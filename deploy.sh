#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# debz-free deploy.sh — build the ISO, that's it.
#
# Usage:
#   ./deploy.sh build           Build the ISO (requires builder image)
#   ./deploy.sh builder-image   Build the Docker builder container
#   ./deploy.sh clean           Remove build artifacts
#   ./deploy.sh latest-iso      Print path to the newest ISO
#   ./deploy.sh burn            Write latest ISO to USB  (USB_DEVICE=/dev/sdX)
# ---------------------------------------------------------------------------

ROOT="$(dirname "$(realpath "$0")")"
PROFILE="${PROFILE:-desktop}"
ARCH="${ARCH:-amd64}"
BUILDER_IMAGE="${BUILDER_IMAGE:-debz-live-builder:latest}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

require_docker() {
    command -v docker &>/dev/null || command -v podman &>/dev/null || \
        die "docker or podman is required"
}

cmd_builder_image() {
    require_docker
    log "Building builder container image..."
    docker build -t "$BUILDER_IMAGE" "$ROOT/builder"
    log "Builder image ready: $BUILDER_IMAGE"
}

cmd_build() {
    require_docker
    docker image inspect "$BUILDER_IMAGE" &>/dev/null || \
        die "Builder image not found. Run: ./deploy.sh builder-image"
    log "Building ISO (PROFILE=$PROFILE ARCH=$ARCH)..."
    mkdir -p "$OUTPUT_DIR"
    ROOT="$ROOT" PROFILE="$PROFILE" ARCH="$ARCH" \
        EDITION="free" OUTPUT_DIR="$OUTPUT_DIR" \
        bash "$ROOT/builder/container-build.sh"
    log "ISO ready:"
    cmd_latest_iso
}

cmd_latest_iso() {
    local iso
    iso="$(find "$OUTPUT_DIR" -name "*.iso" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)"
    if [[ -z "$iso" ]]; then
        die "No ISO found in $OUTPUT_DIR — run: ./deploy.sh build"
    fi
    echo "$iso"
}

cmd_clean() {
    log "Cleaning build artifacts..."
    rm -rf "$ROOT/live-build/chroot" \
           "$ROOT/live-build/binary" \
           "$ROOT/live-build/cache" \
           "$ROOT/live-build/output"
    log "Clean done."
}

cmd_burn() {
    local iso usb
    iso="$(cmd_latest_iso)"
    usb="${USB_DEVICE:-}"
    if [[ -z "$usb" ]]; then
        die "Set USB_DEVICE. Example: USB_DEVICE=/dev/sdb ./deploy.sh burn"
    fi
    [[ -b "$usb" ]] || die "Not a block device: $usb"
    log "Burning $iso → $usb  (this will ERASE $usb)"
    read -r -p "Type YES to confirm: " confirm
    [[ "$confirm" == "YES" ]] || die "Aborted."
    dd if="$iso" of="$usb" bs=4M conv=fsync status=progress
    sync
    log "Burn complete."
}

cmd_help() {
    cat <<'EOF'
debz-free — Debian 13 live ISO builder

  ./deploy.sh build           Build the ISO (requires builder image)
  ./deploy.sh builder-image   Build the Docker builder container
  ./deploy.sh clean           Remove build artifacts
  ./deploy.sh latest-iso      Print path to the newest ISO
  ./deploy.sh burn            Write latest ISO to USB (USB_DEVICE=/dev/sdX)

Variables:
  PROFILE=desktop|server      Install profile baked into live environment (default: desktop)
  ARCH=amd64                  Target architecture (default: amd64)
  USB_DEVICE=/dev/sdX         USB device for burn command

After building:
  - Load the ISO into your hypervisor (Proxmox, VMware, VirtualBox, QEMU)
  - Or burn to USB and boot bare metal
  - Boot → open Firefox → navigate to https://localhost:8080
EOF
}

subcommand="${1:-help}"
shift || true

case "$subcommand" in
    build)          cmd_build ;;
    builder-image)  cmd_builder_image ;;
    clean)          cmd_clean ;;
    latest-iso)     cmd_latest_iso ;;
    burn)           cmd_burn ;;
    help|--help|-h) cmd_help ;;
    *)              die "Unknown command: '$subcommand'. Run ./deploy.sh help" ;;
esac
