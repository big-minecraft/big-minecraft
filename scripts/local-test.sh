#!/bin/bash
set -euo pipefail

# Disposable local BMC cluster on k3d.
#
# Two safety properties, both deliberate:
#
#   1. It writes its own kubeconfig to .local-test/kubeconfig and exports
#      KUBECONFIG for its own commands only. Your default kubectl context is
#      never switched, so a forgotten teardown cannot leave you pointed at a
#      test cluster -- or, worse, leave a test command pointed at production.
#
#   2. It passes charts/bmc-chart/values.local.yaml explicitly via VALUES_FILE
#      and never reads or writes values.custom.yaml.
#
# Usage:
#   scripts/local-test.sh up        # create cluster + RWX storage
#   scripts/local-test.sh build     # build panel/manager for THIS arch, import
#   scripts/local-test.sh install   # preflight + install BMC
#   scripts/local-test.sh status    # what is running
#   scripts/local-test.sh kubectl … # run any kubectl against the test cluster
#   scripts/local-test.sh panel     # port-forward the panel to localhost:8080
#   scripts/local-test.sh down      # delete everything
#   scripts/local-test.sh all       # up + build + install + status

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

CLUSTER="${BMC_TEST_CLUSTER:-bmc-test}"
NS="${BMC_TEST_NAMESPACE:-bmc}"
PROFILE="${BMC_TEST_PROFILE:-generic}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.local-test"
export KUBECONFIG="$STATE/kubeconfig"
VALUES="$ROOT/charts/bmc-chart/values.local.yaml"

# Optional per-machine settings (gitignored). Put BMC_PANEL_SRC / BMC_MANAGER_SRC
# here once instead of exporting them every time.
[ -f "$ROOT/.local-test.env" ] && . "$ROOT/.local-test.env"

PANEL_REPO="${BMC_PANEL_REPO:-https://github.com/big-minecraft/bmc-panel.git}"
MANAGER_REPO="${BMC_MANAGER_REPO:-https://github.com/big-minecraft/bmc-manager.git}"

step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

need() { command -v "$1" &>/dev/null || die "$1 is required but not installed"; }

cmd_up() {
  need k3d; need kubectl; need helm
  docker info &>/dev/null || die "Docker is not running"

  mkdir -p "$STATE"

  if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
    ok "cluster '$CLUSTER' already exists"
  else
    step "Creating k3d cluster '$CLUSTER'"
    # --kubeconfig-update-default=false is what keeps your real context safe.
    k3d cluster create "$CLUSTER" \
      --wait --timeout 300s \
      --kubeconfig-update-default=false \
      --kubeconfig-switch-context=false \
      --port "8080:80@loadbalancer" \
      --port "25565:25565@loadbalancer" >/dev/null
    ok "cluster created"
  fi

  k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG"
  chmod 600 "$KUBECONFIG"
  ok "kubeconfig written to $KUBECONFIG (your default context is untouched)"

  step "Waiting for Traefik (k3s installs it via a Job)"
  for _ in $(seq 1 60); do
    kubectl get ingressclass traefik &>/dev/null && break
    sleep 5
  done
  kubectl get ingressclass traefik &>/dev/null \
    && ok "IngressClass 'traefik' ready" \
    || warn "Traefik did not appear; the ingress check will fail"

  step "Installing an RWX storage class"
  # k3d only ships local-path, which is ReadWriteOnce. BMC needs RWX for game
  # data because file-edit and SFTP pods mount a running server's volume.
  if kubectl get sc nfs &>/dev/null; then
    ok "storage class 'nfs' already present"
  else
    helm repo add nfs-ganesha https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ &>/dev/null || true
    helm repo update &>/dev/null
    # vers=4.1 is REQUIRED. The chart defaults to NFSv3, which needs rpcbind and
    # fails inside a k3d node with "mount failed: exit status 255" -- the PVC
    # binds, then every pod that mounts it hangs in ContainerCreating.
    helm install nfs nfs-ganesha/nfs-server-provisioner \
      --namespace nfs --create-namespace \
      --set storageClass.name=nfs \
      --set 'storageClass.mountOptions={vers=4.1}' \
      --set persistence.enabled=false \
      --wait --timeout 5m >/dev/null
    ok "storage class 'nfs' installed (NFSv4.1)"
  fi

  # The provisioner registers with the API a moment after its pod is Ready.
  kubectl wait --for=condition=ready pod -l app=nfs-server-provisioner -n nfs --timeout=180s &>/dev/null || true

  echo ""
  ok "Cluster ready. Next: scripts/local-test.sh build   (or 'install' to use registry images)"
}

# Locate a source checkout, or fetch one.
#
# There is no sane default path: the panel and manager live in separate repos
# that may be anywhere, or nowhere. Resolution order is explicit config, then
# conventional sibling locations, then a shallow clone into .local-test/src so
# this works on a machine that has never seen those repos.
#
# $1 = component name (bmc-panel|bmc-manager)  $2 = explicit path or ""  $3 = git URL
resolve_source() {
  local name="$1" explicit="$2" repo="$3" candidate

  if [ -n "$explicit" ]; then
    [ -d "$explicit" ] || die "$name source not found at $explicit"
    echo "$explicit"; return 0
  fi

  for candidate in "$ROOT/../$name" "$ROOT/../../$name" "$STATE/src/$name"; do
    if [ -d "$candidate/.git" ] || [ -f "$candidate/Dockerfile" ]; then
      echo "$candidate"; return 0
    fi
  done

  # Nothing local: clone it. Shallow, into throwaway state.
  mkdir -p "$STATE/src"
  git clone --depth 1 "$repo" "$STATE/src/$name" >/dev/null 2>&1 \
    || die "could not find or clone $name.
    Set it in .local-test.env:
      BMC_PANEL_SRC=/path/to/bmc-panel
      BMC_MANAGER_SRC=/path/to/bmc-manager"
  echo "$STATE/src/$name"
}

cmd_build() {
  need docker; need k3d; need git
  ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"

  step "Building images for linux/$ARCH and importing into '$CLUSTER'"
  echo "  Two reasons to build rather than pull:"
  echo "    1. Architecture - a published image with no variant for this node"
  echo "       cannot run here at all (check: docker manifest inspect <image>)."
  echo "    2. Testing YOUR code - published images are the published source,"
  echo "       not your working tree. This is the only way to test panel or"
  echo "       manager changes."
  echo ""

  local MANAGER_SRC PANEL_SRC
  MANAGER_SRC="$(resolve_source bmc-manager "${BMC_MANAGER_SRC:-}" "$MANAGER_REPO")"
  PANEL_SRC="$(resolve_source bmc-panel "${BMC_PANEL_SRC:-}" "$PANEL_REPO")"
  echo "  manager source: $MANAGER_SRC"
  echo "  panel source:   $PANEL_SRC"
  echo ""

  echo "  building bmc-manager (gradle, this takes a few minutes)..."
  docker build --platform "linux/$ARCH" -t bmc-manager:local "$MANAGER_SRC" >/dev/null
  ok "bmc-manager:local"

  echo "  building bmc-panel (npm + tool downloads)..."
  docker build --platform "linux/$ARCH" -t bmc-panel:local "$PANEL_SRC" >/dev/null
  ok "bmc-panel:local"

  k3d image import bmc-manager:local bmc-panel:local -c "$CLUSTER" >/dev/null
  # Verify against the node, not the host -- these are separate image stores.
  if cluster_has_image "bmc-panel:local" && cluster_has_image "bmc-manager:local"; then
    ok "imported and verified present in the cluster"
  else
    die "import reported success but the images are not in the node's containerd"
  fi
}

# Is the image in the CLUSTER's containerd? `docker image inspect` answers a
# different question -- it queries the host daemon. The two stores are separate,
# which is why `k3d image import` exists at all. Checking the host and then
# setting pullPolicy=Never is how you get ErrImageNeverPull: the override says
# "never contact a registry", and the node has nothing to fall back on.
cluster_has_image() {
  docker exec "k3d-${CLUSTER}-server-0" crictl images 2>/dev/null \
    | awk '{print $1":"$2}' | grep -qx "docker.io/library/$1" && return 0
  docker exec "k3d-${CLUSTER}-server-0" crictl images 2>/dev/null \
    | awk '{print $1":"$2}' | grep -qx "$1" && return 0
  return 1
}

# The node's architecture, and whether a published image actually has a manifest
# for it. Falling back to published images without checking this is how you get
# ImagePullBackOff: the tag exists, it just has no variant this node can run.
node_arch() {
  kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null
}

published_supports_arch() {
  docker manifest inspect "$1" 2>/dev/null \
    | jq -e --arg a "$2" '[.manifests[]? | select(.platform.os=="linux") | .platform.architecture] | index($a)' \
      >/dev/null 2>&1
}

host_has_local_images() {
  docker image inspect bmc-panel:local &>/dev/null && docker image inspect bmc-manager:local &>/dev/null
}

ensure_images_imported() {
  if cluster_has_image "bmc-panel:local" && cluster_has_image "bmc-manager:local"; then
    ok "local images present in the cluster"
    return 0
  fi
  if host_has_local_images; then
    warn "images exist on the host but not in the cluster - importing"
    k3d image import bmc-manager:local bmc-panel:local -c "$CLUSTER" >/dev/null 2>&1 || true
    if cluster_has_image "bmc-panel:local" && cluster_has_image "bmc-manager:local"; then
      ok "imported"
      return 0
    fi
  fi
  return 1
}

cmd_install() {
  need kubectl; need helm; need helmfile; need yq
  [ -f "$KUBECONFIG" ] || die "no test cluster; run: scripts/local-test.sh up"
  cd "$ROOT"

  step "Preflight"
  PROFILE="$PROFILE" VALUES_FILE="$VALUES" PREFLIGHT_TIMEOUT=120 \
    ./scripts/preflight.sh || die "preflight failed - fix the ✗ items above"

  step "Secrets"
  kubectl create namespace "$NS" &>/dev/null || true
  if kubectl get secret bmc-secrets -n "$NS" &>/dev/null; then
    ok "bmc-secrets already exists"
  else
    NAMESPACE="$NS" ./scripts/generate-secrets.sh | tee "$STATE/secrets.txt" | grep -E "Invite Code" || true
    ok "credentials saved to $STATE/secrets.txt"
  fi

  step "Images"
  # Build ONE effective values file rather than applying twice. The previous
  # approach ran helmfile (registry images) and then a helm upgrade (local
  # images), which produced two ReplicaSets per Deployment: the first could
  # never pull on arm64 and its failed pods lingered beside the second.
  local effective="$STATE/values.effective.yaml"
  cp "$VALUES" "$effective"

  local arch; arch="$(node_arch)"; arch="${arch:-amd64}"

  if [ "${BMC_TEST_IMAGES:-}" = "published" ]; then
    warn "BMC_TEST_IMAGES=published - using the registry images as-is"
  elif ensure_images_imported; then
    cat >> "$effective" <<'EOF'

# Injected by scripts/local-test.sh: use the images built for this machine's
# architecture and imported into the node. pullPolicy Never is safe ONLY
# because presence in the cluster was verified first.
images:
  panel:
    repository: bmc-panel
    tag: local
    pullPolicy: Never
  manager:
    repository: bmc-manager
    tag: local
    pullPolicy: Never
EOF
    ok "using locally built images"
  else
    # No local build. Published images are fine IF they have a variant for this
    # node -- that is the common case on an amd64 machine, and it means a plain
    # `install` works with no build step at all.
    local incompatible=()
    for img in kyrokrypt/bmc-panel:latest kyrokrypt/bmc-manager:latest; do
      published_supports_arch "$img" "$arch" || incompatible+=("$img")
    done

    if [ ${#incompatible[@]} -eq 0 ]; then
      ok "no local build; published images support linux/$arch - using them"
      warn "these are the PUBLISHED images, not your working tree"
      warn "run '$0 build' to test local panel/manager changes"
    else
      echo ""
      die "no local images, and these published images have no linux/$arch variant:
$(printf '      - %s\n' "${incompatible[@]}")
    Run '$0 build' to build them for this machine, or publish multi-arch:
      docker buildx build --platform linux/amd64,linux/arm64 -t <image> --push ."
    fi
  fi

  step "Installing BMC (profile: $PROFILE)"
  # BMC_VALUES_FILE redirects helmfile's installation-values layer at the
  # generated file. values.custom.yaml is never read or written.
  PROFILE="$PROFILE" BMC_VALUES_FILE="$effective" \
    helmfile -f "$ROOT/helmfile.yaml" apply --skip-diff-on-install 2>&1 | tail -12 || true

  ok "install complete - run '$0 status'"
}

cmd_reset_deployments() {
  [ -f "$KUBECONFIG" ] || die "no test cluster"
  local panel
  panel=$(kubectl get pods -n "$NS" -l app=panel --no-headers -o custom-columns=:.metadata.name 2>/dev/null | head -1)
  [ -n "$panel" ] || die "no panel pod running"

  step "Re-rendering deployments from the synced templates"
  # All four pieces must go together. Deleting only the cluster resources
  # leaves them in Pulumi's state, and the panel's bootstrap only recreates a
  # deployment when its MANIFEST is missing -- so a half-reset leaves the
  # deployment permanently stuck with nothing willing to recreate it.
  # Order and waiting both matter. A PVC carries the pvc-protection finalizer,
  # so it sits in Terminating for as long as any pod mounts it. Deleting with
  # --wait=false and immediately restarting the panel means Pulumi tries to
  # recreate a claim that is still terminating: the GameServer comes back, the
  # PVC does not, and the pods sit Pending on "persistentvolumeclaim not found".
  # So: remove the GameServers, let their pods go, then wait for the claims to
  # actually disappear.
  kubectl delete gameservers --all -n "$NS" --wait=true --timeout=120s &>/dev/null || true
  kubectl delete pods -n "$NS" -l 'kyriji.dev/lb-ready' --wait=true --timeout=120s &>/dev/null || true
  kubectl delete pvc -n "$NS" -l 'kyriji.dev/deployment-type' --wait=true --timeout=180s &>/dev/null || true

  for _ in $(seq 1 60); do
    local remaining
    remaining=$(kubectl get pvc -n "$NS" -l 'kyriji.dev/deployment-type' --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${remaining:-0}" = "0" ] && break
    sleep 2
  done
  if [ "$(kubectl get pvc -n "$NS" -l 'kyriji.dev/deployment-type' --no-headers 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
    warn "some deployment PVCs are still terminating; the recreate may race"
  else
    ok "cluster resources removed (claims fully gone)"
  fi

  kubectl exec -n "$NS" "$panel" -- sh -c 'rm -rf /storage/manifests/*/*.yaml' &>/dev/null || true
  ok "manifests removed (lets the panel bootstrap recreate them)"

  kubectl exec -n "$NS" "$panel" -- sh -c 'rm -f /storage/pulumi-state/.pulumi/stacks/bmc-deployments/*.json*' &>/dev/null || true
  ok "pulumi state cleared"

  kubectl rollout restart deploy/panel -n "$NS" &>/dev/null || true
  kubectl rollout status deploy/panel -n "$NS" --timeout=240s &>/dev/null || true
  ok "panel restarted - deployments will be recreated from the synced templates"
}

cmd_status() {
  [ -f "$KUBECONFIG" ] || die "no test cluster; run: scripts/local-test.sh up"
  step "Pods"
  kubectl get pods -n "$NS" -o wide 2>/dev/null | sed 's/^/  /' || true
  step "Services"
  kubectl get svc -n "$NS" -o 'custom-columns=NAME:.metadata.name,TYPE:.spec.type,EXTERNAL:.status.loadBalancer.ingress[*].ip,PORTS:.spec.ports[*].port' 2>/dev/null | sed 's/^/  /' || true
  step "Storage"
  kubectl get pvc -n "$NS" -o 'custom-columns=NAME:.metadata.name,PHASE:.status.phase,MODES:.spec.accessModes,CLASS:.spec.storageClassName' 2>/dev/null | sed 's/^/  /' || true
  step "Not-running pods"
  kubectl get pods -n "$NS" --field-selector=status.phase!=Running --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (none)"
}

cmd_panel() {
  [ -f "$KUBECONFIG" ] || die "no test cluster"
  echo "Panel -> http://localhost:8080   (Ctrl-C to stop)"
  [ -f "$STATE/secrets.txt" ] && grep -E "Invite Code" "$STATE/secrets.txt" || true
  kubectl port-forward -n "$NS" svc/panel-service 8080:80
}

cmd_down() {
  # Teardown order matters. The in-cluster NFS server leaves mounts inside the
  # k3s node container; deleting the cluster while they exist can wedge the
  # container in a state where even `docker rm -f` fails with
  # "did not receive an exit event", and its namespaces break (exec returns
  # setns errors). Unmount first by removing the workloads, then the provisioner.
  if [ -f "$KUBECONFIG" ] && kubectl version &>/dev/null; then
    step "Releasing NFS mounts before deleting the cluster"
    kubectl delete namespace "$NS" --wait=true --timeout=120s &>/dev/null || true
    ok "workload namespace removed"
    helm uninstall nfs -n nfs --wait --timeout 2m &>/dev/null || true
    kubectl delete namespace nfs --wait=true --timeout=120s &>/dev/null || true
    ok "NFS provisioner removed"
    sleep 3
  fi

  step "Deleting cluster '$CLUSTER'"
  # Do NOT suppress this. k3d prints "Successfully deleted cluster" and exits 0
  # even when it failed to remove the container, network and volume -- so the
  # exit code cannot be trusted and the output is the only real signal.
  k3d cluster delete "$CLUSTER" 2>&1 | sed 's/^/    /' || true

  step "Verifying"
  local leftover=0
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "k3d-${CLUSTER}-server-0"; then
    warn "node container survived; forcing removal"
    docker rm -f "k3d-${CLUSTER}-server-0" 2>&1 | sed 's/^/    /' || true
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "k3d-${CLUSTER}-server-0" && leftover=1
  fi
  docker network rm "k3d-${CLUSTER}" &>/dev/null || true
  docker volume rm "k3d-${CLUSTER}-images" &>/dev/null || true

  docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "k3d-${CLUSTER}" && leftover=1
  docker volume  ls --format '{{.Name}}' 2>/dev/null | grep -qx "k3d-${CLUSTER}-images" && leftover=1

  rm -rf "$STATE"

  if [ "$leftover" = "1" ]; then
    echo ""
    warn "The cluster did NOT fully delete."
    echo "    Docker still holds one or more of:"
    docker ps -a --format '      container {{.Names}}' 2>/dev/null | grep "k3d-${CLUSTER}" || true
    docker network ls --format '      network   {{.Name}}' 2>/dev/null | grep "k3d-${CLUSTER}" || true
    docker volume  ls --format '      volume    {{.Name}}' 2>/dev/null | grep "k3d-${CLUSTER}" || true
    echo ""
    echo "    The node container is wedged: Docker reports it running, but exec"
    echo "    fails with setns errors and it ignores SIGKILL. Only a Docker"
    echo "    daemon restart clears this:"
    echo ""
    echo "      Docker Desktop > Troubleshoot > Restart    (or: killall Docker && open -a Docker)"
    echo ""
    echo "    Then re-run: $0 down"
    return 1
  fi

  ok "cluster, network, volume and local state all removed"
  echo "  Your default kubectl context was never touched."
}

case "${1:-}" in
  up)      cmd_up ;;
  reset-deployments) cmd_reset_deployments ;;
  build)   cmd_build ;;
  install) cmd_install ;;
  status)  cmd_status ;;
  panel)   cmd_panel ;;
  down)    cmd_down ;;
  kubectl) shift; kubectl "$@" ;;
  all)     cmd_up
           # Build only when the published images cannot run on this node.
           # Testing your own panel/manager changes is an explicit `build`.
           _arch="$(node_arch)"; _arch="${_arch:-amd64}"
           _need=0
           for _img in kyrokrypt/bmc-panel:latest kyrokrypt/bmc-manager:latest; do
             published_supports_arch "$_img" "$_arch" || _need=1
           done
           if [ "$_need" = "1" ]; then
             warn "published images have no linux/$_arch variant - building locally"
             cmd_build
           else
             ok "published images support linux/$_arch - skipping build"
             echo "    run '$0 build' if you want to test local panel/manager changes"
           fi
           cmd_install; cmd_status ;;
  *)
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
