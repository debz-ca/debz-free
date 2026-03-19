# roles/kvm.sls — KVM hypervisor node
include:
  - roles.common

kvm_packages:
  pkg.installed:
    - pkgs:
      - qemu-kvm
      - qemu-utils
      - libvirt-daemon-system
      - libvirt-clients
      - virtinst
      - bridge-utils
      - ovmf
      - cpu-checker

libvirtd:
  service.running:
    - enable: True
    - require:
      - pkg: kvm_packages

ip_forward:
  sysctl.present:
    - name: net.ipv4.ip_forward
    - value: 1

/var/lib/libvirt/images:
  file.directory:
    - user: root
    - group: root
    - mode: '0711'
