#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-iso.sh — runs INSIDE the builder container at /build/builder/build-iso.sh
# Drives live-build to produce the Debz live ISO.
# ---------------------------------------------------------------------------

PROFILE="${PROFILE:-desktop}"
EDITION="free"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/build/live-build/output}"
LOG_DIR="${LOG_DIR:-/build/live-build/logs}"
LB_ROOT="/build/live-build"
BUILD_DATE="$(date +%Y%m%d)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '[%s] [build-iso] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
    printf '[%s] [build-iso] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------

case "$PROFILE" in
    desktop|server) ;;
    *) die "Invalid PROFILE '$PROFILE'. Must be 'desktop' or 'server'." ;;
esac

case "$EDITION" in
    free|pro) ;;
    *) die "Invalid EDITION '$EDITION'. Must be 'free' or 'pro'." ;;
esac

case "$ARCH" in
    amd64|arm64) ;;
    *) die "Invalid ARCH '$ARCH'. Must be 'amd64' or 'arm64'." ;;
esac

# Map ARCH to live-build linux flavour (same names happen to match)
LB_LINUX_FLAVOUR="$ARCH"

# Map ARCH to ZFSBootMenu arch string
case "$ARCH" in
    amd64) ZBM_ARCH="x86_64" ;;
    arm64) ZBM_ARCH="aarch64" ;;
esac
export ZBM_ARCH

# Map ARCH to GRUB EFI package name
case "$ARCH" in
    amd64) GRUB_PKG="grub-efi-amd64" ;;
    arm64) GRUB_PKG="grub-efi-arm64" ;;
esac

log "Starting ISO build."
log "Profile:    $PROFILE"
log "Edition:    $EDITION"
log "Arch:       $ARCH"
log "ZBM arch:   $ZBM_ARCH"
log "GRUB pkg:   $GRUB_PKG"
log "LB root:    $LB_ROOT"
log "Output dir: $OUTPUT_DIR"
log "Log dir:    $LOG_DIR"
log "Date:       $BUILD_DATE"

# ---------------------------------------------------------------------------
# Validate required directories and tools
# ---------------------------------------------------------------------------

[[ -d "$LB_ROOT" ]] \
    || die "live-build root not found: $LB_ROOT"

for cmd in lb debootstrap mksquashfs xorriso; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required tool not found in container: $cmd"
done

# ---------------------------------------------------------------------------
# Prepare output and log directories
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

LOG_FILE="$LOG_DIR/build-${PROFILE}-${ARCH}-${BUILD_DATE}.log"
log "Build log: $LOG_FILE"

# ---------------------------------------------------------------------------
# Change into live-build working directory
# ---------------------------------------------------------------------------

cd "$LB_ROOT"

# ---------------------------------------------------------------------------
# Clean previous state
# ---------------------------------------------------------------------------

log "Pre-cleaning stale build state (chroot, binary, .build)..."
rm -rf "${LB_ROOT}/chroot" "${LB_ROOT}/binary" "${LB_ROOT}/.build"

log "Running: lb clean --purge"
lb clean --purge 2>&1 | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# Set active profile package list
# ---------------------------------------------------------------------------

PROFILE_LIST="$LB_ROOT/config/package-lists/profile-${PROFILE}.list.chroot"
ACTIVE_LIST="$LB_ROOT/config/package-lists/profile-active.list.chroot"

[[ -f "$PROFILE_LIST" ]] \
    || die "Profile package list not found: $PROFILE_LIST"

log "Copying profile package list: $PROFILE_LIST -> $ACTIVE_LIST"
cp "$PROFILE_LIST" "$ACTIVE_LIST"

# ---------------------------------------------------------------------------
# Configure live-build
# ---------------------------------------------------------------------------

# ── Disable Pro-only package lists for free edition ───────────────────────────
PRO_LISTS=(
    cloud-tools
    dns-stack
    ebpf
    security-tang-clevis
    template-master
)
if [[ "$EDITION" == "free" ]]; then
    log "Free edition: disabling Pro-only package lists"
    for _list in "${PRO_LISTS[@]}"; do
        _path="$LB_ROOT/config/package-lists/${_list}.list.chroot"
        if [[ -f "$_path" ]]; then
            mv "$_path" "${_path}.pro-disabled"
            log "  disabled: ${_list}.list.chroot"
        fi
    done
fi

# ── Bake edition into the chroot overlay ──────────────────────────────────────
log "Writing edition file: /etc/debz/edition = $EDITION"
mkdir -p "$LB_ROOT/config/includes.chroot/etc/debz"
printf '%s\n' "$EDITION" > "$LB_ROOT/config/includes.chroot/etc/debz/edition"

# ── Select web UI for this edition ────────────────────────────────────────────
WEBUI_SRC="/build/live-build/config/includes.chroot/usr/local/share/debz-webui/${EDITION}"
WEBUI_DST="/build/live-build/config/includes.chroot/usr/local/share/debz-webui/active"
if [[ -d "$WEBUI_SRC" ]]; then
    log "Activating ${EDITION} web UI from ${WEBUI_SRC}"
    rm -rf "$WEBUI_DST"
    cp -r "$WEBUI_SRC" "$WEBUI_DST"
else
    log "WARNING: no web UI found at ${WEBUI_SRC} — web UI may be missing"
fi

log "Running: lb config"
lb config \
    --distribution trixie \
    --architectures "$ARCH" \
    --binary-images iso-hybrid \
    --debian-installer none \
    --archive-areas "main contrib non-free non-free-firmware" \
    --linux-flavours "$LB_LINUX_FLAVOUR" \
    --bootappend-live "boot=live components username=live hostname=debz" \
    --iso-volume "Debz-${EDITION}-${BUILD_DATE}" \
    --image-name "debz-${EDITION}" \
    --grub-timeout 5 \
    2>&1 | tee -a "$LOG_FILE"

log "lb config complete."

# ---------------------------------------------------------------------------
# Write arch-specific package list
# ---------------------------------------------------------------------------

ARCH_PKG_LIST="$LB_ROOT/config/package-lists/arch-specific.list.chroot"
log "Writing arch-specific package list: $ARCH_PKG_LIST (ARCH=$ARCH)"
case "$ARCH" in
    amd64)
        printf '%s\n' \
            "grub-efi-amd64" \
            "grub-efi-amd64-signed" \
            "amd64-microcode" \
            "linux-headers-amd64" \
            > "$ARCH_PKG_LIST"
        ;;
    arm64)
        printf '%s\n' \
            "grub-efi-arm64" \
            "grub-efi-arm64-signed" \
            "linux-headers-arm64" \
            > "$ARCH_PKG_LIST"
        ;;
esac
log "Arch-specific package list written."

# ---------------------------------------------------------------------------
# Build darksite APT mirror (downloads packages, builds local repo)
# ---------------------------------------------------------------------------

DARKSITE_SCRIPT="/build/build/darksite/build-darksite.sh"
if [[ -x "$DARKSITE_SCRIPT" ]]; then
    log "Building darksite APT mirror (PROFILE=$PROFILE ARCH=$ARCH)..."
    PROFILE="$PROFILE" ARCH="$ARCH" SUITE="trixie" \
        bash "$DARKSITE_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    log "Darksite APT mirror build complete."
else
    log "Warning: darksite build script not found at $DARKSITE_SCRIPT — skipping offline mirror"
    log "Target installation will require internet connectivity."
fi

# ---------------------------------------------------------------------------
# Run live-build
# ---------------------------------------------------------------------------

GIT_SHA=$(git -C /build rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$GIT_SHA" > /build/live-build/config/includes.chroot/etc/debz-build-sha

log "Running: lb build  (this will take a while)"
lb build 2>&1 | tee -a "$LOG_FILE"

log "lb build complete."

# ── Restore Pro-only package lists after build ────────────────────────────────
if [[ "$EDITION" == "free" ]]; then
    for _list in "${PRO_LISTS[@]}"; do
        _path="$LB_ROOT/config/package-lists/${_list}.list.chroot.pro-disabled"
        [[ -f "$_path" ]] && mv "$_path" "${_path%.pro-disabled}"
    done
    log "Free edition: Pro-only package lists restored"
fi

# ---------------------------------------------------------------------------
# Locate built ISO
# ---------------------------------------------------------------------------

log "Scanning for ISO in: $LB_ROOT"
log "Directory contents:"
ls -lh "$LB_ROOT"/*.iso "$LB_ROOT"/*.hybrid.iso 2>/dev/null || ls -lh "$LB_ROOT"/ 2>/dev/null | grep -i iso || log "  (no *.iso files found at top level)"

ISO_PATH=""
while IFS= read -r -d '' f; do
    ISO_PATH="$f"
done < <(find "$LB_ROOT" -maxdepth 2 -name "*.iso" -print0 2>/dev/null | sort -z)

[[ -n "$ISO_PATH" ]] \
    || die "No ISO file found after lb build completed."

# ---------------------------------------------------------------------------
# Move ISO to output directory
# ---------------------------------------------------------------------------

ISO_DEST="$OUTPUT_DIR/$(basename "$ISO_PATH")"
if [[ "$(realpath "$ISO_PATH")" != "$(realpath "$ISO_DEST" 2>/dev/null || echo '')" ]]; then
    log "Moving ISO: $ISO_PATH -> $ISO_DEST"
    mv "$ISO_PATH" "$ISO_DEST"
else
    log "ISO already in output directory: $ISO_DEST"
fi

# ---------------------------------------------------------------------------
# Export MOK cert alongside ISO for Proxmox/KVM NVRAM pre-enrollment
# The cert lives at /etc/debz/mok/mok.der inside the chroot.
# deploy.sh uses it to inject the key into the VM's OVMF NVRAM before boot.
# ---------------------------------------------------------------------------
MOK_SRC="/build/live-build/chroot/etc/debz/mok/mok.der"
MOK_DEST="$OUTPUT_DIR/debz-mok.der"
if [[ -f "$MOK_SRC" ]]; then
    cp "$MOK_SRC" "$MOK_DEST"
    log "MOK cert exported: $MOK_DEST"
else
    log "WARNING: MOK cert not found at $MOK_SRC — NVRAM pre-enrollment will not be available"
fi

# ---------------------------------------------------------------------------
# Generate sha256 checksum
# ---------------------------------------------------------------------------

log "Generating SHA256 checksum..."
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$ISO_DEST")" \
    > "$(basename "$ISO_DEST").sha256")

SHA256_FILE="${ISO_DEST}.sha256"
log "Checksum: $(cat "$SHA256_FILE")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

ISO_SIZE="$(du -sh "$ISO_DEST" | cut -f1)"
log "Build complete."
log "  ISO:      $ISO_DEST"
log "  Size:     $ISO_SIZE"
log "  Checksum: $SHA256_FILE"
log "  Log:      $LOG_FILE"

echo "$ISO_DEST"
