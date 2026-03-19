# roles/k8s-worker.sls — Kubernetes worker node
# kubeadm join is triggered by debz-autobootstrap on MASTER, not from here
include:
  - roles.k8s-common
