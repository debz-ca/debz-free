#!/usr/bin/env bash
# Sourced by debz-install-target — k_profile_packages, k_profile_optional_packages, k_install_system_files (called from bootstrap.sh)
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

k_profile_packages() {
  local profile="${DEBZ_PROFILE:-server}"
  case "$profile" in
    server)
      echo "openssh-server sudo curl ca-certificates vim less systemd-resolved systemd-timesyncd wireguard-tools iproute2"
      ;;
    client)
      echo "openssh-server sudo curl ca-certificates vim less network-manager wireguard-tools iproute2"
      ;;
    desktop)
      # task-gnome-desktop pulls gnome-core → gnome-snapshot → gstreamer1.0-plugins-bad
      # → libfluidsynth3 → sf3-soundfont-gm which is not in the darksite (soundfonts
      # are blacklisted). Install individual packages that avoid gnome-snapshot entirely.
      # Only packages confirmed present in the darksite pool are listed here.
      # loupe = GNOME image viewer (replaces eog in trixie).
      echo "openssh-server sudo curl ca-certificates vim less network-manager \
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
        gdm3 nautilus gnome-terminal gnome-text-editor loupe \
        adwaita-icon-theme fonts-cantarell gvfs gvfs-backends \
        wireguard-tools iproute2"
      ;;

    # ── debz templates ────────────────────────────────────────────────────────

    master)
      # Control plane: Salt master + WireGuard hub + PXE + APT mirror
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        salt-master salt-minion salt-api \
        wireguard-tools \
        dnsmasq tftp-hpa \
        nginx \
        nftables chrony \
        qemu-utils ovmf \
        htop iperf3 tcpdump ethtool nmap"
      ;;

    kvm)
      # Hypervisor: KVM + libvirt + containerd for microVMs (Firecracker pulled by firstboot)
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        qemu-kvm qemu-utils \
        libvirt-daemon-system libvirt-clients virtinst \
        bridge-utils ovmf cpu-checker \
        containerd \
        nftables chrony \
        wireguard-tools"
      ;;

    storage)
      # ZFS storage server: NFS + iSCSI exports, managed by Salt minion
      # ZFS datasets are the core — nfs-kernel-server + targetcli serve them
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        nfs-kernel-server nfs-common \
        tgt \
        samba \
        prometheus-node-exporter \
        nftables chrony \
        salt-minion wireguard-tools"
      ;;

    vdi)
      # Virtual desktop delivery: Wayland + FFmpeg/SRT + mediamtx (binary via hook)
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        mutter gnome-session gdm3 \
        ffmpeg libsrt1.5 \
        pipewire wireplumber \
        wf-recorder \
        xdotool xclip \
        python3-websockets \
        evemu-tools \
        nginx \
        nftables chrony \
        salt-minion wireguard-tools"
      ;;

    proxmox)
      # Proxmox VE hypervisor node — installs base system; Proxmox repo + packages added by firstboot
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        nftables chrony \
        bridge-utils \
        wireguard-tools"
      ;;

    monitoring)
      # Monitoring stack: Prometheus + Grafana + Alertmanager + node exporter
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        prometheus prometheus-node-exporter prometheus-alertmanager \
        grafana \
        nftables chrony \
        wireguard-tools"
      ;;

    *)
      k_die "unsupported profile: $profile"
      ;;
  esac
}

k_profile_optional_packages() {
  local out=()
  if [[ "${DEBZ_ENABLE_EBPF:-0}" == "1" ]]; then
    out+=(bpftool bpfcc-tools bpftrace linux-perf)
  fi
  if [[ "${DEBZ_ENABLE_ZFS:-0}" == "1" ]]; then
    out+=(zfsutils-linux zfs-zed zfs-initramfs zfs-dkms sanoid)
  fi

  # Auto-detect hypervisor and add guest tools
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "${virt}" in
    vmware)   out+=(open-vm-tools) ;;
    kvm|qemu) out+=(qemu-guest-agent) ;;
    xen)      out+=(xe-guest-utilities) ;;
  esac

  printf '%s ' "${out[@]:-}"
}

# k_install_system_files — copy debz system files from the live environment
# into the freshly bootstrapped target. These files live in the live ISO chroot
# but debootstrap creates a clean slate, so they must be copied explicitly.
k_install_system_files() {
  local target="${DEBZ_TARGET:?}"
  local root_ds
  root_ds="rpool/ROOT/${DEBZ_HOSTNAME:-debz}"

  k_log "Installing system files into target"

  # ── Sanoid snapshot automation ─────────────────────────────────────────────
  if [[ -f /etc/sanoid/sanoid.conf ]]; then
    mkdir -p "${target}/etc/sanoid"
    cp /etc/sanoid/sanoid.conf "${target}/etc/sanoid/sanoid.conf"
  fi

  # ── APT pre/post snapshot hooks ────────────────────────────────────────────
  if [[ -d /etc/apt/apt.conf.d ]]; then
    mkdir -p "${target}/etc/apt/apt.conf.d"
    for f in /etc/apt/apt.conf.d/00-debz-snapshot-*; do
      [[ -f "$f" ]] && cp "$f" "${target}/etc/apt/apt.conf.d/"
    done
  fi

  # ── Snapshot management scripts ────────────────────────────────────────────
  mkdir -p "${target}/usr/local/sbin"
  for f in /usr/local/sbin/snapshot-*.sh; do
    [[ -f "$f" ]] && cp "$f" "${target}/usr/local/sbin/" && chmod +x "${target}/usr/local/sbin/$(basename "$f")"
  done

  # ── Systemd units ──────────────────────────────────────────────────────────
  mkdir -p "${target}/usr/lib/systemd/system"
  for f in debz-srv-snapshot.service debz-srv-snapshot.timer debz-firstboot.service; do
    [[ -f "/usr/lib/systemd/system/${f}" ]] && \
      cp "/usr/lib/systemd/system/${f}" "${target}/usr/lib/systemd/system/${f}"
  done

  # Enable services in the installed system via symlinks (no systemctl in chroot)
  mkdir -p "${target}/etc/systemd/system/timers.target.wants"
  ln -sf "/usr/lib/systemd/system/debz-srv-snapshot.timer" \
    "${target}/etc/systemd/system/timers.target.wants/debz-srv-snapshot.timer" || true
  # Sanoid scheduled snapshots (daily/weekly/monthly/yearly)
  ln -sf "/lib/systemd/system/sanoid.timer" \
    "${target}/etc/systemd/system/timers.target.wants/sanoid.timer" || true

  mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
  ln -sf "/usr/lib/systemd/system/debz-firstboot.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/debz-firstboot.service" || true

  # ── User tools: mdir (ZFS dataset creator) + adduser.local hook ────────────
  mkdir -p "${target}/usr/local/bin" "${target}/usr/local/sbin"
  [[ -x /usr/local/bin/mdir ]] && \
    cp /usr/local/bin/mdir "${target}/usr/local/bin/mdir" && \
    chmod +x "${target}/usr/local/bin/mdir"
  [[ -f /usr/local/sbin/adduser.local ]] && \
    cp /usr/local/sbin/adduser.local "${target}/usr/local/sbin/adduser.local" && \
    chmod +x "${target}/usr/local/sbin/adduser.local"

  # ── GNOME dconf system settings (dock, theme, defaults) ─────────────────────
  if [[ -d /etc/dconf/db/local.d ]]; then
    mkdir -p "${target}/etc/dconf/db/local.d"
    cp /etc/dconf/db/local.d/00-debz-desktop "${target}/etc/dconf/db/local.d/00-debz-desktop" 2>/dev/null || true
    mkdir -p "${target}/etc/dconf/profile"
    cp /etc/dconf/profile/user "${target}/etc/dconf/profile/user" 2>/dev/null || true
  fi

  # ── Backend runtime tools (debz-be, debz-recovery, debz-upgrade) ───────────
  if [[ -d /usr/lib/debz-installer/backend ]]; then
    mkdir -p "${target}/usr/lib/debz-installer/backend/bin"
    cp -r /usr/lib/debz-installer/backend/. "${target}/usr/lib/debz-installer/backend/"
    chmod +x "${target}/usr/lib/debz-installer/backend/bin/"* 2>/dev/null || true
    # Expose debz-be in PATH
    mkdir -p "${target}/usr/local/bin"
    ln -sf /usr/lib/debz-installer/backend/bin/debz-be       "${target}/usr/local/bin/debz-be"
    ln -sf /usr/lib/debz-installer/backend/bin/debz-recovery  "${target}/usr/local/bin/debz-recovery"
    ln -sf /usr/lib/debz-installer/backend/bin/debz-upgrade   "${target}/usr/local/bin/debz-upgrade" || true
  fi

  # ── Boot environment marker — tells debz-be which dataset is active ─────────
  mkdir -p "${target}/etc/debz"
  printf '%s\n' "${root_ds}" > "${target}/etc/debz/boot-environment"

  # ── Darksite (full APT mirror + support scripts) → target /root/darksite/ ──
  local darksite_src="/root/darksite"
  local darksite_tgt="${target}/root/darksite"
  if [[ -d "$darksite_src" ]]; then
    mkdir -p "$darksite_tgt"
    # Copy the full darksite tree (apt pool, manifests, scripts)
    rsync -a --exclude='*.lock' "${darksite_src}/" "${darksite_tgt}/"
    # Ensure scripts are executable
    for f in debz-syscheck.sh audit.sh; do
      [[ -f "${darksite_tgt}/${f}" ]] && chmod +x "${darksite_tgt}/${f}"
    done
    k_log "Darksite installed to target: ${darksite_tgt}"
  fi

  # ── Kernel module pinning (APT conf + DKMS verify hook) ────────────────────
  local tgt_files="/usr/lib/debz-installer/target-files"
  if [[ -d "${tgt_files}" ]]; then
    mkdir -p "${target}/etc/apt/apt.conf.d"
    cp "${tgt_files}/etc/apt/apt.conf.d/60-debz-kernel" \
       "${target}/etc/apt/apt.conf.d/60-debz-kernel"
    mkdir -p "${target}/etc/kernel/postinst.d"
    cp "${tgt_files}/etc/kernel/postinst.d/debz-dkms-verify" \
       "${target}/etc/kernel/postinst.d/debz-dkms-verify"
    chmod +x "${target}/etc/kernel/postinst.d/debz-dkms-verify"
  fi

  # ── APT mirror service on the installed target ──────────────────────────────
  # Copy the service unit so the installed system can also serve its local APT repo
  local mirror_svc="/usr/lib/systemd/system/debz-apt-mirror.service"
  if [[ -f "$mirror_svc" ]]; then
    cp "$mirror_svc" "${target}/usr/lib/systemd/system/debz-apt-mirror.service"
    mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
    ln -sf "/usr/lib/systemd/system/debz-apt-mirror.service" \
      "${target}/etc/systemd/system/multi-user.target.wants/debz-apt-mirror.service" || true
    k_log "debz-apt-mirror.service enabled on target"
  fi

  k_log "System files installed (root_ds=${root_ds})"
}
