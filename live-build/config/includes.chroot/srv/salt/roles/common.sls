# roles/common.sls — applied to every debz node
common_packages:
  pkg.installed:
    - pkgs:
      - curl
      - ca-certificates
      - vim
      - tmux
      - htop
      - tcpdump
      - ethtool
      - jq
      - wireguard-tools
      - nftables
      - chrony

chrony:
  service.running:
    - enable: True
    - require:
      - pkg: common_packages

nftables:
  service.running:
    - enable: True

/etc/skel/.bashrc:
  file.managed:
    - source: salt://files/bashrc
    - user: root
    - group: root
    - mode: '0644'
