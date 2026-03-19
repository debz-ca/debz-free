#!/usr/bin/env bash
# Sourced by debz-install-target — k_bootstrap_base (debootstrap, APT mirror detection, locale, timezone, extra packages)
set -Eeuo pipefail

# k_write_sources_list — INSTALL-TIME only.
# Points the target at whatever mirror is being used right now (local darksite
# or internet).  This is intentionally temporary — k_finalize_sources_list
# overwrites it at the end of bootstrap with the correct post-install config.
k_write_sources_list() {
  local target="${DEBZ_TARGET:?}"
  local suite="${DEBZ_SUITE:-trixie}"
  local mirror="${DEBZ_MIRROR:-https://mirror.it.ubc.ca/debian}"

  if [[ "$mirror" == "http://127.0.0.1:"* ]]; then
    cat > "${target}/etc/apt/sources.list" <<EOS
# Install-time only — darksite local mirror (will be replaced after install)
deb [trusted=yes] ${mirror} ${suite} main
EOS
  else
    cat > "${target}/etc/apt/sources.list" <<EOS
deb ${mirror} ${suite} main contrib non-free non-free-firmware
deb ${mirror} ${suite}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
EOS
  fi
}

# k_finalize_sources_list — POST-INSTALL.
# Writes the sources.list the installed system will actually use for updates.
#
#   DEBZ_KEEP_DARKSITE=0  (default) → standard Debian internet repos
#   DEBZ_KEEP_DARKSITE=1            → custom mirror at DEBZ_CUSTOM_MIRROR_URL
#                                     (for air-gap targets that update via a
#                                      local APT mirror server or updated ISO)
k_finalize_sources_list() {
  local target="${DEBZ_TARGET:?}"
  local suite="${DEBZ_SUITE:-trixie}"

  if [[ "${DEBZ_KEEP_DARKSITE:-0}" == "1" && -n "${DEBZ_CUSTOM_MIRROR_URL:-}" ]]; then
    k_log_to "${DEBZ_BOOTSTRAP_LOG}" \
      "Finalizing sources.list: custom mirror ${DEBZ_CUSTOM_MIRROR_URL}"
    cat > "${target}/etc/apt/sources.list" <<EOS
# Custom APT mirror — configured at install time
deb [trusted=yes] ${DEBZ_CUSTOM_MIRROR_URL} ${suite} main contrib non-free non-free-firmware
EOS
  else
    k_log_to "${DEBZ_BOOTSTRAP_LOG}" \
      "Finalizing sources.list: standard Debian internet repos"
    cat > "${target}/etc/apt/sources.list" <<EOS
deb https://deb.debian.org/debian ${suite} main contrib non-free non-free-firmware
deb https://deb.debian.org/debian ${suite}-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
EOS
  fi
}

k_bind_chroot_mounts() {
  local target="${DEBZ_TARGET:?}"
  k_mount_bind /dev "${target}/dev"
  mkdir -p "${target}/dev/pts"
  k_mount_bind /dev/pts "${target}/dev/pts"
  k_mount_bind /proc "${target}/proc"
  k_mount_bind /sys "${target}/sys"
  k_mount_bind /run "${target}/run"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "${target}/sys/firmware/efi/efivars"
    mountpoint -q "${target}/sys/firmware/efi/efivars" || \
      mount --bind /sys/firmware/efi/efivars "${target}/sys/firmware/efi/efivars" || true
  fi
}

k_unbind_chroot_mounts() {
  local target="${DEBZ_TARGET:?}"
  k_umount_if_mounted "${target}/sys/firmware/efi/efivars"
  k_umount_if_mounted "${target}/run"
  k_umount_if_mounted "${target}/sys"
  k_umount_if_mounted "${target}/proc"
  k_umount_if_mounted "${target}/dev/pts"
  k_umount_if_mounted "${target}/dev"
}

k_write_hostname() {
  local target="${DEBZ_TARGET:?}"
  local host="${DEBZ_HOSTNAME:-debz}"

  printf '%s\n' "${host}" > "${target}/etc/hostname"
  cat > "${target}/etc/hosts" <<EOH
127.0.0.1 localhost
127.0.1.1 ${host}
::1 localhost ip6-localhost ip6-loopback
EOH
}

k_enable_locale() {
  local target="${DEBZ_TARGET:?}"
  local locale="${DEBZ_LOCALE:-en_US.UTF-8}"

  mkdir -p "${target}/etc"
  : > "${target}/etc/locale.gen"
  printf '%s UTF-8\n' "${locale}" >> "${target}/etc/locale.gen"

  cat > "${target}/etc/default/locale" <<EOL
LANG=${locale}
LC_ALL=
EOL
}

k_preseed_noninteractive() {
  local target="${DEBZ_TARGET:?}"

  mkdir -p "${target}/etc/apt/apt.conf.d"
  cat > "${target}/etc/apt/apt.conf.d/90debz-noninteractive" <<'EOA'
APT::Get::Assume-Yes "true";
APT::Install-Recommends "false";
DPkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOA

  if command -v chroot >/dev/null 2>&1; then
    printf '%s\n' \
      'console-setup console-setup/charmap47 select UTF-8' \
      'console-setup console-setup/codeset47 select Latin1 and Latin5 - western Europe and Turkic languages' \
      'console-setup console-setup/fontface47 select Fixed' \
      'console-setup console-setup/fontsize-fb47 select 8x16' \
      'keyboard-configuration keyboard-configuration/layoutcode string us' \
      'keyboard-configuration keyboard-configuration/modelcode string pc105' \
      'keyboard-configuration keyboard-configuration/variantcode string' \
      | chroot "${target}" debconf-set-selections || true
  fi
}

k_create_users() {
  local target="${DEBZ_TARGET:?}"
  local user="${DEBZ_USERNAME:-admin}"

  if [[ -n "${DEBZ_ROOT_PASSWORD:-}" ]]; then
    echo "root:${DEBZ_ROOT_PASSWORD}" | chroot "${target}" chpasswd
  fi

  if ! chroot "${target}" id "${user}" >/dev/null 2>&1; then
    k_in_chroot "${target}" useradd -m -s /bin/bash -G sudo "${user}"
  fi

  if [[ -n "${DEBZ_PASSWORD:-}" ]]; then
    echo "${user}:${DEBZ_PASSWORD}" | chroot "${target}" chpasswd
  fi
}

k_write_manifest() {
  local target="${DEBZ_TARGET:?}"
  mkdir -p "${target}/etc/debz"

  cat > "${target}/etc/debz/install-manifest.env" <<EOM
DEBZ_PROFILE=${DEBZ_PROFILE:-server}
DEBZ_STORAGE_MODE=${DEBZ_STORAGE_MODE:-standard}
DEBZ_ENABLE_ZFS=${DEBZ_ENABLE_ZFS:-0}
DEBZ_ENABLE_EBPF=${DEBZ_ENABLE_EBPF:-0}
DEBZ_SECURE_BOOT=${DEBZ_SECURE_BOOT:-0}
DEBZ_TPM_PRESENT=${DEBZ_TPM_PRESENT:-0}
EOM
}

# k_generate_mok_keys — create MOK key pair at the standard DKMS paths and
# configure DKMS to sign modules during build.  Must be called BEFORE any
# package installation so that when zfs-dkms is installed, DKMS builds the
# kernel module and signs it in a single pass — no retroactive signing needed.
k_generate_mok_keys() {
  local target="${DEBZ_TARGET:?}"
  local mok_dir="${target}/var/lib/dkms"

  k_log_to "${DEBZ_BOOTSTRAP_LOG}" "Generating MOK key pair for DKMS module signing"

  mkdir -p "${mok_dir}"

  # RSA-2048 key + self-signed cert — 10-year validity, no passphrase
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "${mok_dir}/mok.key" \
    -out    "${mok_dir}/mok.pub" \
    -days 3650 -nodes \
    -subj "/CN=debz Secure Boot MOK/" \
    >> "${DEBZ_BOOTSTRAP_LOG}" 2>&1

  # DER format required by mokutil --import
  openssl x509 \
    -in "${mok_dir}/mok.pub" \
    -out "${mok_dir}/mok.der" \
    -outform DER \
    >> "${DEBZ_BOOTSTRAP_LOG}" 2>&1

  chmod 0600 "${mok_dir}/mok.key"
  chmod 0644 "${mok_dir}/mok.pub" "${mok_dir}/mok.der"

  # DKMS sign_tool script — called by DKMS as: script KVER MODULE_PATH
  # Uses the sign-file binary from the matching linux-headers package.
  mkdir -p "${target}/etc/dkms"
  cat > "${target}/etc/dkms/sign_helper.sh" <<'EOSIGN'
#!/bin/bash
set -euo pipefail
KVER="${1:?}" MOD="${2:?}"
KEY=/var/lib/dkms/mok.key
CERT=/var/lib/dkms/mok.pub
SIGN_FILE=$(find /usr/src/linux-headers-"${KVER}" \
                 /usr/lib/linux-kbuild-"${KVER%%.*}"* \
                 -name sign-file -type f 2>/dev/null | head -1 || true)
[[ -x "${SIGN_FILE}" ]] || { echo "sign-file not found for ${KVER}" >&2; exit 0; }
exec "${SIGN_FILE}" sha256 "${KEY}" "${CERT}" "${MOD}"
EOSIGN
  chmod 0755 "${target}/etc/dkms/sign_helper.sh"

  # Wire into DKMS — all future module builds will be signed automatically
  printf 'sign_tool=/etc/dkms/sign_helper.sh\n' \
    >> "${target}/etc/dkms/framework.conf"

  k_log_to "${DEBZ_BOOTSTRAP_LOG}" "MOK keys ready at /var/lib/dkms/mok.{key,pub,der} — DKMS will sign on install"
}

k_install_target_packages() {
  local target="${DEBZ_TARGET:?}"
  local -a pkgs
  local profile_pkgs profile_opt

  # Generate MOK keys BEFORE package installation so DKMS signs ZFS modules
  # during build rather than requiring retroactive signing afterward.
  k_generate_mok_keys

  pkgs=(
    "linux-image-$(dpkg --print-architecture)"
    "linux-headers-$(dpkg --print-architecture)"
    efibootmgr
    mokutil
    kexec-tools
    locales
    keyboard-configuration
    console-setup
    systemd-sysv
    initramfs-tools
    sudo
    openssh-server
    network-manager
    qemu-guest-agent
  )

  if [[ "${DEBZ_STORAGE_MODE:-standard}" == "zfs" ]]; then
    # zfs-dkms must be explicit so DKMS builds (and signs) the kernel module;
    # zfsutils-linux alone may pull a pre-built binary that bypasses DKMS.
    pkgs+=(
      zfs-dkms
      zfsutils-linux
      zfs-initramfs
      zfs-zed
    )
  fi

  k_in_chroot "${target}" apt-get update
  k_in_chroot "${target}" apt-get install -y "${pkgs[@]}"

  profile_pkgs="$(k_profile_packages)"
  profile_opt="$(k_profile_optional_packages)"
  if [[ -n "${profile_pkgs}${profile_opt}" ]]; then
    k_in_chroot "${target}" bash -lc "apt-get install -y ${profile_pkgs} ${profile_opt}"
  fi
}

# k_detect_local_mirror — returns the local darksite mirror URL if the
# debz-apt-mirror service is running and the repo is healthy.
k_detect_local_mirror() {
  local test_url="http://127.0.0.1:3142/apt/dists/trixie/Release"
  if curl -sf --connect-timeout 3 --max-time 5 "$test_url" >/dev/null 2>&1; then
    echo "http://127.0.0.1:3142/apt"
    return 0
  fi
  return 1
}

k_bootstrap_base() {
  local suite="${DEBZ_SUITE:-trixie}"
  local target="${DEBZ_TARGET:?}"

  # Prefer the local darksite APT mirror; fall back to internet
  local mirror
  if mirror="$(k_detect_local_mirror 2>/dev/null)"; then
    k_log_to "${DEBZ_BOOTSTRAP_LOG}" "Using local darksite APT mirror: ${mirror}"
  else
    mirror="${DEBZ_MIRROR:-https://mirror.it.ubc.ca/debian}"
    k_log_to "${DEBZ_BOOTSTRAP_LOG}" "Darksite mirror not available; using: ${mirror}"
  fi
  export DEBZ_MIRROR="$mirror"

  k_log_to "${DEBZ_BOOTSTRAP_LOG}" "Running debootstrap suite=${suite} target=${target} mirror=${mirror}"
  local debootstrap_opts=(
    --arch "$(dpkg --print-architecture)"
    --merged-usr          # trixie uses merged /usr; without this the dynamic linker
                          # symlinks (/lib64 → /usr/lib) are missing and all chroot
                          # binaries fail with "No such file or directory"
    "--include=dash,diffutils,gzip,zstd"  # gzip/zstd required by mkinitramfs; must be
                              # present before kernel package configuration runs
    --keep-debootstrap-dir
  )
  # Local unsigned repo needs --no-check-gpg
  [[ "$mirror" == "http://127.0.0.1:"* ]] && debootstrap_opts+=(--no-check-gpg)
  debootstrap "${debootstrap_opts[@]}" "${suite}" "${target}" "${mirror}" \
    2>&1 | tee -a "${DEBZ_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}" || {
    k_log_to "${DEBZ_BOOTSTRAP_LOG}" "debootstrap failed — internal log:"
    local _dbs_log="${target}/debootstrap/debootstrap.log"
    if [[ -s "$_dbs_log" ]]; then
      tee -a "${DEBZ_BOOTSTRAP_LOG}" < "$_dbs_log" >&2
    else
      k_log_to "${DEBZ_BOOTSTRAP_LOG}" "(no debootstrap internal log found at ${_dbs_log})"
    fi
    return 1
  }

  k_write_sources_list
  k_bind_chroot_mounts
  k_preseed_noninteractive
  k_install_target_packages
  k_write_hostname
  k_enable_locale
  k_in_chroot "${target}" locale-gen "${DEBZ_LOCALE:-en_US.UTF-8}"
  k_create_users
  k_install_system_files

  # ── Compile dconf system database in target chroot ──────────────────────────
  if [[ -d "${target}/etc/dconf/db/local.d" ]]; then
    k_in_chroot "${target}" dconf update 2>/dev/null || true
  fi

  k_write_manifest

  # Switch sources.list from the install-time mirror to the final post-install
  # config — internet repos by default, or a custom URL if DEBZ_KEEP_DARKSITE=1.
  k_finalize_sources_list

  mkdir -p "${target}/var/log/debz"
  touch "${target}/var/log/debz/bootstrap.log" "${target}/var/log/debz/firstboot.log"

  k_log_to "${DEBZ_BOOTSTRAP_LOG}" "Base bootstrap complete"
}
