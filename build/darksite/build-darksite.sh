#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# build-darksite.sh — runs inside the Docker builder container.
# Downloads all required Debian packages and builds a local APT repository
# that is baked into the live ISO at /root/darksite/apt/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${SCRIPT_DIR}/config/package-sets"

PROFILE="${PROFILE:-desktop}"
ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"

# Output: goes directly into the live ISO chroot
DARKSITE_OUT="/build/live-build/config/includes.chroot/root/darksite"
APT_ROOT="${DARKSITE_OUT}/apt"
APT_POOL="${APT_ROOT}/pool/main"
APT_DISTS="${APT_ROOT}/dists/${SUITE}/main/binary-${ARCH}"

log() { printf '[%s] [darksite] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Read package sets
# ---------------------------------------------------------------------------

declare -a PACKAGES=()

read_package_set() {
    local name="$1"
    local file="${PKG_SETS_DIR}/${name}.txt"
    if [[ ! -f "$file" ]]; then
        log "Package set not found (skipping): $file"
        return 0
    fi
    while IFS= read -r line; do
        # Strip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # Expand ${ARCH} placeholder
        line="${line//\$\{ARCH\}/$ARCH}"
        PACKAGES+=("$line")
    done < "$file"
    log "Loaded package set: $name ($(wc -l < "$file") entries)"
}

# Always include live tools and target base
read_package_set "live-base"
read_package_set "target-base"
read_package_set "target-zfs"      # ZFS is a core debz feature

# All installable target profiles — included regardless of ISO profile so any
# target type can be installed fully offline from the darksite repo.
read_package_set "target-desktop"
read_package_set "target-server"
read_package_set "target-client"
read_package_set "target-kvm"
read_package_set "target-storage"
read_package_set "target-monitoring"
read_package_set "target-vdi"
read_package_set "target-proxmox"

# Container runtimes — included in all ISOs for offline container setup
read_package_set "target-containers"

# Master template packages — always included so any ISO can deploy a master node.
read_package_set "target-master"

# ── SaltProject APT repo ───────────────────────────────────────────────────────
_SALT_KEYRING="/usr/share/keyrings/salt-archive-keyring.gpg"
_SALT_LIST="/etc/apt/sources.list.d/salt-darksite.list"
if [[ ! -f "${_SALT_KEYRING}" ]]; then
    log "Adding SaltProject APT repo (needed for salt-master darksite packages)..."
    curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
        | gpg --dearmor > "${_SALT_KEYRING}" 2>/dev/null \
        && log "Salt keyring written: ${_SALT_KEYRING}" \
        || log "WARNING: failed to fetch Salt keyring — salt packages may be missing from darksite"
    echo "deb [signed-by=${_SALT_KEYRING} arch=${ARCH}] https://packages.broadcom.com/artifactory/saltproject-deb/ stable main" \
        > "${_SALT_LIST}" || true
fi

# ── Grafana APT repo (grafana is not in standard Debian repos) ────────────────
_GRAFANA_KEYRING="/usr/share/keyrings/grafana-archive-keyring.gpg"
_GRAFANA_LIST="/etc/apt/sources.list.d/grafana-darksite.list"
if [[ ! -f "${_GRAFANA_KEYRING}" ]]; then
    log "Adding Grafana APT repo (needed for monitoring profile)..."
    curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor > "${_GRAFANA_KEYRING}" 2>/dev/null \
        && log "Grafana keyring written: ${_GRAFANA_KEYRING}" \
        || log "WARNING: failed to fetch Grafana keyring — grafana may be missing from darksite"
    echo "deb [signed-by=${_GRAFANA_KEYRING} arch=${ARCH}] https://apt.grafana.com stable main" \
        > "${_GRAFANA_LIST}" || true
fi

# ── Docker APT repo ───────────────────────────────────────────────────────────
_DOCKER_KEYRING="/usr/share/keyrings/docker-archive-keyring.gpg"
_DOCKER_LIST="/etc/apt/sources.list.d/docker-darksite.list"
if [[ ! -f "${_DOCKER_KEYRING}" ]]; then
    log "Adding Docker APT repo..."
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor > "${_DOCKER_KEYRING}" 2>/dev/null \
        && log "Docker keyring written: ${_DOCKER_KEYRING}" \
        || log "WARNING: failed to fetch Docker keyring"
    echo "deb [signed-by=${_DOCKER_KEYRING} arch=${ARCH}] https://download.docker.com/linux/debian bookworm stable" \
        > "${_DOCKER_LIST}" || true
fi

# ── Kubernetes APT repo ───────────────────────────────────────────────────────
_K8S_KEYRING="/usr/share/keyrings/kubernetes-archive-keyring.gpg"
_K8S_LIST="/etc/apt/sources.list.d/kubernetes-darksite.list"
if [[ ! -f "${_K8S_KEYRING}" ]]; then
    log "Adding Kubernetes APT repo..."
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
        | gpg --dearmor > "${_K8S_KEYRING}" 2>/dev/null \
        && log "Kubernetes keyring written: ${_K8S_KEYRING}" \
        || log "WARNING: failed to fetch Kubernetes keyring"
    echo "deb [signed-by=${_K8S_KEYRING} arch=${ARCH}] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
        > "${_K8S_LIST}" || true
fi

# ── Proxmox VE APT repo ───────────────────────────────────────────────────────
_PVE_KEYRING="/usr/share/keyrings/proxmox-release-bookworm.gpg"
_PVE_LIST="/etc/apt/sources.list.d/proxmox-darksite.list"
if [[ ! -f "${_PVE_KEYRING}" ]]; then
    log "Adding Proxmox VE APT repo..."
    curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        -o "${_PVE_KEYRING}" 2>/dev/null \
        && log "Proxmox keyring written: ${_PVE_KEYRING}" \
        || log "WARNING: failed to fetch Proxmox keyring"
    echo "deb [signed-by=${_PVE_KEYRING}] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
        > "${_PVE_LIST}" || true
fi

# Update APT cache first — apt-cache dumpavail returns nothing until this runs.
log "Updating APT package lists..."
apt-get update -q 2>&1 | grep -v '^Get\|^Hit\|^Ign' || true

# Add all required+important priority packages so debootstrap always has
# what it needs (e.g. dash for /bin/sh, diffutils for diff).
# These may not appear in apt-cache depends output for our package list.
log "Adding required+important Debian base packages..."
mapfile -t PRIORITY_PKGS < <(
    apt-cache dumpavail 2>/dev/null \
        | awk '/^Package:/ { pkg=$2 }
               /^Priority: (required|important)/ { print pkg }' \
        | sort -u
)
log "Priority packages found: ${#PRIORITY_PKGS[@]}"
PACKAGES+=("${PRIORITY_PKGS[@]}")

# Hardcoded debootstrap essentials — guaranteed even if apt-cache dumpavail
# misses something. debootstrap requires these to bootstrap any Debian system.
PACKAGES+=(
    gzip zstd xz-utils bzip2 tar
    dash bash coreutils diffutils findutils grep sed gawk
    mount util-linux apt dpkg base-files base-passwd
)

# Deduplicate while preserving order
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Packages to download: ${#PKGS_FINAL[@]}"

# ---------------------------------------------------------------------------
# Prepare output directories
# ---------------------------------------------------------------------------

mkdir -p "$APT_POOL" "$APT_DISTS"

# ---------------------------------------------------------------------------
# Download packages and all transitive dependencies
# ---------------------------------------------------------------------------

log "Resolving full dependency closure (including already-installed packages)..."
# apt-get --simulate only lists packages NOT yet installed in the builder container,
# so core base packages (libc6, coreutils, base-files, etc.) are omitted.
# apt-cache depends --recurse gives the complete transitive closure regardless.
mapfile -t CLOSURE < <(
    apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        "${PKGS_FINAL[@]}" 2>/dev/null \
        | grep '^[[:alpha:]]' \
        | sort -u
)
log "Dependency closure: ${#CLOSURE[@]} packages"

if [[ "${#CLOSURE[@]}" -eq 0 ]]; then
    log "apt-cache depends returned empty — falling back to direct package list."
    CLOSURE=("${PKGS_FINAL[@]}")
fi

# ---------------------------------------------------------------------------
# Download .deb files directly to darksite pool
# ---------------------------------------------------------------------------
# apt-get download always fetches to disk regardless of installed state,
# unlike apt-get -d install which skips packages already in the container.

log "Downloading ${#CLOSURE[@]} packages to darksite pool (skipping already-cached versions)..."
# Download one package at a time — batch apt-get download exits on the first
# unresolvable name (virtual packages), silently skipping everything after it.
# Skip packages whose exact version is already in the pool to avoid re-downloading
# 2500 packages on every build.
_dl_new=0
_dl_skip=0
_dl_fail=0
for _pkg in "${CLOSURE[@]}"; do
    # Resolve current candidate version from the apt cache
    _ver="$(apt-cache show "$_pkg" 2>/dev/null | awk '/^Version:/{print $2; exit}')"
    if [[ -n "$_ver" ]]; then
        # apt-get download writes epoch ':' as '%3a'; our rename step converts
        # those back, so check both forms.
        _f1="${APT_POOL}/${_pkg}_${_ver//:/%3a}_${ARCH}.deb"
        _f2="${APT_POOL}/${_pkg}_${_ver}_${ARCH}.deb"
        if [[ -f "$_f1" || -f "$_f2" ]]; then
            (( _dl_skip++ )) || true
            continue
        fi
    fi
    (cd "$APT_POOL" && apt-get download "$_pkg" 2>/dev/null) && {
        (( _dl_new++ )) || true
    } || {
        (( _dl_fail++ )) || true
    }
done
log "Download complete: ${_dl_new} new, ${_dl_skip} cached, ${_dl_fail} skipped (virtual/unavailable)"

# apt-get download saves epoch versions with URL-encoded colons in the filename
# (e.g. iputils-ping_3%3a20240905-3_amd64.deb). Python's http.server URL-decodes
# request paths (%3a → :), so it looks for the colon form. Rename to match.
log "Normalising epoch filenames (%3a → :) ..."
while IFS= read -r -d '' f; do
    mv "$f" "${f//%3a/:}"
done < <(find "$APT_POOL" -maxdepth 1 -name '*%3a*' -print0)

DEB_COUNT=0
while IFS= read -r -d '' _; do
    (( DEB_COUNT++ )) || true
done < <(find "$APT_POOL" -maxdepth 1 -name "*.deb" -print0)

log "Darksite pool: ${DEB_COUNT} packages"
[[ "$DEB_COUNT" -gt 0 ]] || die "No packages were downloaded to the darksite pool"

# ---------------------------------------------------------------------------
# Generate Packages index
# ---------------------------------------------------------------------------

log "Generating Packages index (dpkg-scanpackages)..."
mkdir -p "${APT_DISTS}"
(
    cd "$APT_ROOT"
    dpkg-scanpackages --multiversion pool/main 2>/dev/null \
        > "dists/${SUITE}/main/binary-${ARCH}/Packages" \
        || dpkg-scanpackages pool/main \
        > "dists/${SUITE}/main/binary-${ARCH}/Packages"
)
gzip -9c "${APT_DISTS}/Packages" > "${APT_DISTS}/Packages.gz"

PKG_LINES=$(wc -l < "${APT_DISTS}/Packages")
log "Packages index: ${PKG_LINES} lines"

# ---------------------------------------------------------------------------
# Generate Release file (unsigned — installer uses [trusted=yes])
# ---------------------------------------------------------------------------

log "Generating Release file..."

_size() { stat -c%s "$1"; }
_md5()  { md5sum "$1" | awk '{print $1}'; }
_sha256() { sha256sum "$1" | awk '{print $1}'; }

PKG_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages"
PKG_GZ_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages.gz"

cat > "${APT_ROOT}/dists/${SUITE}/Release" <<EOF
Origin: Debz Darksite
Label: Debz
Suite: ${SUITE}
Codename: ${SUITE}
Architectures: ${ARCH}
Components: main
Description: Debz offline APT repository — profile: ${PROFILE}, arch: ${ARCH}
Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')
MD5Sum:
 $(_md5 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_md5 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
SHA256:
 $(_sha256 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_sha256 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
EOF

# ---------------------------------------------------------------------------
# Write build manifest
# ---------------------------------------------------------------------------

mkdir -p "${DARKSITE_OUT}/manifests"
cat > "${DARKSITE_OUT}/manifests/build-manifest.json" <<EOF
{
  "build_id": "$(date -u +%Y%m%dT%H%M%SZ)",
  "profile": "${PROFILE}",
  "arch": "${ARCH}",
  "suite": "${SUITE}",
  "package_count": ${DEB_COUNT},
  "mirror_url": "http://127.0.0.1:3142/apt",
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# ---------------------------------------------------------------------------
# Download ZFSBootMenu pre-built EFI binary
# ---------------------------------------------------------------------------

log "Downloading ZFSBootMenu pre-built EFI binary..."
ZBM_BOOT_DIR="${DARKSITE_OUT}/boot"
mkdir -p "${ZBM_BOOT_DIR}"

if [[ ! -f "${ZBM_BOOT_DIR}/zfsbootmenu.EFI" ]]; then
    # Download the latest release EFI from ZFSBootMenu
    # This is a self-contained UEFI executable that works on any x86_64 UEFI system
    if curl -L --connect-timeout 30 --max-time 300 \
        -o "${ZBM_BOOT_DIR}/zfsbootmenu.EFI" \
        "https://get.zfsbootmenu.org/efi" 2>/dev/null; then
        log "ZFSBootMenu EFI downloaded: $(stat -c%s "${ZBM_BOOT_DIR}/zfsbootmenu.EFI") bytes"
    else
        log "WARNING: Failed to download ZFSBootMenu EFI — installer will download at install time"
        rm -f "${ZBM_BOOT_DIR}/zfsbootmenu.EFI"
    fi
else
    log "ZFSBootMenu EFI already cached: ${ZBM_BOOT_DIR}/zfsbootmenu.EFI"
fi

# ---------------------------------------------------------------------------
# Download GitHub release binaries (non-APT tools)
# Stored in ${DARKSITE_OUT}/binaries/<tool>/<version>/
# Firstboot scripts install them from here when running offline.
# ---------------------------------------------------------------------------

BINARIES_DIR="${DARKSITE_OUT}/binaries"
mkdir -p "${BINARIES_DIR}"

gh_latest_version() {
    # Resolve latest release tag for a GitHub repo (owner/repo)
    local repo="$1"
    curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

gh_download() {
    # Download a GitHub release asset if not already cached
    local repo="$1" version="$2" url="$3" dest="$4"
    if [[ -f "$dest" ]]; then
        log "  cached: $(basename "$dest")"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --connect-timeout 30 --max-time 300 -o "$dest" "$url" 2>/dev/null; then
        log "  downloaded: $(basename "$dest") ($(stat -c%s "$dest") bytes)"
    else
        log "  WARNING: failed to download $(basename "$dest") from ${repo}@${version}"
        rm -f "$dest"
        return 1
    fi
}

# ── Firecracker + jailer ──────────────────────────────────────────────────────
log "Fetching Firecracker binaries..."
FC_REPO="firecracker-microvm/firecracker"
FC_VER="$(gh_latest_version "$FC_REPO")"
if [[ -n "$FC_VER" ]]; then
    log "  Firecracker latest: ${FC_VER}"
    FC_DIR="${BINARIES_DIR}/firecracker/${FC_VER}"
    # Firecracker ships as a .tgz containing firecracker-vX.Y.Z-x86_64 + jailer-vX.Y.Z-x86_64
    FC_TGZ="${FC_DIR}/firecracker-${FC_VER}-x86_64.tgz"
    FC_URL="https://github.com/${FC_REPO}/releases/download/${FC_VER}/firecracker-${FC_VER}-x86_64.tgz"
    if gh_download "$FC_REPO" "$FC_VER" "$FC_URL" "$FC_TGZ"; then
        # Extract and rename to stable names for firstboot
        tar -xzf "$FC_TGZ" -C "$FC_DIR" 2>/dev/null || true
        # Rename versioned binaries to plain names
        find "$FC_DIR" -name "firecracker-*-x86_64" -exec mv {} "${FC_DIR}/firecracker" \; 2>/dev/null || true
        find "$FC_DIR" -name "jailer-*-x86_64"      -exec mv {} "${FC_DIR}/jailer"      \; 2>/dev/null || true
        chmod +x "${FC_DIR}/firecracker" "${FC_DIR}/jailer" 2>/dev/null || true
        log "  Firecracker ${FC_VER}: firecracker + jailer extracted"
        # Write version marker for firstboot
        echo "${FC_VER}" > "${FC_DIR}/VERSION"
    fi
else
    log "  WARNING: could not resolve Firecracker latest version — skipping"
fi

# ── Helm (Kubernetes package manager) ────────────────────────────────────────
log "Fetching Helm..."
HELM_REPO="helm/helm"
HELM_VER="$(gh_latest_version "$HELM_REPO")"
if [[ -n "$HELM_VER" ]]; then
    log "  Helm latest: ${HELM_VER}"
    HELM_DIR="${BINARIES_DIR}/helm/${HELM_VER}"
    HELM_TGZ="${HELM_DIR}/helm-${HELM_VER}-linux-amd64.tar.gz"
    HELM_URL="https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"
    if gh_download "$HELM_REPO" "$HELM_VER" "$HELM_URL" "$HELM_TGZ"; then
        tar -xzf "$HELM_TGZ" -C "$HELM_DIR" 2>/dev/null || true
        find "$HELM_DIR" -name helm -not -name "*.tar.gz" -exec mv {} "${HELM_DIR}/helm" \; 2>/dev/null || true
        chmod +x "${HELM_DIR}/helm" 2>/dev/null || true
        echo "${HELM_VER}" > "${HELM_DIR}/VERSION"
        log "  Helm ${HELM_VER}: OK"
    fi
else
    log "  WARNING: could not resolve Helm latest version — skipping"
fi

# ── k9s (Kubernetes TUI) ──────────────────────────────────────────────────────
log "Fetching k9s..."
K9S_REPO="derailed/k9s"
K9S_VER="$(gh_latest_version "$K9S_REPO")"
if [[ -n "$K9S_VER" ]]; then
    log "  k9s latest: ${K9S_VER}"
    K9S_DIR="${BINARIES_DIR}/k9s/${K9S_VER}"
    K9S_TGZ="${K9S_DIR}/k9s_Linux_amd64.tar.gz"
    K9S_URL="https://github.com/${K9S_REPO}/releases/download/${K9S_VER}/k9s_Linux_amd64.tar.gz"
    if gh_download "$K9S_REPO" "$K9S_VER" "$K9S_URL" "$K9S_TGZ"; then
        tar -xzf "$K9S_TGZ" -C "$K9S_DIR" 2>/dev/null || true
        [[ -f "${K9S_DIR}/k9s" ]] && chmod +x "${K9S_DIR}/k9s"
        echo "${K9S_VER}" > "${K9S_DIR}/VERSION"
        log "  k9s ${K9S_VER}: OK"
    fi
else
    log "  WARNING: could not resolve k9s latest version — skipping"
fi

# ── firectl (Firecracker CLI wrapper) ─────────────────────────────────────────
log "Fetching firectl..."
FIRECTL_REPO="firecracker-microvm/firectl"
FIRECTL_VER="$(gh_latest_version "$FIRECTL_REPO")"
if [[ -n "$FIRECTL_VER" ]]; then
    log "  firectl latest: ${FIRECTL_VER}"
    FIRECTL_DIR="${BINARIES_DIR}/firectl/${FIRECTL_VER}"
    FIRECTL_BIN="${FIRECTL_DIR}/firectl"
    FIRECTL_URL="https://github.com/${FIRECTL_REPO}/releases/download/${FIRECTL_VER}/firectl"
    if gh_download "$FIRECTL_REPO" "$FIRECTL_VER" "$FIRECTL_URL" "$FIRECTL_BIN"; then
        chmod +x "$FIRECTL_BIN"
        echo "${FIRECTL_VER}" > "${FIRECTL_DIR}/VERSION"
        log "  firectl ${FIRECTL_VER}: OK"
    fi
else
    log "  WARNING: could not resolve firectl latest version — skipping"
fi

# ── Count cached binaries ─────────────────────────────────────────────────────
BIN_COUNT=$(find "${BINARIES_DIR}" -type f -not -name VERSION | wc -l)
log "GitHub binaries cached: ${BIN_COUNT} files in ${BINARIES_DIR}"

log "====================================================="
log "Darksite build complete"
log "  APT packages: ${DEB_COUNT}"
log "  Binaries:     ${BIN_COUNT}"
log "  Repo:         ${APT_ROOT}"
log "  Mirror:       http://127.0.0.1:3142/apt/"
log "====================================================="
