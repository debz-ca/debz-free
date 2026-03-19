# roles/k8s-common.sls — applied to all k8s nodes before kubeadm join
# Binds kubelet to wg2 (10.79.0.0/16) — Kubernetes backend plane
include:
  - roles.common

k8s_repo:
  cmd.run:
    - name: |
        K8S_VER=$(curl -sL https://dl.k8s.io/release/stable.txt | grep -oP 'v\K[0-9]+\.[0-9]+')
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VER}/deb/Release.key" \
          | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VER}/deb/ /" \
          > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq
    - unless: test -f /etc/apt/sources.list.d/kubernetes.list

k8s_packages:
  pkg.installed:
    - pkgs:
      - kubelet
      - kubeadm
      - kubectl
      - containerd
    - require:
      - cmd: k8s_repo

containerd:
  service.running:
    - enable: True
    - require:
      - pkg: k8s_packages

# Bind kubelet to wg2 (backend plane)
/etc/default/kubelet:
  file.managed:
    - contents: |
        KUBELET_EXTRA_ARGS=--node-ip={{ grains['wg2_ip'] }}
    - require:
      - pkg: k8s_packages

kubelet:
  service.running:
    - enable: True
    - require:
      - pkg: k8s_packages
