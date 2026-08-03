RELEASE=big-minecraft
NAMESPACE=bmc

for res in "crd/gameservers.kyriji.dev" "deployment/foo" "service/bar"; do
  kubectl annotate $res meta.helm.sh/release-name=$RELEASE --overwrite
  kubectl annotate $res meta.helm.sh/release-namespace=$NAMESPACE --overwrite
  kubectl label   $res app.kubernetes.io/managed-by=Helm --overwrite
done