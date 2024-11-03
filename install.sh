helm uninstall traefik traefik-crd -n kube-system
helmfile apply -l name="metallb"
helmfile apply -l name="cert-manager"
helmfile apply
helmfile sync