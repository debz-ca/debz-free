# roles/k8s-etcd.sls — Kubernetes control-plane node (etcd + API server)
# kubeadm init / join --control-plane triggered by debz-autobootstrap
include:
  - roles.k8s-common

kubectl_config_dir:
  file.directory:
    - name: /root/.kube
    - user: root
    - mode: '0700'
