# roles/storage.sls — ZFS storage node, NFS + iSCSI on wg3 (10.80.0.0/16)
include:
  - roles.common

storage_packages:
  pkg.installed:
    - pkgs:
      - zfsutils-linux
      - nfs-kernel-server
      - nfs-common
      - tgt
      - samba
      - prometheus-node-exporter

nfs-kernel-server:
  service.running:
    - enable: True
    - require:
      - pkg: storage_packages

tgt:
  service.running:
    - enable: True
    - require:
      - pkg: storage_packages

prometheus-node-exporter:
  service.running:
    - enable: True

# NFS exports accessible only via wg3 storage plane
/etc/exports:
  file.managed:
    - contents: |
        /srv/nfs  10.80.0.0/16(rw,no_subtree_check,no_root_squash)
    - user: root
    - group: root
    - mode: '0644'
