#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Debz deploy.sh — top-level entry point for all build + deploy operations
# ---------------------------------------------------------------------------

ROOT="$(dirname "$(realpath "$0")")"

# Auto-load debz.env (contains secrets — gitignored, never committed)
# shellcheck disable=SC1091
[[ -f "$ROOT/debz.env" ]] && source "$ROOT/debz.env"

PROFILE="${PROFILE:-desktop}"
EDITION="free"
ARCH="${ARCH:-amd64}"
BUILDER_IMAGE="${BUILDER_IMAGE:-debz-live-builder:latest}"
BUILDER_CONTAINER="${BUILDER_CONTAINER:-debz-free-build-$$}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"
LOG_DIR="${LOG_DIR:-$ROOT/live-build/logs}"

# ---------------------------------------------------------------------------
# Host build log — stream all output to /home/todd/logs/ in real time
# Creates a timestamped file per run + a stable "latest.log" symlink.
# Both stdout and stderr are captured; output still appears on the terminal.
# ---------------------------------------------------------------------------
TODD_LOG_DIR="${TODD_LOG_DIR:-/home/todd/logs}"
mkdir -p "$TODD_LOG_DIR" "$LOG_DIR"
_DEBZ_RUN_LOG="${TODD_LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S)-${1:-run}.log"
# Start tee before any output so the very first log() line is captured
exec > >(tee -a "$_DEBZ_RUN_LOG") 2>&1
ln -sf "$_DEBZ_RUN_LOG" "${TODD_LOG_DIR}/latest.log"
ln -sf "$_DEBZ_RUN_LOG" "${TODD_LOG_DIR}/latest-${EDITION}.log"

# ---------------------------------------------------------------------------
# Proxmox / VM configuration
# ---------------------------------------------------------------------------

PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}"
PROXMOX_NODE="${PROXMOX_NODE:-fiend}"                  # Proxmox cluster node name
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"               # API token ID  (e.g. root@pam!root)
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"       # API token secret UUID
PROXMOX_ISO_STORE="${PROXMOX_ISO_STORE:-local}"        # Proxmox storage for ISOs
PROXMOX_VM_STORE="${PROXMOX_VM_STORE:-local-zfs}"      # Proxmox storage for VM boot disk
PROXMOX_DATA_STORE="${PROXMOX_DATA_STORE:-fireball}"   # Proxmox storage for extra data disks (fireball zpool)

VMID="${VMID:-901}"
VM_NAME="${VM_NAME:-debz-free}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_GB="${VM_DISK_GB:-40}"
VM_EXTRA_DISKS="${VM_EXTRA_DISKS:-0}"                  # extra data disks for ZFS pool topology testing
VM_EXTRA_DISK_GB="${VM_EXTRA_DISK_GB:-20}"             # Size of each extra data disk in GB
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_SECURE_BOOT="${VM_SECURE_BOOT:-no}"
VM_TPM="${VM_TPM:-yes}"

# Seed disk — FAT32 image (DEBZ-SEED label) containing answers.env.
# Picked up by debz-autoinstall.service on the live ISO to drive unattended install.
SEED_ANSWERS="${SEED_ANSWERS:-$ROOT/live-build/config/includes.chroot/etc/debz/answers/zfs-single-disk.env}"
SEED_DISK_ENABLED="${SEED_DISK_ENABLED:-yes}"

_debz_exit_handler() {
    local code=$?
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ $code -ne 0 ]]; then
        printf '\n[%s] [deploy] ════ FAILED (exit %d) — see %s ════\n' \
            "$ts" "$code" "${_DEBZ_RUN_LOG:-/home/todd/logs/latest.log}"
    else
        printf '\n[%s] [deploy] ════ DONE — log: %s ════\n' \
            "$ts" "${_DEBZ_RUN_LOG:-/home/todd/logs/latest.log}"
    fi
}
trap '_debz_exit_handler' EXIT

# ---------------------------------------------------------------------------
# USB burn configuration
# ---------------------------------------------------------------------------

USB_DEVICE="${USB_DEVICE:-}"
USB_BURN_ON_DEPLOY="${USB_BURN_ON_DEPLOY:-yes}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '[%s] [deploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
    printf '[%s] [deploy] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Proxmox REST API helpers (token auth — no SSH required)
# ---------------------------------------------------------------------------

_proxmox_check_token() {
    [[ -n "${PROXMOX_TOKEN_ID:-}" ]]     || die "PROXMOX_TOKEN_ID not set — source debz.env or set it explicitly"
    [[ -n "${PROXMOX_TOKEN_SECRET:-}" ]] || die "PROXMOX_TOKEN_SECRET not set — source debz.env or set it explicitly"
}

# proxmox_api METHOD /path [curl-args...]
proxmox_api() {
    local method="${1:?method required}"
    local path="${2:?path required}"
    shift 2
    _proxmox_check_token
    curl -sf --insecure \
        -X "$method" \
        -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
        "https://${PROXMOX_HOST}:8006/api2/json${path}" \
        "$@"
}

# proxmox_vm_destroy VMID — force-stop and delete VM + all disks; non-fatal
proxmox_vm_destroy() {
    local vmid="${1:?}"
    log "  Killing VM ${vmid}..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${PROXMOX_HOST}" \
        "qm stop ${vmid} --skiplock 2>/dev/null; qm destroy ${vmid} --purge 2>/dev/null" || true
    log "  VM ${vmid} dead"
}

# proxmox_vm_destroy_by_name NAME — look up VMID by name, then destroy; non-fatal
proxmox_vm_destroy_by_name() {
    local name="${1:?}"
    _proxmox_check_token
    local json vmid
    json=$(proxmox_api GET "/nodes/${PROXMOX_NODE}/qemu" 2>/dev/null || true)
    if [[ -z "$json" ]]; then
        log "  Could not reach Proxmox — skipping '${name}' VM destroy"
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        vmid=$(printf '%s' "$json" \
            | jq -r --arg n "$name" '.data[] | select(.name==$n) | .vmid' \
            | head -1)
    else
        # fallback: grep per-object block for the matching name then extract vmid
        vmid=$(printf '%s' "$json" \
            | grep -oP '\{[^}]*"name"\s*:\s*"'"${name}"'"[^}]*\}' \
            | grep -oP '"vmid"\s*:\s*\K[0-9]+' \
            | head -1 || true)
    fi
    if [[ -z "$vmid" ]]; then
        log "  No VM named '${name}' found on Proxmox — nothing to destroy"
        return 0
    fi
    proxmox_vm_destroy "${vmid}"
}

# proxmox_iso_upload ISO_PATH STORAGE — upload ISO via API; polls until visible
proxmox_iso_upload() {
    local iso_path="${1:?}"
    local storage="${2:?}"
    local iso_name
    iso_name="$(basename "${iso_path}")"

    log "Uploading ISO ${iso_name} to Proxmox storage '${storage}' (this may take a few minutes)..."
    proxmox_api POST "/nodes/${PROXMOX_NODE}/storage/${storage}/upload" \
        --max-time 1800 \
        -F "content=iso" \
        -F "filename=@${iso_path}"

    log "Waiting for ${iso_name} to appear in pvesm..."
    local i
    for i in $(seq 1 30); do
        proxmox_api GET "/nodes/${PROXMOX_NODE}/storage/${storage}/content?content=iso" \
            2>/dev/null | grep -q "\"${iso_name}\"" && {
            log "ISO ${iso_name} confirmed in storage '${storage}'"
            return 0
        }
        sleep 2
    done
    log "WARNING: pvesm did not confirm ISO — will attempt attach anyway"
}

# debz_seed_disk_build — create a 32 MB FAT32 image (label DEBZ-SEED) containing
# answers.env. The debz-autoinstall.service on the live ISO reads this and runs
# debz-install-target unattended.
# Args: answers_file output_image
debz_seed_disk_build() {
    local answers="${1:?}"
    local out="${2:?}"
    [[ -f "$answers" ]] || die "Seed disk: answers file not found: $answers"
    require_cmd mkfs.fat
    log "Building seed disk from $answers → $out"
    dd if=/dev/zero of="$out" bs=1M count=32 2>/dev/null
    mkfs.fat -F 32 -n "DEBZ-SEED" "$out" >/dev/null
    local mnt
    mnt="$(mktemp -d)"
    mount -o loop "$out" "$mnt"
    cp "$answers" "$mnt/answers.env"
    sync
    umount "$mnt"
    rmdir  "$mnt"
    log "Seed disk built: $out ($(du -sh "$out" | cut -f1))"
}

# proxmox_seed_upload — upload seed disk image to Proxmox ISO storage as .iso
# Args: seed_img storage
# Returns: the ISO name as stored in Proxmox (printed to stdout)
proxmox_seed_upload() {
    local seed_img="${1:?}"
    local storage="${2:-$PROXMOX_ISO_STORE}"
    local seed_name
    seed_name="debz-seed-$(date +%Y%m%d%H%M%S).iso"
    log "Uploading seed disk as $seed_name to $storage..."
    curl -fsSk \
        -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
        -F "content=iso" \
        -F "filename=@${seed_img};filename=${seed_name}" \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/storage/${storage}/upload" \
        >/dev/null
    # Wait for it to appear
    local retries=20
    while (( retries-- > 0 )); do
        proxmox_api GET "/nodes/${PROXMOX_NODE}/storage/${storage}/content?content=iso" \
            2>/dev/null | grep -q "\"${seed_name}\"" && {
            log "Seed disk $seed_name confirmed in storage"
            echo "$seed_name"
            return 0
        }
        sleep 2
    done
    log "WARNING: seed disk upload not confirmed — will try to attach anyway"
    echo "$seed_name"
}

# proxmox_mok_enroll — inject debz MOK cert into Proxmox VM OVMF NVRAM
# Runs after proxmox_vm_create so the EFI disk zvol exists.
# The VM must be stopped. Injects the cert into db so ZFS loads without
# any MOK enrollment prompt — fully automated Secure Boot for KVM/Proxmox.
# Args: vmid mok_der
proxmox_mok_enroll() {
    local vmid="${1:?}" mok_der="${2:?}"
    local virt_fw_vars

    virt_fw_vars="$(command -v virt-fw-vars 2>/dev/null || \
        find /root/venvs -name 'virt-fw-vars' 2>/dev/null | head -1)"
    if [[ -z "$virt_fw_vars" ]]; then
        log "WARNING: virt-fw-vars not found — skipping NVRAM MOK pre-enrollment"
        log "         Install via: pip3 install virt-firmware"
        return 0
    fi

    if [[ ! -f "$mok_der" ]]; then
        log "WARNING: MOK cert not found at $mok_der — skipping NVRAM pre-enrollment"
        return 0
    fi

    log "Injecting debz MOK cert into VM ${vmid} OVMF NVRAM..."

    # Find the EFI disk zvol for this VM on Proxmox
    local efi_zvol
    efi_zvol="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${PROXMOX_HOST}" \
        "pvesm list local-zfs 2>/dev/null | awk '/vm-${vmid}-disk/{print \$1}' | head -1" 2>/dev/null)"
    # Map pvesm name (local-zfs:vm-N-disk-X) to block device path
    local zvol_path
    zvol_path="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${PROXMOX_HOST}" \
        "pvesm path ${efi_zvol} 2>/dev/null" 2>/dev/null)"

    if [[ -z "$zvol_path" ]]; then
        log "WARNING: Cannot find EFI disk zvol for VM ${vmid} — skipping NVRAM enrollment"
        return 0
    fi
    log "  EFI disk: $efi_zvol → $zvol_path"

    # Pull OVMF VARS from Proxmox, inject cert, push back
    local tmp_vars tmp_enrolled
    tmp_vars="$(mktemp --suffix=.fd)"
    tmp_enrolled="$(mktemp --suffix=.fd)"

    # The EFI disk is 4MB: first 2MB = CODE (read-only), second 2MB = VARS
    # Extract just the VARS section (offset 2MB)
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${PROXMOX_HOST}" \
        "dd if=${zvol_path} bs=1M skip=2 count=2 2>/dev/null" > "$tmp_vars"

    # Inject debz MOK cert into db (Secure Boot allow list)
    "$virt_fw_vars" \
        --input  "$tmp_vars" \
        --enroll-cert db "$mok_der" \
        --secure-boot \
        --output "$tmp_enrolled" 2>/dev/null && {

        # Write modified VARS back to zvol (offset 2MB)
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${PROXMOX_HOST}" \
            "dd of=${zvol_path} bs=1M seek=2 conv=notrunc 2>/dev/null" < "$tmp_enrolled"
        log "  MOK cert enrolled — VM ${vmid} will boot ZFS with Secure Boot, no prompts"
    } || {
        log "WARNING: virt-fw-vars injection failed — falling back to manual MOK enrollment"
    }

    rm -f "$tmp_vars" "$tmp_enrolled"
}

# proxmox_vm_create — create + configure + start a VM via the REST API
# Uses JSON body — form-encoded data breaks compound Proxmox property strings
# (net0, efidisk0, tpmstate0) in PVE 8.x due to comma/colon parsing.
# Args: vmid vmname vmem vcores vdisk vbridge vmstore datastore
#       isostore isoname vtpm vextradisks vextradiskgb pre_enrolled [seedname]
proxmox_vm_create() {
    local vmid="${1:?}"     vmname="${2:?}"     vmem="${3:?}"
    local vcores="${4:?}"   vdisk="${5:?}"      vbridge="${6:?}"
    local vmstore="${7:?}"  datastore="${8:?}"  isostore="${9:?}"
    local isoname="${10:?}" vtpm="${11:?}"      vextradisks="${12:?}"
    local vextradiskgb="${13:?}" pre_enrolled="${14:?}" seedname="${15:-}"

    log "Creating VM ${vmid} (${vmname}) via Proxmox API..."

    # Destroy any existing VM with this ID first
    proxmox_api DELETE \
        "/nodes/${PROXMOX_NODE}/qemu/${vmid}?purge=1&destroy-unreferenced-disks=1" \
        2>/dev/null || true
    sleep 2

    # Create VM — JSON body required. Form-encoded data misparses compound
    # Proxmox property strings like "virtio,bridge=vmbr0" (net0) and
    # "local-zfs:4,efitype=4m" (efidisk0) in PVE 8.x.
    proxmox_api POST "/nodes/${PROXMOX_NODE}/qemu" \
        -H "Content-Type: application/json" \
        -d "{
          \"vmid\": ${vmid},
          \"name\": \"${vmname}\",
          \"memory\": ${vmem},
          \"cores\": ${vcores},
          \"cpu\": \"host\",
          \"sockets\": 1,
          \"machine\": \"q35\",
          \"ostype\": \"l26\",
          \"net0\": \"virtio,bridge=${vbridge}\",
          \"scsihw\": \"virtio-scsi-single\",
          \"scsi0\": \"${vmstore}:${vdisk}\",
          \"serial0\": \"socket\",
          \"agent\": \"1\",
          \"bios\": \"ovmf\",
          \"efidisk0\": \"${vmstore}:4,efitype=4m,pre-enrolled-keys=${pre_enrolled}\"
        }"

    # TPM (separate PUT — Proxmox allocates storage on the fly)
    if [[ "${vtpm}" == "yes" ]]; then
        proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
            -H "Content-Type: application/json" \
            -d "{\"tpmstate0\": \"${vmstore}:4,version=v2.0\"}"
    fi

    # Extra data disks
    local idx
    for (( idx=1; idx<=vextradisks; idx++ )); do
        proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
            -H "Content-Type: application/json" \
            -d "{\"scsi${idx}\": \"${datastore}:${vextradiskgb}\"}"
    done

    # Attach ISO as CDROM
    local retries=10
    while (( retries-- > 0 )); do
        proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
            -H "Content-Type: application/json" \
            -d "{\"ide2\": \"${isostore}:iso/${isoname},media=cdrom\"}" \
            2>/dev/null && break
        sleep 1
    done

    # Attach seed disk as ide3 if provided (debz-autoinstall.service reads it)
    if [[ -n "${seedname}" ]]; then
        proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
            -H "Content-Type: application/json" \
            -d "{\"ide3\": \"${isostore}:iso/${seedname},media=cdrom\"}" || \
            log "WARNING: seed disk attach failed — autoinstall will not run"
        log "Seed disk attached as ide3: $seedname"
    fi

    # Boot order: disk first, CDROM (live ISO) as fallback.
    # On first boot the disk is empty so OVMF falls through to the CDROM (live ISO).
    # After install ZFSBootMenu is on the disk — it wins on next boot.
    proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
        -H "Content-Type: application/json" \
        -d "{\"boot\": \"order=scsi0;ide2;ide3\"}"

    # Start VM
    proxmox_api POST "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start"

    log "VM ${vmid} (${vmname}) created and started"
}

latest_iso() {
    local iso=""
    while IFS= read -r -d '' f; do
        iso="$f"
    done < <(find "$OUTPUT_DIR" -name "*.iso" -print0 2>/dev/null | sort -z)
    echo "$iso"
}

# ---------------------------------------------------------------------------
# Detect container runtime (prefer docker, fallback to podman)
# ---------------------------------------------------------------------------

detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1; then
        echo "podman"
    else
        die "Neither docker nor podman found. Install one to continue."
    fi
}

# ---------------------------------------------------------------------------
# Subcommand: builder-image
# ---------------------------------------------------------------------------

cmd_builder_image() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building builder image '$BUILDER_IMAGE' using $runtime..."

    [[ -f "$ROOT/builder/Dockerfile" ]] \
        || die "builder/Dockerfile not found at $ROOT/builder/Dockerfile"

    "$runtime" build \
        --tag "$BUILDER_IMAGE" \
        --file "$ROOT/builder/Dockerfile" \
        "$ROOT/builder"

    log "Builder image '$BUILDER_IMAGE' built successfully."
}

# ---------------------------------------------------------------------------
# Subcommand: build / iso
# ---------------------------------------------------------------------------

cmd_build() {
    local runtime
    runtime="$(detect_runtime)"
    log "Starting ISO build. PROFILE=$PROFILE ARCH=$ARCH"

    # Ensure builder image exists; auto-build if missing
    if ! "$runtime" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
        log "Builder image '$BUILDER_IMAGE' not found. Building it now..."
        cmd_builder_image
    fi

    mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

    log "Delegating to builder/container-build.sh..."
    # shellcheck disable=SC2097,SC2098
    PROFILE="$PROFILE" \
    EDITION="$EDITION" \
    ARCH="$ARCH" \
    ROOT="$ROOT" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    LOG_DIR="$LOG_DIR" \
    BUILDER_IMAGE="$BUILDER_IMAGE" \
    BUILDER_CONTAINER="$BUILDER_CONTAINER" \
        "$ROOT/builder/container-build.sh"
}

# ---------------------------------------------------------------------------
# Subcommand: build-free  (shorthand for EDITION=free build)
# ---------------------------------------------------------------------------
cmd_build_free() {
    EDITION=free cmd_build
}

# ---------------------------------------------------------------------------
# Subcommand: build-pro  (shorthand for EDITION=pro build)
# ---------------------------------------------------------------------------
cmd_build_pro() {
    EDITION=pro cmd_build
}

# ---------------------------------------------------------------------------
# Subcommand: build-all  (builds both editions sequentially)
# ---------------------------------------------------------------------------
cmd_build_all() {
    log "=== Building FREE edition ==="
    EDITION=free cmd_build
    log "=== Building PRO edition ==="
    EDITION=pro cmd_build
    log "=== Both ISOs complete ==="
    ls -lh "$OUTPUT_DIR"/debz-*.iso 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommand: clean
# ---------------------------------------------------------------------------

cmd_clean() {
    local runtime
    runtime="$(detect_runtime)"
    log "Cleaning local build artifacts..."

    # live-build work directories
    for d in chroot binary .build; do
        local p="$ROOT/live-build/$d"
        if [[ -d "$p" ]]; then
            log "  Removing $p"
            rm -rf "$p"
        fi
    done

    # Output ISO + logs
    if [[ -d "$OUTPUT_DIR" ]]; then
        log "  Removing $OUTPUT_DIR"
        rm -rf "$OUTPUT_DIR"
    fi

    local work_dir="$ROOT/live-build/work"
    if [[ -d "$work_dir" ]]; then
        log "  Removing $work_dir"
        rm -rf "$work_dir"
    fi

    # Kill any lingering builder containers
    local containers
    containers=$("$runtime" ps -a \
        --filter "name=debz-free-build" \
        --filter "name=debz-resume" \
        -q 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        log "  Removing builder containers..."
        # shellcheck disable=SC2086
        "$runtime" rm -f $containers 2>/dev/null || true
    fi

    # Destroy the test VM on Proxmox by name (non-fatal — skipped if PROXMOX_HOST unset)
    if [[ -n "${PROXMOX_HOST:-}" ]]; then
        proxmox_vm_destroy_by_name "${VM_NAME}"
    else
        log "  PROXMOX_HOST not set — skipping '${VM_NAME}' VM destroy"
    fi

    log "Clean complete."
}

# ---------------------------------------------------------------------------
# Subcommand: burn  (write ISO to USB)
# ---------------------------------------------------------------------------

cmd_burn() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR. Run 'build' first."

    # Auto-detect USB device if not set
    if [[ -z "$USB_DEVICE" ]]; then
        log "USB_DEVICE not set. Scanning for removable block devices..."
        local candidates=()
        while IFS= read -r dev; do
            local rm_flag
            rm_flag="$(cat "/sys/block/$(basename "$dev")/removable" 2>/dev/null || echo 0)"
            [[ "$rm_flag" == "1" ]] && candidates+=("$dev")
        done < <(find /dev -maxdepth 1 -name 'sd[a-z]' | sort)

        if [[ "${#candidates[@]}" -eq 0 ]]; then
            die "No removable USB device found. Set USB_DEVICE=/dev/sdX explicitly."
        elif [[ "${#candidates[@]}" -gt 1 ]]; then
            die "Multiple removable devices found: ${candidates[*]}. Set USB_DEVICE=/dev/sdX explicitly."
        fi
        USB_DEVICE="${candidates[0]}"
        log "Auto-detected USB device: $USB_DEVICE"
    fi

    [[ -b "$USB_DEVICE" ]] || die "USB_DEVICE=$USB_DEVICE is not a block device"

    local iso_size
    iso_size="$(du -sh "$iso" | cut -f1)"
    log "Burning $iso ($iso_size) to $USB_DEVICE..."
    log "WARNING: ALL DATA ON $USB_DEVICE WILL BE DESTROYED"

    dd if="$iso" of="$USB_DEVICE" bs=4M status=progress oflag=sync conv=fsync
    sync

    log "USB burn complete: $USB_DEVICE"
    log "You can now remove the USB key and test."
}

# ---------------------------------------------------------------------------
# Subcommand: deploy  (upload to Proxmox + create VM + optional USB burn)
# ---------------------------------------------------------------------------

cmd_deploy() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR. Run 'build' first."

    local iso_name iso_size
    iso_name="$(basename "$iso")"
    iso_size="$(du -sh "$iso" | cut -f1)"

    local pre_enrolled=0
    [[ "$VM_SECURE_BOOT" == "yes" ]] && pre_enrolled=1

    log "Deploying Debz ISO to Proxmox."
    log "  ISO:          $iso ($iso_size)"
    log "  Proxmox host: $PROXMOX_HOST"
    log "  VMID:         $VMID  name: $VM_NAME"
    log "  Memory:       ${VM_MEMORY}MB  cores: $VM_CORES  disk: ${VM_DISK_GB}GB"
    log "  Storage:      $PROXMOX_VM_STORE  bridge: $VM_BRIDGE"
    log "  Extra disks:  ${VM_EXTRA_DISKS}x ${VM_EXTRA_DISK_GB}GB from ${PROXMOX_DATA_STORE}"
    log "  Secure Boot:  $VM_SECURE_BOOT  TPM: $VM_TPM"

    # -------------------------------------------------------------------------
    # 1. Upload ISO to Proxmox
    # -------------------------------------------------------------------------

    proxmox_iso_upload "$iso" "$PROXMOX_ISO_STORE"

    # -------------------------------------------------------------------------
    # 2. Build + upload seed disk (triggers unattended install on first boot)
    # -------------------------------------------------------------------------

    local seed_name=""
    if [[ "${SEED_DISK_ENABLED}" == "yes" && -f "${SEED_ANSWERS}" ]]; then
        local seed_img="/tmp/debz-seed-$$.img"
        debz_seed_disk_build "${SEED_ANSWERS}" "${seed_img}"
        seed_name="$(proxmox_seed_upload "${seed_img}" "${PROXMOX_ISO_STORE}")"
        rm -f "${seed_img}"
    else
        log "SEED_DISK_ENABLED=${SEED_DISK_ENABLED} — skipping seed disk (manual install required)"
    fi

    # -------------------------------------------------------------------------
    # 3. Destroy + recreate VM on Proxmox via REST API
    # -------------------------------------------------------------------------

    proxmox_vm_create \
        "$VMID" "$VM_NAME" "$VM_MEMORY" "$VM_CORES" \
        "$VM_DISK_GB" "$VM_BRIDGE" "$PROXMOX_VM_STORE" "$PROXMOX_DATA_STORE" \
        "$PROXMOX_ISO_STORE" "$iso_name" "$VM_TPM" \
        "$VM_EXTRA_DISKS" "$VM_EXTRA_DISK_GB" "$pre_enrolled" \
        "${seed_name}"

    # -------------------------------------------------------------------------
    # 3a. Pre-enroll debz MOK cert into VM OVMF NVRAM (Proxmox/KVM only)
    # Injects the debz signing key directly into the UEFI db so ZFS modules
    # are trusted without any MOK enrollment prompt on first boot.
    # Only runs when mok.der is present alongside the ISO.
    # -------------------------------------------------------------------------
    if [[ "$VM_SECURE_BOOT" == "yes" ]]; then
        local mok_der
        mok_der="$(dirname "$iso")/debz-mok.der"
        proxmox_mok_enroll "$VMID" "$mok_der"
    fi

    log "VM $VMID ($VM_NAME) created and started."
    if [[ -n "${seed_name}" ]]; then
        log "  → Unattended install running via seed disk (debz-autoinstall.service)"
        log "  → Watch: Proxmox console or journalctl on the VM"
        log "  → Log:   /var/log/installer/ on the VM"
        log "  → VM will power off when install completes — then remove ISO and boot"
    else
        log "  → Manual install required: SSH in and run debz-install-target"
    fi

    # -------------------------------------------------------------------------
    # 3. Burn USB (default: yes)
    # -------------------------------------------------------------------------

    if [[ "$USB_BURN_ON_DEPLOY" == "yes" ]]; then
        log "USB_BURN_ON_DEPLOY=yes — burning ISO to USB..."
        cmd_burn
    else
        log "USB_BURN_ON_DEPLOY=$USB_BURN_ON_DEPLOY — skipping USB burn."
    fi

    log "Deploy complete.  VM $VMID booting from ISO on Proxmox $PROXMOX_HOST"
}

# ---------------------------------------------------------------------------
# Subcommand: full  (hard clean + rebuild + deploy)
# ---------------------------------------------------------------------------

cmd_full() {
    local runtime
    runtime="$(detect_runtime)"

    log "=== FULL: hard clean + rebuild builder + build ISO + deploy ==="

    # 0. Nuke the existing VM on Proxmox before anything else so it isn't
    #    still running when we try to redeploy at the end.
    proxmox_vm_destroy "${VMID}"

    # 1. Local clean
    cmd_clean

    # 2. Remove builder image to force a fresh build
    if "$runtime" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
        log "Removing builder image $BUILDER_IMAGE..."
        "$runtime" rmi "$BUILDER_IMAGE" || true
    fi

    # 3. Prune dangling images to reclaim space
    log "Pruning dangling Docker/Podman images..."
    "$runtime" image prune -f 2>/dev/null || true

    # 4. Rebuild builder image
    cmd_builder_image

    # 5. Build ISO
    cmd_build

    # 6. Deploy to Proxmox + burn USB
    cmd_deploy

    log "=== FULL complete ==="
}

# ---------------------------------------------------------------------------
# Subcommand: server-deploy  (opinionated server build + Proxmox deploy)
# ---------------------------------------------------------------------------
#
# Best-practice defaults for a headless debz server node:
#   PROFILE=server          server ISO (no GNOME, SSH-only)
#   VM_MEMORY=8192          8 GB RAM
#   VM_CORES=8              8 vCPUs
#   VM_DISK_GB=80           80 GB boot pool
#   VM_EXTRA_DISKS=2        2 extra data disks for ZFS mirror testing
#   VM_EXTRA_DISK_GB=100    100 GB each
#   VM_SECURE_BOOT=yes      UEFI + Secure Boot enrolled
#   VM_TPM=yes              TPM 2.0 attached
#   USB_BURN_ON_DEPLOY=no   no USB burn (server workflow)
#
# Override any var on the command line:
#   VMID=910 VM_MEMORY=16384 ./deploy.sh server-deploy
#
cmd_server_deploy() {
    # Apply server defaults — only set if caller hasn't overridden
    : "${PROFILE:=server}"
    : "${VM_MEMORY:=8192}"
    : "${VM_CORES:=8}"
    : "${VM_DISK_GB:=80}"
    : "${VM_EXTRA_DISKS:=2}"
    : "${VM_EXTRA_DISK_GB:=100}"
    : "${VM_SECURE_BOOT:=yes}"
    : "${VM_TPM:=yes}"
    : "${USB_BURN_ON_DEPLOY:=no}"
    : "${VMID:=910}"
    : "${VM_NAME:=debz-server}"

    log "=== server-deploy: PROFILE=${PROFILE}  VMID=${VMID}  ${VM_MEMORY}MB / ${VM_CORES}vCPU / ${VM_DISK_GB}GB ==="
    log "    Secure Boot: ${VM_SECURE_BOOT}  TPM: ${VM_TPM}  Extra disks: ${VM_EXTRA_DISKS}×${VM_EXTRA_DISK_GB}GB"

    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST is required. Set it in debz.env or pass on the command line."

    # Build server ISO if none exists yet
    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    if [[ -z "${iso}" ]] || [[ "$(basename "${iso}")" != *server* ]]; then
        log "No server ISO found — building one now (PROFILE=server)..."
        cmd_build
    else
        log "Using existing ISO: $(basename "${iso}")"
    fi

    cmd_deploy

    log "=== server-deploy complete — VM ${VMID} (${VM_NAME}) booting on ${PROXMOX_HOST} ==="
    log "    SSH will be available once the live session starts: ssh live@<vm-ip>"
    log "    Web UI: http://<vm-ip>:8080"
    log "    TUI installer will auto-launch on the console."
}

# ---------------------------------------------------------------------------
# Subcommand: proxmox-deploy  (spin up a Proxmox VE node on debz base)
# ---------------------------------------------------------------------------
# Installs debz server profile, then firstboot installs proxmox-ve on top.
# The node self-registers its API token with the master on first boot.
#
# Default VMID 905 — override on the command line:
#   VMID=908 VM_MEMORY=32768 ./deploy.sh proxmox-deploy
#
cmd_proxmox_deploy() {
    : "${PROFILE:=server}"
    : "${VM_MEMORY:=16384}"
    : "${VM_CORES:=8}"
    : "${VM_DISK_GB:=120}"
    : "${VM_EXTRA_DISKS:=0}"
    : "${VM_SECURE_BOOT:=no}"
    : "${VM_TPM:=no}"
    : "${USB_BURN_ON_DEPLOY:=no}"
    : "${VMID:=905}"
    : "${VM_NAME:=proxmox-01}"

    log "=== proxmox-deploy: VMID=${VMID}  ${VM_MEMORY}MB / ${VM_CORES}vCPU / ${VM_DISK_GB}GB ==="
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST is required. Set it in debz.env or pass on the command line."

    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR}. Run './deploy.sh build' first."
    log "Using ISO: $(basename "${iso}")"

    cmd_spawn

    log "=== proxmox-deploy complete — VM ${VMID} (${VM_NAME}) booting on ${PROXMOX_HOST} ==="
    log "    SSH to live session, then:"
    log "    sudo debz-install-target --config /etc/debz/answers/template-proxmox.env"
    log "    On first reboot, Proxmox VE will be installed automatically."
}

# ---------------------------------------------------------------------------
# Subcommand: monitoring-deploy  (Prometheus + Grafana reporting node)
# ---------------------------------------------------------------------------
# Deploys a dedicated monitoring node running Prometheus, Grafana, and
# node_exporter. Registers with the master automatically on first boot.
#
# Default VMID 907 — override on the command line:
#   VMID=909 ./deploy.sh monitoring-deploy
#
cmd_monitoring_deploy() {
    : "${PROFILE:=server}"
    : "${VM_MEMORY:=4096}"
    : "${VM_CORES:=4}"
    : "${VM_DISK_GB:=80}"
    : "${VM_EXTRA_DISKS:=0}"
    : "${VM_SECURE_BOOT:=no}"
    : "${VM_TPM:=no}"
    : "${USB_BURN_ON_DEPLOY:=no}"
    : "${VMID:=907}"
    : "${VM_NAME:=monitoring-01}"

    log "=== monitoring-deploy: VMID=${VMID}  ${VM_MEMORY}MB / ${VM_CORES}vCPU / ${VM_DISK_GB}GB ==="
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST is required. Set it in debz.env or pass on the command line."

    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR}. Run './deploy.sh build' first."
    log "Using ISO: $(basename "${iso}")"

    cmd_spawn

    log "=== monitoring-deploy complete — VM ${VMID} (${VM_NAME}) booting ==="
    log "    SSH to live session, then:"
    log "    sudo debz-install-target --config /etc/debz/answers/template-monitoring.env"
    log "    On first reboot, Prometheus + Grafana install automatically."
    log "    Grafana: http://10.100.10.26:3000  (admin / debz-admin)"
    log "    Prometheus: http://10.100.10.26:9090"
}

# ---------------------------------------------------------------------------
# Subcommand: landing-deploy  (SFTP landing zone / secure drop zone)
# ---------------------------------------------------------------------------
# Deploys a hardened SFTP-only drop zone. Each SFTP user gets a ZFS dataset
# with quota isolation and a chroot jail. ZFS encryption on by default.
#
# Default VMID 908 — override on the command line:
#   VMID=909 ./deploy.sh landing-deploy
#
cmd_landing_deploy() {
    : "${PROFILE:=server}"
    : "${VM_MEMORY:=2048}"
    : "${VM_CORES:=2}"
    : "${VM_DISK_GB:=40}"
    : "${VM_EXTRA_DISKS:=0}"
    : "${VM_SECURE_BOOT:=no}"
    : "${VM_TPM:=no}"
    : "${USB_BURN_ON_DEPLOY:=no}"
    : "${VMID:=908}"
    : "${VM_NAME:=landing-01}"

    log "=== landing-deploy: VMID=${VMID}  ${VM_MEMORY}MB / ${VM_CORES}vCPU / ${VM_DISK_GB}GB ==="
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST is required. Set it in debz.env or pass on the command line."

    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR}. Run './deploy.sh build' first."
    log "Using ISO: $(basename "${iso}")"

    cmd_spawn

    log "=== landing-deploy complete — VM ${VMID} (${VM_NAME}) booting ==="
    log "    SSH to live session, then:"
    log "    sudo debz-install-target --config /etc/debz/answers/template-landing.env"
    log "    On first reboot, SFTP landing zone configures automatically."
    log "    Add SFTP users: debz-landing-adduser <username>"
}

# ---------------------------------------------------------------------------
# Subcommand: lb-deploy  (HAProxy + Keepalived Kubernetes load balancer)
# ---------------------------------------------------------------------------
# Deploys a dedicated HA load balancer for Kubernetes API servers.
# HAProxy fronts all k8s-control nodes on the VIP; Keepalived provides the
# floating VIP for HA. Registers VIP with master so kubeadm can point
# --control-plane-endpoint at the VIP.
#
# Default VMID 909, VIP 10.100.10.200 — override on the command line:
#   VMID=910 DEBZ_LB_VIP=10.100.10.201 ./deploy.sh lb-deploy
#
cmd_lb_deploy() {
    : "${PROFILE:=server}"
    : "${VM_MEMORY:=2048}"
    : "${VM_CORES:=2}"
    : "${VM_DISK_GB:=20}"
    : "${VM_EXTRA_DISKS:=0}"
    : "${VM_SECURE_BOOT:=no}"
    : "${VM_TPM:=no}"
    : "${USB_BURN_ON_DEPLOY:=no}"
    : "${VMID:=909}"
    : "${VM_NAME:=lb-01}"

    log "=== lb-deploy: VMID=${VMID}  ${VM_MEMORY}MB / ${VM_CORES}vCPU / ${VM_DISK_GB}GB ==="
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST is required. Set it in debz.env or pass on the command line."

    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR}. Run './deploy.sh build' first."
    log "Using ISO: $(basename "${iso}")"

    cmd_spawn

    log "=== lb-deploy complete — VM ${VMID} (${VM_NAME}) booting ==="
    log "    SSH to live session, then:"
    log "    sudo debz-install-target --config /etc/debz/answers/template-lb.env"
    log "    On first reboot, HAProxy + Keepalived configure automatically."
    log "    Default VIP: 10.100.10.200:6443  (Kubernetes API)"
    log "    Add backends: debz-lb-addbackend <name> <ip> [port]"
}

# ---------------------------------------------------------------------------
# Subcommand: vmdk  (convert latest ISO → VMDK)
# ---------------------------------------------------------------------------

cmd_vmdk() {
    require_cmd qemu-img
    # Convert a golden qcow2 image → VMDK (stream-optimized, works with VMware + VirtualBox)
    # Use GOLDEN_INPUT to override source; defaults to latest golden server image.
    local src="${GOLDEN_INPUT:-}"
    if [[ -z "$src" ]]; then
        src="$(find "${OUTPUT_DIR}/images" -maxdepth 1 -name '*.qcow2' 2>/dev/null | sort | tail -1 || true)"
    fi
    if [[ -z "$src" || ! -f "$src" ]]; then
        die "No golden qcow2 image found. Run 'make images' first, or set GOLDEN_INPUT=/path/to/image.qcow2"
    fi

    local base out
    base="$(basename "$src" .qcow2)"
    out="${src%.qcow2}.vmdk"

    log "Converting golden image → VMDK (stream-optimized)"
    log "  Source: $src"
    log "  Output: $out"
    qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized "$src" "$out"
    (cd "$(dirname "$out")" && sha256sum "$(basename "$out")") > "${out}.sha256"
    log "VMDK ready: $out ($(du -sh "$out" | cut -f1))"
}

cmd_images() {
    log "Building VM disk images (all formats)"
    bash "${ROOT}/builder/build-images.sh" "$@"
}

# ---------------------------------------------------------------------------
# Subcommand: rootfs  (extract squashfs → raw ext4 rootfs image)
# ---------------------------------------------------------------------------

cmd_rootfs() {
    require_cmd unsquashfs
    require_cmd mkfs.ext4
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR. Run 'build' first."

    local base
    base="$(basename "$iso" .iso)"
    local work="$OUTPUT_DIR/rootfs-work-$$"
    local squashfs="$work/squashfs"
    local rootfs_img="$OUTPUT_DIR/${base}-rootfs.ext4"

    log "Extracting squashfs from ISO..."
    mkdir -p "$work"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local mnt="$work/iso-mnt"
    mkdir -p "$mnt"
    mount -o loop,ro "$iso" "$mnt" || die "Failed to mount ISO"
    local sqfs_path
    sqfs_path="$(find "$mnt" -name 'filesystem.squashfs' | head -n1)"
    [[ -n "$sqfs_path" ]] || { umount "$mnt"; die "filesystem.squashfs not found in ISO"; }

    unsquashfs -d "$squashfs" "$sqfs_path"
    umount "$mnt"

    local size_mb
    size_mb=$(( $(du -sm "$squashfs" | cut -f1) + 512 ))
    log "Creating ext4 image: ${size_mb}MB → $rootfs_img"
    dd if=/dev/zero of="$rootfs_img" bs=1M count="$size_mb" status=none
    mkfs.ext4 -q -L debz-root "$rootfs_img"

    local img_mnt="$work/img-mnt"
    mkdir -p "$img_mnt"
    mount -o loop "$rootfs_img" "$img_mnt"
    cp -a "$squashfs/." "$img_mnt/"
    umount "$img_mnt"

    log "rootfs image ready: $rootfs_img"
}

# ---------------------------------------------------------------------------
# Subcommand: firecracker  (build Firecracker microVM bundle)
# ---------------------------------------------------------------------------

cmd_firecracker() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR. Run 'build' first."

    local base
    base="$(basename "$iso" .iso)"
    local bundle_dir="$OUTPUT_DIR/${base}-firecracker"
    mkdir -p "$bundle_dir"

    log "Building Firecracker bundle in $bundle_dir ..."

    # Build rootfs first (reuse cmd_rootfs logic)
    local rootfs_img="$OUTPUT_DIR/${base}-rootfs.ext4"
    if [[ ! -f "$rootfs_img" ]]; then
        log "rootfs image not found — building it now..."
        cmd_rootfs
    fi

    cp "$rootfs_img" "$bundle_dir/rootfs.ext4"

    # Extract kernel from ISO
    local mnt="$OUTPUT_DIR/fc-iso-mnt-$$"
    mkdir -p "$mnt"
    mount -o loop,ro "$iso" "$mnt" || die "Failed to mount ISO"
    local vmlinuz
    vmlinuz="$(find "$mnt" -name 'vmlinuz*' | head -n1)"
    if [[ -n "$vmlinuz" ]]; then
        cp "$vmlinuz" "$bundle_dir/vmlinuz"
        log "Kernel: $vmlinuz → $bundle_dir/vmlinuz"
    else
        log "WARNING: vmlinuz not found in ISO — add kernel manually"
    fi
    umount "$mnt"
    rmdir "$mnt"

    # Write Firecracker VM config
    cat > "$bundle_dir/vm-config.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "vmlinuz",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ro root=/dev/vda"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 1024
  }
}
EOF

    # Write convenience run script
    cat > "$bundle_dir/run.sh" <<'EORUN'
#!/usr/bin/env bash
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec firecracker \
    --no-api \
    --config-file "$BUNDLE_DIR/vm-config.json"
EORUN
    chmod +x "$bundle_dir/run.sh"

    log "Firecracker bundle ready: $bundle_dir"
    log "  rootfs:    $bundle_dir/rootfs.ext4"
    log "  kernel:    $bundle_dir/vmlinuz"
    log "  config:    $bundle_dir/vm-config.json"
    log "  run:       $bundle_dir/run.sh"
}

# ---------------------------------------------------------------------------
# Subcommand: golden  (build a golden qcow2 image via headless QEMU autoinstall)
# ---------------------------------------------------------------------------

cmd_golden() {
    require_cmd qemu-system-x86_64
    require_cmd qemu-img
    require_cmd mkfs.fat

    local TEMPLATE="${TEMPLATE:-}"
    local GOLDEN_OUTPUT="${GOLDEN_OUTPUT:-}"
    local GOLDEN_FORMAT="${GOLDEN_FORMAT:-qcow2}"
    local GOLDEN_ISO="${GOLDEN_ISO:-}"
    local GOLDEN_SIZE="${GOLDEN_SIZE:-40}"

    [[ -n "$TEMPLATE" ]] \
        || die "TEMPLATE must be set (master|kvm|storage|vdi). e.g. TEMPLATE=kvm ./deploy.sh golden"

    log "Building golden $TEMPLATE image (format=$GOLDEN_FORMAT size=${GOLDEN_SIZE}G)..."

    local golden_script="$ROOT/live-build/config/includes.chroot/usr/local/sbin/debz-golden"
    [[ -f "$golden_script" ]] || die "debz-golden not found at $golden_script"

    local args=(--template "$TEMPLATE" --format "$GOLDEN_FORMAT" --size "$GOLDEN_SIZE")
    [[ -n "$GOLDEN_OUTPUT" ]] && args+=(--output "$GOLDEN_OUTPUT")
    [[ -n "$GOLDEN_ISO"    ]] && args+=(--iso    "$GOLDEN_ISO")

    bash "$golden_script" "${args[@]}"

    log "Golden image build complete."
}

# ---------------------------------------------------------------------------
# Subcommand: stamp  (CoW-clone a golden image and stamp per-node identities)
# ---------------------------------------------------------------------------

cmd_stamp() {
    require_cmd qemu-img
    require_cmd qemu-nbd

    local TEMPLATE="${TEMPLATE:-}"
    local STAMP_COUNT="${STAMP_COUNT:-1}"
    local STAMP_BASE_HOSTNAME="${STAMP_BASE_HOSTNAME:-}"
    local STAMP_BASE_INDEX="${STAMP_BASE_INDEX:-1}"
    local STAMP_OUTPUT_DIR="${STAMP_OUTPUT_DIR:-/var/lib/debz/clones}"

    [[ -n "$TEMPLATE" ]] \
        || die "TEMPLATE must be set (master|kvm|storage|vdi). e.g. TEMPLATE=kvm STAMP_COUNT=3 ./deploy.sh stamp"

    local golden="/var/lib/debz/golden/golden-${TEMPLATE}.qcow2"
    [[ -f "$golden" ]] \
        || die "Golden image not found: $golden — run 'TEMPLATE=$TEMPLATE ./deploy.sh golden' first"

    [[ -n "$STAMP_BASE_HOSTNAME" ]] || STAMP_BASE_HOSTNAME="${TEMPLATE}"

    local stamp_script="$ROOT/live-build/config/includes.chroot/usr/local/sbin/debz-stamp-identity"
    [[ -f "$stamp_script" ]] || die "debz-stamp-identity not found at $stamp_script"

    mkdir -p "$STAMP_OUTPUT_DIR"

    log "Stamping $STAMP_COUNT clone(s) from $golden → $STAMP_OUTPUT_DIR"
    log "  Hostname prefix: $STAMP_BASE_HOSTNAME  Index start: $STAMP_BASE_INDEX"

    local i
    for (( i=0; i<STAMP_COUNT; i++ )); do
        local idx=$(( STAMP_BASE_INDEX + i ))
        local padded
        padded="$(printf '%02d' "$idx")"
        local hostname="${STAMP_BASE_HOSTNAME}-${padded}"
        local clone="${STAMP_OUTPUT_DIR}/${hostname}.qcow2"

        log "  [$((i+1))/$STAMP_COUNT] Creating CoW clone: $clone"
        qemu-img create -q -f qcow2 -b "$golden" -F qcow2 "$clone"

        log "  [$((i+1))/$STAMP_COUNT] Stamping identity: hostname=$hostname index=$idx"
        bash "$stamp_script" \
            --image    "$clone" \
            --hostname "$hostname" \
            --template "$TEMPLATE" \
            --index    "$idx"

        log "  [$((i+1))/$STAMP_COUNT] Done: $clone"
    done

    log "Stamp complete. $STAMP_COUNT clone(s) written to $STAMP_OUTPUT_DIR"
    log "  Next: use 'debz-spawn --type vm --host <kvm-host> --name <hostname>' to deploy"
}

# ---------------------------------------------------------------------------
# Subcommand: aws-ami  (import raw disk image → AWS AMI via aws-cli)
# ---------------------------------------------------------------------------

cmd_aws_ami() {
    require_cmd aws
    require_cmd qemu-img

    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR. Run 'build' first."

    local AWS_BUCKET="${AWS_BUCKET:-}"
    local AWS_REGION="${AWS_REGION:-us-east-1}"
    local AWS_AMI_NAME="${AWS_AMI_NAME:-debz-$(date -u +%Y%m%d%H%M%S)}"

    [[ -n "$AWS_BUCKET" ]] \
        || die "AWS_BUCKET must be set (e.g. AWS_BUCKET=my-bucket ./deploy.sh aws-ami)"

    local base
    base="$(basename "$iso" .iso)"
    local raw_img="$OUTPUT_DIR/${base}.raw"

    log "Converting ISO → raw disk image: $raw_img"
    qemu-img convert -f raw -O raw "$iso" "$raw_img"

    log "Uploading raw image to s3://${AWS_BUCKET}/${base}.raw ..."
    aws s3 cp "$raw_img" "s3://${AWS_BUCKET}/${base}.raw" \
        --region "$AWS_REGION"

    log "Importing as snapshot via EC2 import-snapshot..."
    local task_id
    task_id="$(aws ec2 import-snapshot \
        --region "$AWS_REGION" \
        --description "Debz $base" \
        --disk-container "Format=RAW,UserBucket={S3Bucket=${AWS_BUCKET},S3Key=${base}.raw}" \
        --query 'ImportTaskId' \
        --output text)"

    log "Import task started: $task_id"
    log "Waiting for snapshot import to complete (this may take several minutes)..."

    local snapshot_id=""
    local status=""
    while true; do
        status="$(aws ec2 describe-import-snapshot-tasks \
            --region "$AWS_REGION" \
            --import-task-ids "$task_id" \
            --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' \
            --output text)"
        log "  Status: $status"
        if [[ "$status" == "completed" ]]; then
            snapshot_id="$(aws ec2 describe-import-snapshot-tasks \
                --region "$AWS_REGION" \
                --import-task-ids "$task_id" \
                --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
                --output text)"
            break
        elif [[ "$status" == "deleted" || "$status" == "deleting" ]]; then
            die "Snapshot import failed (status=$status)"
        fi
        sleep 15
    done

    log "Snapshot ready: $snapshot_id"
    log "Registering AMI: $AWS_AMI_NAME ..."
    local ami_id
    ami_id="$(aws ec2 register-image \
        --region "$AWS_REGION" \
        --name "$AWS_AMI_NAME" \
        --description "Debz Linux - $base" \
        --architecture x86_64 \
        --virtualization-type hvm \
        --root-device-name /dev/xvda \
        --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"SnapshotId\":\"${snapshot_id}\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
        --boot-mode uefi \
        --query 'ImageId' \
        --output text)"

    log "AMI registered: $ami_id  (region: $AWS_REGION)"
    log "  Name: $AWS_AMI_NAME"
    log "  Snapshot: $snapshot_id"
}

# ---------------------------------------------------------------------------
# Subcommand: spawn  (create a new VM from an already-uploaded ISO)
# Skips ISO upload and USB burn — just creates and starts a new VM.
# Override VMID and VM_NAME to distinguish from the primary test VM.
# ---------------------------------------------------------------------------

cmd_spawn() {
    # Resolve the ISO name to use — prefer explicit ISO_NAME, else latest local ISO,
    # else the newest ISO already visible on Proxmox.
    local iso_name="${ISO_NAME:-}"
    if [[ -z "$iso_name" ]]; then
        local local_iso
        local_iso="$(latest_iso)"
        if [[ -n "$local_iso" ]]; then
            iso_name="$(basename "$local_iso")"
        else
            # Fall back to whatever the newest ISO is on Proxmox (parse volid from API JSON)
            log "No local ISO found — querying Proxmox for latest ISO..."
            iso_name="$(proxmox_api GET \
                "/nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORE}/content?content=iso" \
                2>/dev/null \
                | grep -oP '"volid":"[^"]+\.iso"' \
                | sed 's/.*://;s/"//g' \
                | sort | tail -1)" || true
            [[ -n "$iso_name" ]] \
                || die "No ISO found locally or on Proxmox. Run 'build' then 'deploy' first."
        fi
    fi

    local pre_enrolled=0
    [[ "$VM_SECURE_BOOT" == "yes" ]] && pre_enrolled=1

    log "Spawning VM from existing ISO."
    log "  ISO:          $iso_name  (already on Proxmox — no upload)"
    log "  Proxmox host: $PROXMOX_HOST"
    log "  VMID:         $VMID  name: $VM_NAME"
    log "  Memory:       ${VM_MEMORY}MB  cores: $VM_CORES  disk: ${VM_DISK_GB}GB"
    log "  Storage:      $PROXMOX_VM_STORE  bridge: $VM_BRIDGE"
    log "  Extra disks:  ${VM_EXTRA_DISKS}x ${VM_EXTRA_DISK_GB}GB from ${PROXMOX_DATA_STORE}"
    log "  Secure Boot:  $VM_SECURE_BOOT  TPM: $VM_TPM"

    proxmox_vm_create \
        "$VMID" "$VM_NAME" "$VM_MEMORY" "$VM_CORES" \
        "$VM_DISK_GB" "$VM_BRIDGE" "$PROXMOX_VM_STORE" "$PROXMOX_DATA_STORE" \
        "$PROXMOX_ISO_STORE" "$iso_name" "$VM_TPM" \
        "$VM_EXTRA_DISKS" "$VM_EXTRA_DISK_GB" "$pre_enrolled"

    log "VM $VMID ($VM_NAME) created and started from $iso_name."
    log "Open Proxmox console to watch the live environment."
}

# ---------------------------------------------------------------------------
# Subcommand: validate
# ---------------------------------------------------------------------------

cmd_validate() {
    log "Running validation checks..."

    local errors=0

    # Shellcheck all scripts outside legacy/
    if ! command -v shellcheck >/dev/null 2>&1; then
        log "WARNING: shellcheck not installed — skipping script linting"
    else
        log "Running shellcheck on all .sh files (excluding legacy/ and build artifacts)..."
        while IFS= read -r -d '' script; do
            # Skip legacy code, live-build generated artifacts, and agent worktrees
            [[ "$script" == *"/legacy/"* ]]             && continue
            [[ "$script" == *"/live-build/chroot/"* ]]  && continue
            [[ "$script" == *"/live-build/binary/"* ]]  && continue
            [[ "$script" == *"/live-build/cache/"*  ]]  && continue
            [[ "$script" == *"/.claude/worktrees/"* ]]  && continue
            log "  Checking: $script"
            if ! shellcheck -S warning "$script" 2>&1; then
                log "  FAIL: $script"
                (( errors++ )) || true
            fi
        done < <(find "$ROOT" -name "*.sh" -print0 2>/dev/null)
    fi

    # Required directories
    local required_dirs=(
        "$ROOT/builder"
        "$ROOT/build/darksite"
        "$ROOT/live-build/config/package-lists"
        "$ROOT/live-build/config/hooks/live"
        "$ROOT/live-build/config/hooks/normal"
        "$ROOT/live-build/config/includes.chroot/usr/lib/debz-installer/lib"
        "$ROOT/live-build/config/includes.chroot/usr/lib/debz-installer/backend"
        "$ROOT/profiles"
    )
    for d in "${required_dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            log "FAIL: Required directory missing: $d"
            (( errors++ )) || true
        else
            log "  OK dir: $d"
        fi
    done

    # Required files
    local required_files=(
        "$ROOT/builder/Dockerfile"
        "$ROOT/builder/container-build.sh"
        "$ROOT/builder/build-iso.sh"
        "$ROOT/live-build/config/package-lists/base.list.chroot"
        "$ROOT/live-build/config/package-lists/profile-desktop.list.chroot"
        "$ROOT/live-build/config/package-lists/profile-server.list.chroot"
        "$ROOT/profiles/server.yaml"
        "$ROOT/profiles/desktop.yaml"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            log "FAIL: Required file missing: $f"
            (( errors++ )) || true
        else
            log "  OK file: $f"
        fi
    done

    if [[ "$errors" -gt 0 ]]; then
        die "Validation failed with $errors error(s)."
    fi

    log "Validation passed."
}

# ---------------------------------------------------------------------------
# Subcommand: release
# ---------------------------------------------------------------------------

_release_version() {
    # Priority: VERSION file at repo root → /etc/debz-version → date-based fallback
    if [[ -f "$ROOT/VERSION" ]]; then
        tr -d '[:space:]' < "$ROOT/VERSION"
    elif [[ -f /etc/debz-version ]]; then
        tr -d '[:space:]' < /etc/debz-version
    else
        date -u '+%Y.%m'
    fi
}

_bump_version() {
    # Increments the patch number in VERSION: beta_0.07 → beta_0.08, beta_0.99 → beta_0.100
    local vfile="$ROOT/VERSION"
    local cur
    cur="$(_release_version)"
    # Extract prefix (e.g. "beta_0.") and number (e.g. "07")
    local prefix num new_num new_ver
    if [[ "$cur" =~ ^(.+\.)([0-9]+)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"
        # Increment, preserving zero-padding width (min 2 digits)
        new_num="$(printf '%02d' $(( 10#$num + 1 )))"
        new_ver="${prefix}${new_num}"
    else
        # Fallback: append .1
        new_ver="${cur}.1"
    fi
    echo "$new_ver" > "$vfile"
    log "Version bumped: ${cur} → ${new_ver}"
    echo "$new_ver"
}

_update_download_page() {
    # Patch html/index.html with the current version + download URL.
    # Uses DL_URL (home server) if set, otherwise falls back to archive.org.
    local version
    version="$(_release_version)"
    local iso_name
    iso_name="$(basename "$(latest_iso 2>/dev/null || echo 'debz-desktop-amd64.hybrid.iso')")"

    # Prefer self-hosted download server; fall back to archive.org
    local dl_url
    if [[ -n "${DL_URL:-}" ]]; then
        dl_url="${DL_URL}/${iso_name}"
        log "Download URL: self-hosted → ${dl_url}"
    else
        local identifier="${IA_IDENTIFIER:-debz-linux}"
        dl_url="https://archive.org/download/${identifier}/${iso_name}"
        log "Download URL: archive.org → ${dl_url}"
    fi

    local html="$ROOT/html/index.html"
    log "Patching download page: version=${version}"

    sed -i "s|&#8987;&nbsp; Release pending|<a href=\"${dl_url}\" class=\"btn btn-primary\" target=\"_blank\">&#8595;&nbsp; debz ${version} (AMD64)</a>|g" "$html"
    sed -i "s|<span class=\"btn btn-primary\" style=\"opacity:0.55;cursor:default;\">&#8987;&amp;nbsp; Coming Soon</span>|<a href=\"${dl_url}\" class=\"btn btn-primary\" target=\"_blank\">&#8595;&amp;nbsp; Download debz ${version}</a>|g" "$html"
    sed -i "s|<span class=\"btn btn-primary\" style=\"opacity:0.55;cursor:default;font-size:0.75rem;padding:0.4rem 0.9rem;\">&#8987; Coming Soon</span>|<a href=\"${dl_url}\" class=\"btn btn-primary\" style=\"font-size:0.75rem;padding:0.4rem 0.9rem;\" target=\"_blank\">&#8595; Download</a>|g" "$html"

    log "Download page updated → ${dl_url}"
}

cmd_full_release() {
    # Full release pipeline:
    #   1. Bump VERSION
    #   2. Full build (clean + rebuild + deploy to Proxmox + burn USB)
    #   3. Package release artifacts (checksums, RELEASE.md)
    #   4. Upload ISO to archive.org
    #   5. Patch website download page with new version + link
    #   6. Deploy website to debz.ca

    [[ -f "$ROOT/debz.env" ]] && source "$ROOT/debz.env"

    local new_version
    new_version="$(_bump_version)"
    log "══════════════════════════════════════════"
    log "  debz full-release → ${new_version}"
    log "══════════════════════════════════════════"

    # Commit bumped version before build so it's baked in
    git -C "$ROOT" add VERSION
    git -C "$ROOT" commit -m "chore: bump version to ${new_version}" 2>/dev/null || true

    # Full build + Proxmox deploy + USB burn
    cmd_full

    # Package checksums + RELEASE.md
    cmd_release

    # Upload ISO — prefer self-hosted (DL_HOST set) over archive.org
    if [[ -n "${DL_HOST:-}" ]]; then
        cmd_dl_upload
    else
        cmd_ia_upload
    fi

    # Patch download page + deploy site
    _update_download_page
    cmd_site_deploy

    log "══════════════════════════════════════════"
    log "  Release ${new_version} complete!"
    log "  ISO: https://archive.org/download/${IA_IDENTIFIER:-debz-linux}/"
    log "  Site: https://debz.ca"
    log "══════════════════════════════════════════"
}

cmd_release() {
    log "Packaging release artifacts..."

    [[ -d "$OUTPUT_DIR" ]] \
        || die "No output directory at $OUTPUT_DIR. Run 'build' first."

    local version
    version="$(_release_version)"
    local release_dir="$ROOT/releases/v${version}"

    # Confirm at least one ISO exists before doing any work
    local iso
    iso="$(latest_iso)" \
        || die "No ISO files found in $OUTPUT_DIR — run 'build' first."
    [[ -n "$iso" ]] \
        || die "No ISO files found in $OUTPUT_DIR — run 'build' first."

    mkdir -p "$release_dir"

    local iso_name sha256 sha512
    iso_name="$(basename "$iso")"

    log "ISO: $iso_name"
    log "Copying ISO to $release_dir/ ..."
    cp "$iso" "$release_dir/$iso_name"

    # SHA256
    log "Generating SHA256 checksum..."
    sha256="$(sha256sum "$iso" | awk '{print $1}')"
    printf '%s  %s\n' "$sha256" "$iso_name" > "$release_dir/${iso_name}.sha256"
    log "  SHA256: $sha256"

    # SHA512
    log "Generating SHA512 checksum..."
    sha512="$(sha512sum "$iso" | awk '{print $1}')"
    printf '%s  %s\n' "$sha512" "$iso_name" > "$release_dir/${iso_name}.sha512"
    log "  SHA512: ${sha512:0:16}..."

    # GPG signature (optional — skip gracefully if GPG_KEY not set)
    if [[ -n "${GPG_KEY:-}" ]]; then
        log "Signing ISO with GPG key: $GPG_KEY"
        gpg --batch --yes --armor \
            --local-user "$GPG_KEY" \
            --detach-sign \
            --output "$release_dir/${iso_name}.asc" \
            "$release_dir/$iso_name" \
            && log "  Signature: $release_dir/${iso_name}.asc" \
            || log "  WARNING: GPG signing failed — signature omitted."
    else
        log "GPG_KEY not set — skipping signature."
    fi

    # RELEASE.md
    local release_date
    release_date="$(date -u '+%Y-%m-%d')"
    cat > "$release_dir/RELEASE.md" <<EOF
# debz v${version} — Release Notes

**Version:** ${version}
**Date:** ${release_date}
**ISO:** \`${iso_name}\`

## Checksums

| Algorithm | Hash |
|-----------|------|
| SHA256 | \`${sha256}\` |
| SHA512 | \`${sha512}\` |

## Verification

\`\`\`bash
# Verify SHA256
sha256sum -c ${iso_name}.sha256

# Verify SHA512
sha512sum -c ${iso_name}.sha512
EOF

    if [[ -n "${GPG_KEY:-}" ]] && [[ -f "$release_dir/${iso_name}.asc" ]]; then
        cat >> "$release_dir/RELEASE.md" <<EOF

# Verify GPG signature
gpg --verify ${iso_name}.asc ${iso_name}
\`\`\`
EOF
    else
        printf '%s\n' '```' >> "$release_dir/RELEASE.md"
    fi

    cat >> "$release_dir/RELEASE.md" <<EOF

## Full Changelog

See [CHANGELOG.md](../../CHANGELOG.md) for the complete change history.
EOF

    log "RELEASE.md written."
    log ""
    log "Release artifacts: $release_dir"
    log "  $iso_name"
    log "  ${iso_name}.sha256"
    log "  ${iso_name}.sha512"
    [[ -f "$release_dir/${iso_name}.asc" ]] && log "  ${iso_name}.asc"
    log "  RELEASE.md"
    printf '%s\n' "$release_dir"
}

# ---------------------------------------------------------------------------
# Subcommand: tree
# ---------------------------------------------------------------------------

cmd_tree() {
    require_cmd tree
    log "Repository structure (excluding work/output/debs/isos/legacy):"
    tree -I 'work|output|*.deb|*.iso|legacy' "$ROOT"
}

# ---------------------------------------------------------------------------
# Subcommand: site-deploy  (push html/ to debz.ca)
# ---------------------------------------------------------------------------

SITE_USER="${SITE_USER:-foundrybot}"
SITE_HOST="${SITE_HOST:-68.66.226.120}"
SITE_PATH="${SITE_PATH:-/home/foundrybot/public_html}"
SITE_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

cmd_site_deploy() {
    local src="/root/debz-web/"
    [[ -d "${src}" ]] || die "debz-web not found at ${src} — expected /root/debz-web/"

    log "Deploying website to ${SITE_USER}@${SITE_HOST}:${SITE_PATH}"

    # Verify SSH is reachable
    # shellcheck disable=SC2086
    ssh ${SITE_SSH_OPTS} "${SITE_USER}@${SITE_HOST}" 'exit 0' \
        || die "Cannot reach ${SITE_USER}@${SITE_HOST} — check SSH key and connectivity"

    # Sync html/ → public_html/
    # --delete removes files on remote that no longer exist locally
    # --checksum skips files that haven't changed (faster than mtime-only)
    # shellcheck disable=SC2086
    rsync -az --checksum --delete --progress \
        -e "ssh ${SITE_SSH_OPTS}" \
        "${src}" \
        "${SITE_USER}@${SITE_HOST}:${SITE_PATH}/"

    log "Site deployed → https://debz.ca"

    # ISO upload — opt-in only (slow connection)
    if [[ "${SITE_UPLOAD_ISO:-no}" == "yes" ]]; then
        _site_upload_iso
    fi
}

_site_upload_iso() {
    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR} — run 'build' first"

    local iso_name iso_size
    iso_name="$(basename "${iso}")"
    iso_size="$(du -sh "${iso}" | cut -f1)"

    log "Uploading ISO: ${iso_name} (${iso_size}) — this will take a while on a slow link"
    log "  Source : ${iso}"
    log "  Dest   : ${SITE_USER}@${SITE_HOST}:${SITE_PATH}/${iso_name}"

    # shellcheck disable=SC2086
    rsync -az --progress \
        -e "ssh ${SITE_SSH_OPTS}" \
        "${iso}" \
        "${SITE_USER}@${SITE_HOST}:${SITE_PATH}/${iso_name}"

    log "ISO uploaded → https://debz.ca/${iso_name}"
}

cmd_site_deploy_release() {
    SITE_UPLOAD_ISO=yes cmd_site_deploy
}

# ---------------------------------------------------------------------------
# Subcommand: dl-upload  (SCP ISO to home pfSense/server for self-hosting)
# ---------------------------------------------------------------------------
# Required vars (set in debz.env):
#   DL_HOST   — SSH host of the download server (pfSense LAN IP or hostname)
#   DL_USER   — SSH user (pfSense: admin)
#   DL_PATH   — remote directory to drop files into (e.g. /var/db/debz-dl)
#   DL_URL    — public base URL for downloads (e.g. http://dl.debz.ca:8080)
#   DL_PORT   — SSH port on DL_HOST (default: 22)
#
# pfSense one-time setup:
#   1. System → Package Manager → install nginx
#   2. mkdir -p /var/db/debz-dl && chown -R www:www /var/db/debz-dl
#   3. Configure nginx server block (see docs/pfsense-dl-nginx.conf)
#   4. Firewall → Rules → WAN → allow TCP dst 8080
#   5. Add DNS A record: dl.debz.ca → your home public IP

cmd_dl_upload() {
    [[ -f "$ROOT/debz.env" ]] && source "$ROOT/debz.env"

    local dl_host="${DL_HOST:-}"
    local dl_user="${DL_USER:-admin}"
    local dl_path="${DL_PATH:-/var/db/debz-dl}"
    local dl_url="${DL_URL:-}"
    local dl_ssh_port="${DL_PORT:-22}"
    local dl_key="${DL_KEY:-}"
    local ssh_opts="-o StrictHostKeyChecking=no -p ${dl_ssh_port}"
    [[ -n "$dl_key" ]] && ssh_opts="$ssh_opts -i ${dl_key}"

    [[ -n "$dl_host" ]] || die "DL_HOST not set in debz.env — set to your pfSense LAN IP"
    [[ -n "$dl_url"  ]] || die "DL_URL not set in debz.env — e.g. http://dl.debz.ca:8080"

    local iso version iso_name iso_size
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "$iso" ]] || die "No ISO found in ${OUTPUT_DIR} — run 'build' first"
    version="$(_release_version)"
    iso_name="$(basename "$iso")"
    iso_size="$(du -sh "$iso" | cut -f1)"

    log "Uploading ISO to download server (home pfSense)"
    log "  Host : ${dl_user}@${dl_host}:${dl_path}"
    log "  File : ${iso_name} (${iso_size})"
    log "  URL  : ${dl_url}/${iso_name}"

    # Ensure remote directory exists
    ssh $ssh_opts "${dl_user}@${dl_host}" "mkdir -p '${dl_path}'"

    # SCP the ISO (overwrites any previous copy — same filename = same URL)
    scp $ssh_opts "$iso" "${dl_user}@${dl_host}:${dl_path}/${iso_name}"

    # Upload VERSION.txt alongside it
    local vtmp
    vtmp="$(mktemp)"
    printf 'version=%s\ndate=%s\niso=%s\nurl=%s/%s\n' \
        "${version}" "$(date -u '+%Y-%m-%d')" "${iso_name}" "${dl_url}" "${iso_name}" \
        > "${vtmp}"
    scp $ssh_opts "${vtmp}" "${dl_user}@${dl_host}:${dl_path}/VERSION.txt"
    rm -f "${vtmp}"

    log "Download URL : ${dl_url}/${iso_name}"
    log "Version info : ${dl_url}/VERSION.txt"
    log "Upload complete."
}

# ---------------------------------------------------------------------------
# Subcommand: ia-upload  (upload latest ISO to archive.org)
# ---------------------------------------------------------------------------

cmd_ia_upload() {
    local access="${IA_ACCESS_KEY:-}"
    local secret="${IA_SECRET_KEY:-}"
    local identifier="${IA_IDENTIFIER:-debz-linux}"

    [[ -n "${access}" ]] || die "IA_ACCESS_KEY not set — source debz.env first"
    [[ -n "${secret}" ]] || die "IA_SECRET_KEY not set — source debz.env first"

    local iso
    iso="$(latest_iso 2>/dev/null || true)"
    [[ -n "${iso}" ]] || die "No ISO found in ${OUTPUT_DIR} — run 'build' first"

    local version iso_name iso_size
    version="$(_release_version)"
    iso_name="$(basename "${iso}")"
    iso_size="$(du -sh "${iso}" | cut -f1)"

    # ISO filename is always fixed (debz-desktop-amd64.hybrid.iso) so the
    # download URL never changes — archive.org overwrites the same file in-place.
    log "Uploading to archive.org (overwrites existing file — URL stays constant)"
    log "  Item    : https://archive.org/details/${identifier}"
    log "  File    : ${iso_name} (${iso_size})"
    log "  Version : ${version}"

    local ia_base="https://s3.us.archive.org/${identifier}"
    local common_headers=(
        --header "x-amz-auto-make-bucket:1"
        --header "x-archive-meta-mediatype:software"
        --header "x-archive-meta-subject:linux;debian;zfs;live-iso"
        --header "x-archive-meta-title:debz Linux"
        --header "x-archive-meta-description:Debian 13 live ISO with ZFS-on-root, ZFSBootMenu, and WireGuard mesh. https://debz.ca"
        --header "x-archive-meta-licenseurl:https://opensource.org/licenses/MIT"
        --user "${access}:${secret}"
    )

    # Upload ISO (always same filename — overwrites previous version)
    curl --fail --progress-bar "${common_headers[@]}" \
        --upload-file "${iso}" \
        "${ia_base}/${iso_name}"

    # Upload VERSION.txt alongside the ISO so users can check what version
    # they're getting without downloading the full 1.8 GB ISO
    local vtmp
    vtmp="$(mktemp)"
    printf 'version=%s\ndate=%s\niso=%s\nurl=https://archive.org/download/%s/%s\n' \
        "${version}" "$(date -u '+%Y-%m-%d')" "${iso_name}" "${identifier}" "${iso_name}" \
        > "${vtmp}"
    curl --fail --silent "${common_headers[@]}" \
        --upload-file "${vtmp}" \
        "${ia_base}/VERSION.txt" \
        && log "VERSION.txt uploaded"
    rm -f "${vtmp}"

    log "ISO live at : https://archive.org/download/${identifier}/${iso_name}"
    log "Version info: https://archive.org/download/${identifier}/VERSION.txt"
}

# ---------------------------------------------------------------------------
# SCC / k8s-ha helpers
# ---------------------------------------------------------------------------

# _vm_wait_stopped VMID [TIMEOUT_SECONDS]
# Polls Proxmox until the VM is stopped (install complete) or timeout.
_vm_wait_stopped() {
    local vmid="${1:?}"
    local timeout="${2:-900}"
    local elapsed=0
    log "Waiting for VM ${vmid} to stop (install complete)..."
    while (( elapsed < timeout )); do
        local status
        status="$(proxmox_api GET \
            "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/current" \
            2>/dev/null \
            | grep -oP '"status":"[^"]+"' \
            | cut -d'"' -f4 || echo "unknown")"
        if [[ "${status}" == "stopped" ]]; then
            log "VM ${vmid} stopped after ${elapsed}s — install complete"
            return 0
        fi
        sleep 15
        (( elapsed += 15 ))
    done
    log "WARNING: VM ${vmid} did not stop after ${timeout}s — continuing anyway"
    return 0
}

# _vm_start VMID
_vm_start() {
    local vmid="${1:?}"
    proxmox_api POST "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start" \
        2>/dev/null || log "WARNING: could not start VM ${vmid}"
    log "VM ${vmid} started"
}

# _build_node_seed HOSTNAME TEMPLATE [EXTRA_ENV...]
# Writes a temp answers.env, builds a 32 MB FAT32 DEBZ-SEED disk,
# uploads it to Proxmox ISO storage, and prints the uploaded ISO name.
_build_node_seed() {
    local hostname="${1:?}"
    local template="${2:?}"
    shift 2
    local extra_env=("$@")   # optional VAR=value pairs appended to answers.env

    local answers_file="/tmp/debz-answers-$$-${hostname}.env"
    local seed_img="/tmp/debz-seed-$$-${hostname}.img"

    cat > "${answers_file}" <<ENV
DEBZ_PROFILE=server
DEBZ_STORAGE_MODE=zfs
DEBZ_ENABLE_ZFS=1
DEBZ_DISK=/dev/sda
DEBZ_HOSTNAME=${hostname}
DEBZ_USERNAME=admin
DEBZ_PASSWORD=changeme
DEBZ_ROOT_PASSWORD=changeme
DEBZ_NET_METHOD=dhcp
DEBZ_TEMPLATE=${template}
DEBZ_ZFS_ENCRYPT=0
DEBZ_ZFS_BPOOL_SIZE_MIB=2048
DEBZ_ZFS_ASHIFT=12
DEBZ_FORCE_WIPE=1
ENV

    local ev
    for ev in "${extra_env[@]+"${extra_env[@]}"}"; do
        printf '%s\n' "${ev}" >> "${answers_file}"
    done

    debz_seed_disk_build "${answers_file}" "${seed_img}"
    rm -f "${answers_file}"

    local seed_name
    seed_name="$(proxmox_seed_upload "${seed_img}" "${PROXMOX_ISO_STORE}")"
    rm -f "${seed_img}"
    printf '%s\n' "${seed_name}"
}

# ---------------------------------------------------------------------------
# Subcommand: scc  (Starter Cluster Config — 6 nodes in dependency order)
# ---------------------------------------------------------------------------
# Order: fw1 → fw2 → master → proxmox-01 → monitoring → storage
# Each node installs unattended via its seed disk, waits for install to
# complete (VM powers off), then the next node is deployed.
# After master completes, subsequent nodes auto-discover hub.env at firstboot.
# ---------------------------------------------------------------------------

cmd_scc() {
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST required. Set it in debz.env."

    local iso_name="${ISO_NAME:-}"
    if [[ -z "${iso_name}" ]]; then
        local local_iso
        local_iso="$(latest_iso 2>/dev/null || true)"
        [[ -n "${local_iso}" ]] && iso_name="$(basename "${local_iso}")"
    fi
    [[ -n "${iso_name}" ]] \
        || die "No ISO found. Run './deploy.sh build' then './deploy.sh deploy' first."

    # SCC node definitions: vmid name template mem cores disk extra-disks
    local -a SCC_NODES=(
        "920 fw1          firewall    2048  2  40  0"
        "921 fw2          firewall    2048  2  40  0"
        "922 master       master      8192  4  80  0"
        "905 proxmox-01   proxmox    32768  8 120  0"
        "907 monitoring   monitoring  4096  4  80  0"
        "923 storage      storage     4096  4  40  4"
    )

    log "════ SCC: Starter Cluster Config ════"
    log "ISO: ${iso_name}  Nodes: ${#SCC_NODES[@]}"
    log "Order: fw1 → fw2 → master → proxmox-01 → monitoring → storage"
    log "Each node installs unattended — VM powers off when done."

    local i=0
    local node_def
    for node_def in "${SCC_NODES[@]}"; do
        (( i++ ))
        read -r vmid vmname template vmem vcores vdisk vextradisks <<< "${node_def}"

        log ""
        log "── [${i}/${#SCC_NODES[@]}] ${vmname}  VMID=${vmid}  template=${template} ──"

        # Build seed disk for this node
        log "  Building seed disk for ${vmname}..."
        local seed_name
        seed_name="$(_build_node_seed "${vmname}" "${template}" \
            "DEBZ_LAN_CIDR=${DEBZ_LAN_CIDR:-192.168.0.0/16}" \
            "DEBZ_CLUSTER_DOMAIN=${DEBZ_CLUSTER_DOMAIN:-cluster.debz}")"
        log "  Seed disk: ${seed_name}"

        # Create + start VM
        proxmox_vm_create \
            "${vmid}" "${vmname}" "${vmem}" "${vcores}" \
            "${vdisk}" "${VM_BRIDGE:-vmbr0}" "${PROXMOX_VM_STORE}" \
            "${PROXMOX_DATA_STORE}" "${PROXMOX_ISO_STORE}" "${iso_name}" \
            "no" "${vextradisks}" "${VM_EXTRA_DISK_GB:-20}" "0" "${seed_name}"

        # Wait for install to complete (VM powers off)
        _vm_wait_stopped "${vmid}" 900

        # Remove CDROM and boot from disk
        proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
            -H "Content-Type: application/json" \
            -d '{"ide2":"none,media=cdrom","ide3":"none,media=cdrom"}' \
            2>/dev/null || true

        # Start the installed node
        _vm_start "${vmid}"

        log "  ${vmname} (${vmid}) is up — firstboot running in background"

        # After master comes up, give it 30s to generate hub.env before next nodes
        if [[ "${vmname}" == "master" ]]; then
            log "  Waiting 30s for master to generate hub.env before next nodes..."
            sleep 30
        fi
    done

    log ""
    log "════ SCC complete ════"
    log "  fw1       (920) — firewall + DNS/DNSSEC + WireGuard enrollment"
    log "  fw2       (921) — firewall HA pair (keepalived VRRP)"
    log "  master    (922) — Salt master + WireGuard hub + hub.env @ http://10.77.0.1"
    log "  proxmox-01(905) — Proxmox VE hypervisor"
    log "  monitoring(907) — Prometheus + Grafana"
    log "  storage   (923) — ZFS NFS + iSCSI storage (4×${VM_EXTRA_DISK_GB:-20}GB)"
    log ""
    log "  All nodes auto-join via hub.env on firstboot."
    log "  Accept Salt keys:  salt-key -A"
    log "  Check nodes:       salt '*' test.ping"
}

# ---------------------------------------------------------------------------
# Subcommand: k8s-ha  (16-node HA Kubernetes cluster — blue/green/yellow waves)
# ---------------------------------------------------------------------------
# All seed disks built first, then deployed in three color waves:
#   BLUE   — fw1, master, etcd-01, worker-01, worker-04
#   GREEN  — fw2, etcd-02, worker-02, worker-05
#   YELLOW — etcd-03, worker-03, worker-06, storage, monitoring
#
# Wait for each wave to complete before starting the next wave.
# ---------------------------------------------------------------------------

cmd_k8s_ha() {
    [[ -n "${PROXMOX_HOST:-}" ]] \
        || die "PROXMOX_HOST required. Set it in debz.env."

    local iso_name="${ISO_NAME:-}"
    if [[ -z "${iso_name}" ]]; then
        local local_iso
        local_iso="$(latest_iso 2>/dev/null || true)"
        [[ -n "${local_iso}" ]] && iso_name="$(basename "${local_iso}")"
    fi
    [[ -n "${iso_name}" ]] \
        || die "No ISO found. Run './deploy.sh build' then './deploy.sh deploy' first."

    # Node definitions per wave: vmid name template mem cores disk extra-disks
    local -a BLUE_NODES=(
        "920 fw1       firewall  2048  2  40  0"
        "930 master    master    8192  4  80  0"
        "931 etcd-01   etcd      4096  4  40  0"
        "940 worker-01 worker    8192  4  80  0"
        "943 worker-04 worker    8192  4  80  0"
    )
    local -a GREEN_NODES=(
        "921 fw2       firewall  2048  2  40  0"
        "932 etcd-02   etcd      4096  4  40  0"
        "941 worker-02 worker    8192  4  80  0"
        "944 worker-05 worker    8192  4  80  0"
    )
    local -a YELLOW_NODES=(
        "933 etcd-03   etcd      4096  4  40  0"
        "942 worker-03 worker    8192  4  80  0"
        "945 worker-06 worker    8192  4  80  0"
        "923 storage   storage   4096  4  40  4"
        "907 monitoring monitoring 4096 4 80  0"
    )

    local total=$(( ${#BLUE_NODES[@]} + ${#GREEN_NODES[@]} + ${#YELLOW_NODES[@]} ))
    log "════ k8s-ha: ${total}-node HA Kubernetes cluster ════"
    log "ISO: ${iso_name}"
    log "  BLUE   wave: ${#BLUE_NODES[@]} nodes (fw1, master, etcd-01, worker-01/04)"
    log "  GREEN  wave: ${#GREEN_NODES[@]} nodes (fw2, etcd-02, worker-02/05)"
    log "  YELLOW wave: ${#YELLOW_NODES[@]} nodes (etcd-03, worker-03/06, storage, monitoring)"

    # All node definitions combined for seed building
    local -a ALL_NODES=(
        "${BLUE_NODES[@]}"
        "${GREEN_NODES[@]}"
        "${YELLOW_NODES[@]}"
    )

    # ── Phase 1: Build ALL seed disks before powering on anything ─────────────
    log ""
    log "Phase 1: Building all ${total} seed disks..."
    declare -A SEED_MAP   # vmid → seed_name

    local node_def vmid vmname template vmem vcores vdisk vextradisks seed_name
    for node_def in "${ALL_NODES[@]}"; do
        read -r vmid vmname template vmem vcores vdisk vextradisks <<< "${node_def}"
        log "  Building seed for ${vmname} (${vmid})..."
        seed_name="$(_build_node_seed "${vmname}" "${template}" \
            "DEBZ_LAN_CIDR=${DEBZ_LAN_CIDR:-192.168.0.0/16}" \
            "DEBZ_CLUSTER_DOMAIN=${DEBZ_CLUSTER_DOMAIN:-cluster.debz}")"
        SEED_MAP["${vmid}"]="${seed_name}"
        log "    ${vmname} (${vmid}) → ${seed_name}"
    done
    log "All ${total} seed disks ready."

    # ── Phase 2: Deploy waves in order ───────────────────────────────────────
    # Helper: deploy one wave's VMs then wait for all to stop and restart them
    _k8sha_wave() {
        local wave_name="${1}"; shift
        local -a nodes=("$@")
        log ""
        log "── Wave: ${wave_name} (${#nodes[@]} nodes) ──"
        local nd vid vn tmpl vm vc vd vex sn
        for nd in "${nodes[@]}"; do
            read -r vid vn tmpl vm vc vd vex <<< "${nd}"
            sn="${SEED_MAP[${vid}]:-}"
            log "  Deploying ${vn} (${vid})..."
            proxmox_vm_create \
                "${vid}" "${vn}" "${vm}" "${vc}" \
                "${vd}" "${VM_BRIDGE:-vmbr0}" "${PROXMOX_VM_STORE}" \
                "${PROXMOX_DATA_STORE}" "${PROXMOX_ISO_STORE}" "${iso_name}" \
                "no" "${vex}" "${VM_EXTRA_DISK_GB:-20}" "0" "${sn}"
            log "  ${vn} (${vid}) installing..."
        done
        log ""
        log "  Waiting for ${wave_name} nodes to complete install..."
        for nd in "${nodes[@]}"; do
            read -r vid vn tmpl vm vc vd vex <<< "${nd}"
            _vm_wait_stopped "${vid}" 900
            proxmox_api PUT "/nodes/${PROXMOX_NODE}/qemu/${vid}/config" \
                -H "Content-Type: application/json" \
                -d '{"ide2":"none,media=cdrom","ide3":"none,media=cdrom"}' \
                2>/dev/null || true
            _vm_start "${vid}"
            log "  ${vn} (${vid}) — installed and started"
        done
        log "  ${wave_name} wave complete."
    }

    _k8sha_wave "BLUE"   "${BLUE_NODES[@]}"

    log ""
    log "  Waiting 60s for BLUE wave to settle (master hub.env, WireGuard...)..."
    sleep 60

    _k8sha_wave "GREEN"  "${GREEN_NODES[@]}"

    log ""
    log "  Waiting 30s for GREEN wave..."
    sleep 30

    _k8sha_wave "YELLOW" "${YELLOW_NODES[@]}"

    log ""
    log "════ k8s-ha deployment complete ════"
    log "  ${total} nodes deployed across BLUE / GREEN / YELLOW waves"
    log ""
    log "  BLUE  — fw1(920) master(930) etcd-01(931) worker-01(940) worker-04(943)"
    log "  GREEN — fw2(921) etcd-02(932) worker-02(941) worker-05(944)"
    log "  YELLOW— etcd-03(933) worker-03(942) worker-06(945) storage(923) monitoring(907)"
    log ""
    log "  Next steps (run from master):"
    log "    salt-key -A                           # accept all minion keys"
    log "    salt '*' test.ping                    # verify all nodes online"
    log "    kubeadm init --control-plane-endpoint 10.79.0.1 ..."
    log "    # or: debz-k8s-bootstrap (if installed)"
}

# ---------------------------------------------------------------------------
# Subcommand: latest-iso
# ---------------------------------------------------------------------------

cmd_latest_iso() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found in $OUTPUT_DIR"
    echo "$iso"
}

# ---------------------------------------------------------------------------
# Subcommand: r2-upload / publish
# Upload latest ISO + sha256 to Cloudflare R2 (debz-releases bucket).
# Uses aws CLI credentials configured via: aws configure
# Usage: ./deploy.sh publish [VERSION]
#   VERSION defaults to R2_VERSION env var or v1.0.0
# ---------------------------------------------------------------------------

R2_ENDPOINT="https://98b263f2fc04b02728204fbe0242af52.r2.cloudflarestorage.com"
R2_BUCKET="debz-releases"
R2_PUBLIC_URL="https://pub-77bf4c61c18344b4b96dbb96ad972389.r2.dev"

cmd_r2_upload() { cmd_publish "$@"; }

cmd_publish() {
    command -v aws >/dev/null 2>&1 || die "aws CLI not found — install awscli"

    local iso version edition dest dest_sha url
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run: ./deploy.sh build first"

    version="${1:-${R2_VERSION:-v1.0.0}}"
    edition="${EDITION:-free}"
    dest="debz-${edition}-${version}-amd64.iso"
    dest_sha="${dest}.sha256"
    url="${R2_PUBLIC_URL}/${dest}"

    log "Publishing debz-${edition} ${version}"
    log "  ISO:     $iso  ($(du -sh "$iso" | cut -f1))"
    log "  Object:  s3://${R2_BUCKET}/${dest}"
    log "  URL:     ${url}"

    # Remove any previous debz-free-*.iso and *.sha256 objects from the bucket
    log "Removing previous releases from bucket..."
    local old_keys
    old_keys="$(aws s3api list-objects-v2 \
        --bucket "$R2_BUCKET" \
        --endpoint-url "$R2_ENDPOINT" \
        --query "Contents[?contains(Key, 'debz-${edition}-')].Key" \
        --output text 2>/dev/null || true)"
    if [[ -n "$old_keys" ]]; then
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            log "  deleting: $key"
            aws s3 rm "s3://${R2_BUCKET}/${key}" \
                --endpoint-url "$R2_ENDPOINT" 2>/dev/null || true
        done <<< "$old_keys"
    else
        log "  (bucket already empty)"
    fi

    # Generate sha256 alongside the ISO
    local sha_file="${iso}.sha256"
    (cd "$(dirname "$iso")" && sha256sum "$(basename "$iso")" > "$(basename "$sha_file")")
    log "  SHA256:  $(cat "$sha_file")"

    # Upload ISO
    log "Uploading ISO..."
    aws s3 cp "$iso" "s3://${R2_BUCKET}/${dest}" \
        --endpoint-url "$R2_ENDPOINT" \
        --no-progress \
        || die "ISO upload failed"

    # Upload sha256
    aws s3 cp "$sha_file" "s3://${R2_BUCKET}/${dest_sha}" \
        --endpoint-url "$R2_ENDPOINT" \
        --no-progress \
        || die "sha256 upload failed"

    log ""
    log "✔ Published!"
    log "  Download: ${url}"
    log "  Checksum: ${R2_PUBLIC_URL}/${dest_sha}"
}

# ---------------------------------------------------------------------------
# Subcommand: help
# ---------------------------------------------------------------------------

_help_index() {
    cat <<'EOF'
debz — Debian 13 live ISO build, deploy, and VM fleet management

  ./deploy.sh <subcommand> [VAR=value ...]
  ./deploy.sh help <topic>    full detail on any subcommand or topic

ISO BUILDING
  build          Build live ISO in Docker  (PROFILE=desktop|server  ARCH=amd64)
  builder-image  Build/rebuild the Docker build environment
  clean          Delete build artifacts  (not golden images or clones)
  full           Clean + rebuild builder + build + deploy + burn  [everything]
  validate       shellcheck all scripts + verify required files and dirs

PROXMOX
  deploy             Upload ISO → Proxmox → recreate VM → [burn USB]
  server-deploy      Opinionated server build + deploy  (best-practice defaults, no USB burn)
  proxmox-deploy     Deploy a Proxmox VE node on debz base  (VMID=905, 16GB RAM, 120GB disk)
  monitoring-deploy  Deploy Prometheus + Grafana reporting node  (VMID=907)
  landing-deploy     Deploy SFTP landing zone / secure drop zone  (VMID=908, ZFS encrypted)
  lb-deploy          Deploy HAProxy + Keepalived k8s load balancer  (VMID=909, VIP=10.100.10.200)
  site-deploy          Push html/ to debz.ca  (no ISO)
  full-release         Bump version + full build + dl-upload + site deploy
  dl-upload            SCP ISO to home pfSense/server (DL_HOST/DL_PATH/DL_URL in debz.env)
  site-deploy-release  Push html/ + upload latest ISO to debz.ca
  ia-upload            Upload latest ISO to archive.org (requires IA_ACCESS_KEY + IA_SECRET_KEY)
  spawn              Create new Proxmox VM from ISO already on Proxmox  (no upload)
  burn               Write latest ISO to USB  (USB_DEVICE=/dev/sdX)

CLUSTER AUTOMATION
  scc     Starter Cluster Config — 6-node minimal cluster in dependency order
            fw1 → fw2 → master → proxmox-01 → monitoring → storage
            Each node installs unattended; VM stops when done; next node starts.
  k8s-ha  HA Kubernetes cluster — builds all seed disks first, then deploys
            in three color waves: BLUE → GREEN → YELLOW (14 nodes total)
            BLUE:   fw1, master, etcd-01, worker-01, worker-04
            GREEN:  fw2, etcd-02, worker-02, worker-05
            YELLOW: etcd-03, worker-03, worker-06, storage, monitoring

GOLDEN IMAGES & CLONING
  golden         Headless QEMU install → golden qcow2  (TEMPLATE=kvm|master|storage|vdi)
  stamp          CoW-clone golden N times, stamp hostname + node index  (STAMP_COUNT=N)

EXPORT
  vmdk           ISO → VMDK  (VMware / VirtualBox)
  rootfs         ISO squashfs → raw ext4  (Firecracker, bare metal flashing)
  firecracker    Build Firecracker microVM bundle  (rootfs + vmlinuz + config + run.sh)
  aws-ami        ISO → S3 → EC2 snapshot → AMI  (AWS_BUCKET=...  AWS_REGION=...)

UTILITIES
  release        Copy ISOs + sha256 checksums to release/
  latest-iso     Print absolute path of latest built ISO
  tree           Show repo tree  (excludes work/ output/ legacy/)
  help [topic]   This index, or full detail on a subcommand

HELP TOPICS
  ./deploy.sh help build          ./deploy.sh help deploy
  ./deploy.sh help golden         ./deploy.sh help stamp
  ./deploy.sh help spawn          ./deploy.sh help burn
  ./deploy.sh help full           ./deploy.sh help clean
  ./deploy.sh help validate       ./deploy.sh help builder-image
  ./deploy.sh help vmdk           ./deploy.sh help rootfs
  ./deploy.sh help firecracker    ./deploy.sh help aws-ami
  ./deploy.sh help release        ./deploy.sh help workflows
  ./deploy.sh help vars           ./deploy.sh help files

  source debz.env.example         # annotated environment variable reference
EOF
}

_help_build() { cat <<'EOF'
BUILD / ISO  —  build a live ISO inside the debz-live-builder Docker container

  ./deploy.sh build
  ./deploy.sh iso       (alias)

  Automatically builds the builder image if it does not exist.
  Output is written to OUTPUT_DIR (default: live-build/output/).
  Subsequent builds reuse the container apt cache.

  PROFILE         desktop | server          default: desktop
  ARCH            amd64 | arm64             default: amd64
  OUTPUT_DIR      ISO output directory      default: live-build/output
  LOG_DIR         build log directory       default: live-build/logs
  BUILDER_IMAGE   builder image tag         default: debz-live-builder:latest

  Examples:
    ./deploy.sh build
    PROFILE=server ./deploy.sh build
    PROFILE=server ARCH=arm64 ./deploy.sh build
    OUTPUT_DIR=/mnt/nvme/iso LOG_DIR=/mnt/nvme/logs ./deploy.sh build
    BUILDER_IMAGE=debz-live-builder:dev ./deploy.sh build
EOF
}

_help_builder_image() { cat <<'EOF'
BUILDER-IMAGE  —  build or rebuild the Docker build environment image

  ./deploy.sh builder-image

  Builds builder/Dockerfile into debz-live-builder:latest.
  Only needed once, or after modifying builder/Dockerfile.
  'build' calls this automatically when the image is missing.

  BUILDER_IMAGE   image tag to create  default: debz-live-builder:latest

  Examples:
    ./deploy.sh builder-image
    BUILDER_IMAGE=debz-live-builder:dev ./deploy.sh builder-image
    docker rmi debz-live-builder:latest && ./deploy.sh builder-image
EOF
}

_help_clean() { cat <<'EOF'
CLEAN  —  delete local build artifacts

  ./deploy.sh clean

  Removes: live-build/chroot  live-build/binary  live-build/output
           live-build/work  stopped builder containers  and VM $VMID on Proxmox.

  Does NOT remove:
    Golden images in /var/lib/debz/golden/
    VM clones in /var/lib/debz/clones/ or STAMP_OUTPUT_DIR
    The builder Docker image (debz-live-builder:latest)

  VM destroy looks up the VM by name (default: debz-live) and is skipped
  when PROXMOX_HOST is unset.

  OUTPUT_DIR   cleaned alongside default dirs if overridden  default: live-build/output

  Examples:
    ./deploy.sh clean
    OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh clean
    ./deploy.sh clean && ./deploy.sh build
EOF
}

_help_full() { cat <<'EOF'
FULL  —  complete pipeline from scratch: clean + rebuild + deploy + burn

  ./deploy.sh full

  Steps in order:
    1.  Destroy VMID on Proxmox  (non-fatal if VM does not exist)
    2.  clean
    3.  Remove builder Docker image to force a fresh build
    4.  Prune dangling images
    5.  builder-image
    6.  build
    7.  deploy  (upload ISO + recreate VM + start)
    8.  burn    (if USB_BURN_ON_DEPLOY=yes)

  All VM_*, PROXMOX_*, and USB_* variables apply (see: ./deploy.sh help deploy)

  Examples:
    ./deploy.sh full
    USB_BURN_ON_DEPLOY=no ./deploy.sh full
    VMID=901 VM_NAME=debz-test2 USB_BURN_ON_DEPLOY=no ./deploy.sh full
    PROFILE=server PROXMOX_HOST=10.10.0.1 VM_MEMORY=8192 VM_CORES=8 \
      USB_BURN_ON_DEPLOY=no ./deploy.sh full
    VM_SECURE_BOOT=yes VM_TPM=yes VMID=902 VM_NAME=debz-secureboot ./deploy.sh full
EOF
}

_help_validate() { cat <<'EOF'
VALIDATE  —  lint and sanity-check the repository

  ./deploy.sh validate

  Runs:
    shellcheck -S warning on every .sh file outside legacy/ and build artifacts
    shellcheck on every .hook.chroot file outside legacy/
    Checks all required directories exist
    Checks all required files exist
  Exits non-zero on any failure.  Run before every commit.

  Examples:
    ./deploy.sh validate
    ./deploy.sh validate && git push
    ./deploy.sh validate && ./deploy.sh build
EOF
}

_help_deploy() { cat <<'EOF'
DEPLOY  —  upload ISO to Proxmox, recreate VM, optionally burn to USB

  ./deploy.sh deploy

  Steps: API-upload latest ISO → Proxmox, destroy VMID if exists, create
  new VM with specified CPU/RAM/disk/extra-disks, attach ISO as CDROM,
  start VM.  Uses Proxmox REST API with token auth — no SSH required.
  Extra data disks (scsi1..N) are attached from PROXMOX_DATA_STORE for
  ZFS pool topology testing.

  PROXMOX_HOST        Proxmox IP or FQDN              default: 10.100.10.225
  PROXMOX_NODE        Proxmox cluster node name        default: fiend
  PROXMOX_TOKEN_ID    API token ID (root@pam!root)     required (set in debz.env)
  PROXMOX_TOKEN_SECRET API token secret UUID           required (set in debz.env)
  PROXMOX_ISO_STORE   storage ID for ISOs             default: local
  PROXMOX_VM_STORE    storage ID for VM boot disk     default: local-zfs
  PROXMOX_DATA_STORE  storage ID for extra disks      default: fireball
  VMID                VM ID (must be unique)           default: 900
  VM_NAME             VM display name                 default: debz-live
  VM_MEMORY           RAM in MB                       default: 4096
  VM_CORES            virtual CPU count               default: 4
  VM_DISK_GB          boot disk size in GB            default: 40
  VM_EXTRA_DISKS      extra data disks (for ZFS)      default: 6
  VM_EXTRA_DISK_GB    size of each extra disk (GB)    default: 20
  VM_BRIDGE           Proxmox network bridge          default: vmbr0
  VM_SECURE_BOOT      yes | no                        default: no
  VM_TPM              yes | no — attach TPM 2.0       default: yes
  USB_BURN_ON_DEPLOY  yes | no                        default: yes
  USB_DEVICE          /dev/sdX  (auto-detected if unset)

  Examples:
    ./deploy.sh deploy
    USB_BURN_ON_DEPLOY=no ./deploy.sh deploy
    VMID=910 VM_NAME=debz-server VM_MEMORY=8192 VM_CORES=8 \
      VM_EXTRA_DISKS=4 VM_EXTRA_DISK_GB=50 USB_BURN_ON_DEPLOY=no ./deploy.sh deploy
    PROXMOX_HOST=10.10.0.50 VMID=920 VM_SECURE_BOOT=yes VM_TPM=yes \
      USB_BURN_ON_DEPLOY=no ./deploy.sh deploy
    VMID=930 VM_NAME=debz-storage VM_EXTRA_DISKS=8 VM_EXTRA_DISK_GB=100 \
      PROXMOX_DATA_STORE=fireball USB_BURN_ON_DEPLOY=no ./deploy.sh deploy
EOF
}

_help_spawn() { cat <<'EOF'
SPAWN  —  create a new Proxmox VM from an ISO already on Proxmox

  ./deploy.sh spawn

  Same as deploy but skips the ISO upload and USB burn.  Use this to spin
  up additional VMs from the same ISO without re-uploading.

  ISO_NAME   ISO filename in Proxmox storage     default: latest local ISO
  All VM_* and PROXMOX_* variables apply (see: ./deploy.sh help deploy)

  Examples:
    ./deploy.sh spawn
    VMID=901 VM_NAME=debz-node2 ./deploy.sh spawn
    VMID=902 VM_NAME=debz-k8s VM_MEMORY=16384 VM_CORES=8 VM_EXTRA_DISKS=0 \
      ISO_NAME=debz-trixie-amd64-20260316.iso ./deploy.sh spawn
    for id in 901 902 903; do
      VMID=$id VM_NAME=debz-node-$id VM_MEMORY=4096 ./deploy.sh spawn
    done
EOF
}

_help_burn() { cat <<'EOF'
BURN  —  write the latest ISO to a USB block device

  ./deploy.sh burn

  Uses dd with bs=4M oflag=sync.  Auto-detects a single removable drive
  by scanning /sys/block/*/removable.  Fails if zero or more than one
  removable drive is present — set USB_DEVICE explicitly in that case.

  USB_DEVICE   /dev/sdX  (auto-detected from removable drives)

  Examples:
    ./deploy.sh burn
    USB_DEVICE=/dev/sdb ./deploy.sh burn
    USB_DEVICE=/dev/sdc OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh burn
    ./deploy.sh build && USB_DEVICE=/dev/sdb ./deploy.sh burn
EOF
}

_help_golden() { cat <<'EOF'
GOLDEN  —  build a fully-installed golden qcow2 image for a node template

  ./deploy.sh golden   (requires TEMPLATE)

  Boots the live ISO headlessly in QEMU/KVM with a 32 MB FAT32 DEBZ-SEED
  disk containing answers.env.  debz-autoinstall.service detects the seed
  disk on boot and runs debz-install-target unattended.  QEMU exits when
  the installer shuts the VM down.  Timeout: 1800 s.

  Templates:
    master   Salt master + WireGuard hub + k8s control-plane bootstrap
    kvm      KVM hypervisor + libvirt + bridge networking + ovmf
    storage  ZFS NFS/iSCSI + Samba + prometheus-node-exporter
    vdi      Wayland streaming + mediamtx SRT/HLS + FFmpeg + NVIDIA-optional

  Output:       /var/lib/debz/golden/golden-<TEMPLATE>.qcow2
  Serial log:   /tmp/debz-golden-serial.log

  TEMPLATE        master | kvm | storage | vdi    required
  GOLDEN_OUTPUT   custom output path              default: auto
  GOLDEN_FORMAT   qcow2 | rootfs                  default: qcow2
  GOLDEN_ISO      path to live ISO                default: latest in OUTPUT_DIR
  GOLDEN_SIZE     disk image size in GB           default: 40

  Examples:
    TEMPLATE=kvm ./deploy.sh golden
    TEMPLATE=storage GOLDEN_SIZE=80 ./deploy.sh golden
    TEMPLATE=vdi GOLDEN_OUTPUT=/mnt/nvme/gold/vdi.qcow2 GOLDEN_SIZE=60 ./deploy.sh golden
    for t in master kvm storage vdi; do TEMPLATE=$t ./deploy.sh golden; done
    TEMPLATE=master GOLDEN_FORMAT=rootfs ./deploy.sh golden
EOF
}

_help_stamp() { cat <<'EOF'
STAMP  —  CoW-clone a golden image and stamp per-node identity into each clone

  ./deploy.sh stamp   (requires TEMPLATE)

  Creates N qcow2 clones using qemu-img create -b (backing file).
  Each clone is ~1 MB on disk at creation; grows only as the node writes.

  Per clone, debz-stamp-identity:
    - Connects image to /dev/nbdN via qemu-nbd
    - Imports the ZFS pool read-write with alternate root
    - Writes /etc/hostname and /etc/hosts
    - Appends DEBZ_NODE_INDEX=N to /etc/debz/install-manifest.env
    - Clears /etc/machine-id  (regenerated on first boot)
    - Removes /var/lib/debz/firstboot-done  (firstboot re-runs on boot)
    - Copies /etc/debz/hub.env from host if present
    - Exports pool and disconnects nbd on exit (trap-safe)

  Hostnames: <prefix>-<NN>  e.g.  kvm-01  kvm-02  kvm-03

  TEMPLATE             master | kvm | storage | vdi   required
  STAMP_COUNT          number of clones                default: 1
  STAMP_BASE_HOSTNAME  hostname prefix                 default: TEMPLATE
  STAMP_BASE_INDEX     starting node index             default: 1
  STAMP_OUTPUT_DIR     directory for clone qcow2s      default: /var/lib/debz/clones

  Examples:
    TEMPLATE=kvm ./deploy.sh stamp
    TEMPLATE=kvm STAMP_COUNT=8 ./deploy.sh stamp
    TEMPLATE=storage STAMP_COUNT=3 STAMP_BASE_HOSTNAME=stor \
      STAMP_BASE_INDEX=4 STAMP_OUTPUT_DIR=/mnt/nvme/clones ./deploy.sh stamp
    TEMPLATE=vdi STAMP_COUNT=16 STAMP_BASE_HOSTNAME=vdi ./deploy.sh stamp
EOF
}

_help_vmdk() { cat <<'EOF'
VMDK  —  convert the latest ISO to a VMDK disk image

  ./deploy.sh vmdk

  Uses: qemu-img convert -f raw -O vmdk
  Output written alongside the ISO in OUTPUT_DIR.
  Import the VMDK into VMware ESXi, Workstation, or VirtualBox.

  Examples:
    ./deploy.sh vmdk
    OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh vmdk
    ./deploy.sh build && ./deploy.sh vmdk
EOF
}

_help_rootfs() { cat <<'EOF'
ROOTFS  —  extract ISO squashfs to a raw ext4 image

  ./deploy.sh rootfs

  Mounts the ISO loopback, extracts filesystem.squashfs via unsquashfs,
  creates an ext4 image with 512 MB headroom, copies the tree into it.
  Useful for bare-metal dd flashing, Firecracker backing stores, or
  importing into Docker.

  Examples:
    ./deploy.sh rootfs
    OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh rootfs
    ./deploy.sh rootfs
    docker import "$(ls live-build/output/*-rootfs.ext4 | tail -1)" debz:trixie
EOF
}

_help_firecracker() { cat <<'EOF'
FIRECRACKER  —  build a self-contained Firecracker microVM bundle

  ./deploy.sh firecracker

  Builds rootfs first if not already present.  Bundle contains:
    rootfs.ext4      live squashfs extracted to ext4
    vmlinuz          kernel extracted from the ISO
    vm-config.json   boot source + drive + machine config (2 vCPU, 1024 MiB)
    run.sh           exec firecracker --no-api --config-file vm-config.json

  The 'firecracker' binary is pre-installed in the live ISO itself.

  Examples:
    ./deploy.sh firecracker
    OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh firecracker
    ./deploy.sh build && ./deploy.sh firecracker
    cd live-build/output/*-firecracker && sudo ./run.sh
EOF
}

_help_aws_ami() { cat <<'EOF'
AWS-AMI  —  export the latest ISO as an AWS EC2 AMI

  ./deploy.sh aws-ami

  Steps:
    1. Convert ISO to raw disk image  (qemu-img)
    2. Upload raw image to S3         (aws s3 cp)
    3. Start EC2 import-snapshot task
    4. Poll until snapshot is ready   (~5-15 min)
    5. Register AMI                   (x86_64, HVM, UEFI, gp3 root)

  Credentials: set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or use an
  instance profile.  IAM needs: ec2:ImportSnapshot,
  ec2:DescribeImportSnapshotTasks, ec2:RegisterImage, s3:PutObject.

  AWS_BUCKET    S3 bucket  (must exist, must be writable)   required
  AWS_REGION    target region                               default: us-east-1
  AWS_AMI_NAME  AMI display name                           default: debz-<timestamp>

  Examples:
    AWS_BUCKET=my-debz-images ./deploy.sh aws-ami
    AWS_BUCKET=company-images AWS_REGION=eu-west-1 \
      AWS_AMI_NAME=debz-server-trixie-20260316 ./deploy.sh aws-ami
    for region in us-east-1 eu-west-1 ap-southeast-1; do
      AWS_BUCKET=my-debz-images AWS_REGION=$region ./deploy.sh aws-ami
    done
EOF
}

_help_release() { cat <<'EOF'
RELEASE  —  package ISOs with sha256 checksums for distribution

  ./deploy.sh release

  Copies every .iso from OUTPUT_DIR into release/ and writes a
  <iso>.sha256 checksum file alongside each one.
  Run before tagging a git release.

  Examples:
    ./deploy.sh release
    OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh release
    ./deploy.sh build && ./deploy.sh release
    ./deploy.sh release && git tag -a v1.1.0 -m "debz trixie 1.1.0" && git push --tags
EOF
}

_help_workflows() { cat <<'EOF'
COMMON WORKFLOWS

── First time: full pipeline from scratch ────────────────────────────────────
  ./deploy.sh full

── Iterative dev: rebuild ISO, redeploy, no USB ──────────────────────────────
  ./deploy.sh clean && ./deploy.sh build
  USB_BURN_ON_DEPLOY=no ./deploy.sh deploy

── Build + burn to USB only (no Proxmox) ─────────────────────────────────────
  ./deploy.sh build
  USB_DEVICE=/dev/sdb ./deploy.sh burn

── Server ISO on a second Proxmox VM ─────────────────────────────────────────
  PROFILE=server VMID=910 VM_NAME=debz-server \
    VM_MEMORY=4096 USB_BURN_ON_DEPLOY=no ./deploy.sh full

── Build all four golden images ──────────────────────────────────────────────
  for t in master kvm storage vdi; do TEMPLATE=$t ./deploy.sh golden; done

── Stand up a 4-node KVM fleet ───────────────────────────────────────────────
  ./deploy.sh build
  TEMPLATE=kvm ./deploy.sh golden
  TEMPLATE=kvm STAMP_COUNT=4 ./deploy.sh stamp
  # clones at /var/lib/debz/clones/kvm-01..04.qcow2

── Expand a storage cluster: add nodes 4-6 to existing 3-node cluster ────────
  TEMPLATE=storage STAMP_COUNT=3 STAMP_BASE_HOSTNAME=stor \
    STAMP_BASE_INDEX=4 STAMP_OUTPUT_DIR=/mnt/nvme/clones ./deploy.sh stamp

── Full golden + stamp pipeline for every template ───────────────────────────
  ./deploy.sh build
  for t in master kvm storage vdi; do
    TEMPLATE=$t ./deploy.sh golden
    TEMPLATE=$t STAMP_COUNT=2 ./deploy.sh stamp
  done

── Export to AWS in three regions ────────────────────────────────────────────
  ./deploy.sh build
  for region in us-east-1 eu-west-1 ap-southeast-1; do
    AWS_BUCKET=my-debz-images AWS_REGION=$region \
      AWS_AMI_NAME=debz-trixie-$(date +%Y%m%d) ./deploy.sh aws-ami
  done

── Spawn 3 Proxmox test VMs from an ISO already uploaded ─────────────────────
  for id in 901 902 903; do
    VMID=$id VM_NAME=debz-node-$id VM_MEMORY=4096 ./deploy.sh spawn
  done

── Firecracker microVM from latest ISO ───────────────────────────────────────
  ./deploy.sh build && ./deploy.sh firecracker
  cd live-build/output/*-firecracker && sudo ./run.sh

── Release a new version ─────────────────────────────────────────────────────
  ./deploy.sh validate && ./deploy.sh build
  ./deploy.sh release
  git tag -a v1.1.0 -m "debz trixie 1.1.0" && git push --tags

── Inspect latest ISO without installing ─────────────────────────────────────
  sudo mount -o loop,ro "$(./deploy.sh latest-iso)" /mnt/iso
  ls /mnt/iso
EOF
}

_help_vars() { cat <<'EOF'
ENVIRONMENT VARIABLES  —  all variables with defaults

  See debz.env.example for the full annotated reference with example profiles.

  ISO BUILD
    PROFILE             desktop | server            default: desktop
    ARCH                amd64 | arm64               default: amd64
    OUTPUT_DIR          ISO output directory         default: live-build/output
    LOG_DIR             build log directory          default: live-build/logs
    BUILDER_IMAGE       builder Docker image tag     default: debz-live-builder:latest
    BUILDER_CONTAINER   ephemeral container name     default: debz-free-build-<PID>

  PROXMOX
    PROXMOX_HOST          IP or FQDN                  default: 10.100.10.225
    PROXMOX_NODE          cluster node name            default: fiend
    PROXMOX_TOKEN_ID      API token ID                 required (set in debz.env)
    PROXMOX_TOKEN_SECRET  API token secret UUID        required (set in debz.env)
    PROXMOX_ISO_STORE     storage ID for ISOs          default: local
    PROXMOX_VM_STORE      storage ID for VM boot disk  default: local-zfs
    PROXMOX_DATA_STORE    storage ID for extra disks   default: fireball

  VM
    VMID                VM ID                        default: 900
    VM_NAME             display name                 default: debz-live
    VM_MEMORY           RAM in MB                    default: 4096
    VM_CORES            vCPU count                   default: 4
    VM_DISK_GB          boot disk size in GB         default: 40
    VM_EXTRA_DISKS      extra data disks             default: 6
    VM_EXTRA_DISK_GB    size per extra disk in GB    default: 20
    VM_BRIDGE           Proxmox bridge               default: vmbr0
    VM_SECURE_BOOT      yes | no                     default: no
    VM_TPM              yes | no                     default: yes
    ISO_NAME            ISO filename (spawn only)    default: latest local ISO

  USB
    USB_DEVICE          /dev/sdX                     default: auto-detected
    USB_BURN_ON_DEPLOY  yes | no                     default: yes

  GOLDEN IMAGE
    TEMPLATE            master|kvm|storage|vdi       required for golden + stamp
    GOLDEN_OUTPUT       output path                  default: /var/lib/debz/golden/golden-<TEMPLATE>.qcow2
    GOLDEN_FORMAT       qcow2 | rootfs               default: qcow2
    GOLDEN_ISO          path to live ISO             default: latest in OUTPUT_DIR
    GOLDEN_SIZE         disk size in GB              default: 40

  STAMP / CLONING
    STAMP_COUNT         number of clones             default: 1
    STAMP_BASE_HOSTNAME hostname prefix              default: TEMPLATE
    STAMP_BASE_INDEX    starting node index          default: 1
    STAMP_OUTPUT_DIR    clone output directory       default: /var/lib/debz/clones

  AWS
    AWS_BUCKET          S3 bucket name               required for aws-ami
    AWS_REGION          target region                default: us-east-1
    AWS_AMI_NAME        AMI display name             default: debz-<timestamp>
EOF
}

_help_files() { cat <<'EOF'
KEY FILES AND DIRECTORIES

  builder/
    Dockerfile              build environment image definition
    container-build.sh      runs inside container, calls build-iso.sh
    build-iso.sh            lb config + lb build

  live-build/config/
    package-lists/          apt package lists baked into the ISO squashfs
    hooks/live/             scripts run inside the chroot during ISO build
    hooks/normal/           cleanup hooks run after package installation
    includes.chroot/        files copied verbatim into the squashfs root

  live-build/config/includes.chroot/usr/local/sbin/
    debz-deploy-tui         whiptail TUI (auto-launched on TTY2 at live boot)
    debz-golden             headless golden image builder
    debz-stamp-identity     per-node identity injector (nbd + ZFS import)
    debz-spawn              VM / container / k8s deploy backend
    debz-autobootstrap      30s timer: WG reflector + Salt + kubeadm
    debz-apply-role         in-place role activation via salt-call --local
    debz-k8s-join           join this node to the Kubernetes cluster

  live-build/config/includes.chroot/usr/local/bin/
    debz-install-target     main installer entry point
    debz-webui              browser-based management UI (HTTP :8080 / WS :8081)

  live-build/config/includes.chroot/srv/salt/roles/
    common.sls              packages + chrony + nftables on every node
    kvm.sls                 libvirt + bridge + qemu on KVM nodes
    storage.sls             NFS + iSCSI + Samba on storage nodes
    vdi.sls                 mediamtx + FFmpeg + NVIDIA-optional on VDI nodes
    k8s-common.sls          kubelet + kubeadm + containerd
    k8s-worker.sls          includes k8s-common
    k8s-etcd.sls            includes k8s-common, adds .kube dir

  Runtime paths (on the installed system):
    /etc/debz/              node identity (install-manifest.env, hub.env)
    /var/lib/debz/golden/   golden qcow2 images
    /var/lib/debz/clones/   CoW clone qcow2 images
    /var/log/installer/     installer logs
    /var/log/debz/          runtime logs (snapshots, firstboot, autobootstrap)

  WireGuard planes — services bind here, never on wg0:
    wg0  10.77.0.0/16  :51820  enrollment only  (unreliable on some hardware)
    wg1  10.78.0.0/16  :51821  management       (Salt master: 10.78.0.1)
    wg2  10.79.0.0/16  :51822  Kubernetes       (kubelet --node-ip, Cilium)
    wg3  10.80.0.0/16  :51823  storage          (NFS, iSCSI, ZFS replication)
EOF
}

cmd_help() {
    local topic="${1:-}"
    case "$topic" in
        "")               _help_index ;;
        build|iso)        _help_build ;;
        builder-image)    _help_builder_image ;;
        clean)            _help_clean ;;
        full)             _help_full ;;
        validate)         _help_validate ;;
        deploy)           _help_deploy ;;
        spawn)            _help_spawn ;;
        burn)             _help_burn ;;
        golden)           _help_golden ;;
        stamp)            _help_stamp ;;
        vmdk)             _help_vmdk ;;
        rootfs)           _help_rootfs ;;
        firecracker)      _help_firecracker ;;
        aws-ami)          _help_aws_ami ;;
        release)          _help_release ;;
        workflows)        _help_workflows ;;
        vars)             _help_vars ;;
        files)            _help_files ;;
        *) die "No help topic '$topic'. Run './deploy.sh help' to list topics." ;;
    esac
}

# keep the old monolith accessible for piping to less
_help_all() {
    _help_index; echo
    _help_build; echo
    _help_builder_image; echo
    _help_clean; echo
    _help_full; echo
    _help_validate; echo
    _help_deploy; echo
    _help_spawn; echo
    _help_burn; echo
    _help_golden; echo
    _help_stamp; echo
    _help_vmdk; echo
    _help_rootfs; echo
    _help_firecracker; echo
    _help_aws_ami; echo
    _help_release; echo
    _help_workflows; echo
    _help_vars; echo
    _help_files
}

# dead code below — kept so the function name exists for the dispatch
cmd_help_all() { _help_all; }

# Intentionally left empty — replaced by the modular system above
_old_cmd_help() {
    cat <<'EOF'
debz deploy.sh — build, deploy, and operate the Debz live ISO infrastructure

SYNOPSIS
    ./deploy.sh <subcommand> [VAR=value ...]

    All configuration is through environment variables.  Every variable has a
    working default.  Override inline:  VAR=value ./deploy.sh subcommand
    Or source a profile file first:    source debz.env && ./deploy.sh build

    The complete environment reference with all variables and example profiles
    is in debz.env.example at the root of this repository.

    Build pipeline overview:
      build → deploy → [burn]        push a new ISO to Proxmox and USB
      build → golden → stamp         prepare CoW VM fleet from scratch
      build → aws-ami                publish to AWS EC2
      build → vmdk / rootfs          export for VMware or bare metal
      full                           everything from scratch in one command


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ISO BUILDING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  build  (alias: iso)

      Build a Debz live ISO inside the debz-live-builder Docker container.
      The container is built automatically on the first run and reused on all
      subsequent runs.  The ISO is written to OUTPUT_DIR.

      What it does:
        1. Checks for debz-live-builder:latest; builds it if missing.
        2. Runs builder/container-build.sh inside the container.
        3. container-build.sh calls builder/build-iso.sh, which runs
           lb config + lb build inside live-build/.
        4. ISO lands in live-build/output/ (or OUTPUT_DIR if overridden).

      Build time: ~15-40 min depending on host speed and apt mirror latency.
      Subsequent builds reuse the apt cache inside the container.

      PROFILE       desktop | server          default: desktop
      ARCH          amd64 | arm64             default: amd64
      OUTPUT_DIR    ISO output directory      default: live-build/output
      LOG_DIR       build log directory       default: live-build/logs
      BUILDER_IMAGE builder Docker image tag  default: debz-live-builder:latest

      Examples:
        # Standard desktop build — most common
        ./deploy.sh build

        # Headless server build (no GNOME, no virt-manager)
        PROFILE=server ./deploy.sh build

        # Write ISO to a fast NVMe mount, keep logs there too
        OUTPUT_DIR=/mnt/nvme/iso LOG_DIR=/mnt/nvme/logs ./deploy.sh build

        # Build using a custom/pinned builder image
        BUILDER_IMAGE=debz-live-builder:20260315 ./deploy.sh build

        # Build server ISO for arm64 (e.g. Ampere, Graviton)
        PROFILE=server ARCH=arm64 ./deploy.sh build

  builder-image

      Build (or rebuild) the Docker image debz-live-builder:latest from
      builder/Dockerfile.  This image contains live-build, debootstrap,
      ZFS build tools, and all other ISO build dependencies.  You only
      need to run this explicitly when you modify builder/Dockerfile or
      want to force a clean image (e.g. after apt source updates).
      'build' calls it automatically when the image does not exist.

      BUILDER_IMAGE  image tag to create  default: debz-live-builder:latest

      Examples:
        # First-time setup or after modifying builder/Dockerfile
        ./deploy.sh builder-image

        # Build a tagged dev image without touching latest
        BUILDER_IMAGE=debz-live-builder:dev ./deploy.sh builder-image

        # Force rebuild even if the image exists (docker will use cache
        # by default — use --no-cache to bypass):
        docker rmi debz-live-builder:latest
        ./deploy.sh builder-image

  clean

      Delete all local build artifacts so the next build starts from
      scratch.  Removes: live-build/chroot, live-build/binary,
      live-build/output (or OUTPUT_DIR), live-build/work, and any
      stopped builder containers matching the debz- name prefix.

      Does NOT remove:
        - The builder Docker image (debz-live-builder:latest)
        - Golden images in /var/lib/debz/golden/
        - VM clones in /var/lib/debz/clones/ or STAMP_OUTPUT_DIR

      Examples:
        # Standard clean before a rebuild
        ./deploy.sh clean

        # Clean when OUTPUT_DIR was overridden during build
        OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh clean

        # Clean then immediately rebuild
        ./deploy.sh clean && ./deploy.sh build

  full

      The complete pipeline from scratch:
        1. Destroy VMID on Proxmox via API (non-fatal if VM doesn't exist)
        2. Run clean
        3. Remove builder image to force a fully fresh container build
        4. Prune dangling Docker images
        5. Build new builder image
        6. Build ISO
        7. Deploy ISO to Proxmox (upload + recreate VM + start)
        8. Burn ISO to USB (if USB_BURN_ON_DEPLOY=yes)

      Use this when you want absolute certainty that nothing cached is
      affecting the result — e.g. before a release, or after major
      changes to the build system.

      All VM_*, PROXMOX_*, and USB_* variables apply (see 'deploy' below).

      Examples:
        # Complete rebuild targeting the default Proxmox host
        ./deploy.sh full

        # Full rebuild, skip USB, use a second test VM slot
        VMID=901 VM_NAME=debz-test2 USB_BURN_ON_DEPLOY=no ./deploy.sh full

        # Full rebuild of server profile on a different Proxmox host
        PROFILE=server PROXMOX_HOST=10.10.0.1 VMID=920 \
          VM_NAME=debz-server VM_MEMORY=8192 VM_CORES=8 \
          USB_BURN_ON_DEPLOY=no ./deploy.sh full

        # Full rebuild with Secure Boot enabled for Secure Boot testing
        VM_SECURE_BOOT=yes VM_TPM=yes VMID=902 ./deploy.sh full

  validate

      Lint and sanity-check the entire repository before pushing.  Runs:
        1. shellcheck -S warning on every .sh file outside legacy/,
           live-build/chroot/, live-build/binary/, and live-build/cache/.
        2. shellcheck on every .hook.chroot file outside legacy/.
        3. Checks that all required directories exist.
        4. Checks that all required files exist.
        5. Exits non-zero on the first failure; prints a count of all
           failures found.

      Run this before every commit.  CI runs it on every push.

      Examples:
        # Standard validation before commit
        ./deploy.sh validate

        # Validate with a custom output directory (checks that it exists
        # when OUTPUT_DIR is overridden at validate time)
        OUTPUT_DIR=/tmp/debz-out ./deploy.sh validate

        # Use in CI — exits non-zero on any error
        ./deploy.sh validate && git push


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DEPLOYING TO PROXMOX
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  deploy

      Upload the latest ISO in OUTPUT_DIR to Proxmox via SCP, then on
      Proxmox: destroy VMID if it exists, create a new VM with the given
      spec, attach the ISO as a CDROM, attach extra data disks from
      PROXMOX_DATA_STORE for ZFS pool topology testing, and start the VM.
      Optionally burns the ISO to USB at the end.

      Proxmox SSH access must be pre-configured (key-based, passwordless).
      The script uses StrictHostKeyChecking=accept-new — the first
      connection auto-adds the host key.

      PROXMOX_HOST        Proxmox IP or FQDN             default: 10.100.10.225
      PROXMOX_ISO_STORE   Proxmox storage ID for ISOs    default: local
      PROXMOX_VM_STORE    storage ID for VM boot disk    default: local-zfs
      PROXMOX_DATA_STORE  storage ID for extra disks     default: fireball
      VMID                VM ID (must be unique)          default: 900
      VM_NAME             VM display name                 default: debz-live
      VM_MEMORY           RAM in MB                       default: 4096
      VM_CORES            virtual CPU count               default: 4
      VM_DISK_GB          boot disk size in GB            default: 40
      VM_EXTRA_DISKS      extra data disks to attach      default: 6
                          (scsi1–scsiN from PROXMOX_DATA_STORE)
                          6 = 4 data disks + 2 special vdev disks
      VM_EXTRA_DISK_GB    size of each extra disk (GB)    default: 20
      VM_BRIDGE           Proxmox network bridge          default: vmbr0
      VM_SECURE_BOOT      yes | no                        default: no
      VM_TPM              yes | no — attach TPM 2.0       default: yes
      USB_BURN_ON_DEPLOY  yes | no                        default: yes
      USB_DEVICE          /dev/sdX (auto-detected if unset)

      Examples:
        # Deploy with all defaults — most common day-to-day usage
        ./deploy.sh deploy

        # Deploy without burning to USB (laptop has no spare USB slot)
        USB_BURN_ON_DEPLOY=no ./deploy.sh deploy

        # Deploy a server build to a second VM slot on the same Proxmox
        VMID=910 VM_NAME=debz-server VM_MEMORY=4096 VM_CORES=4 \
          VM_EXTRA_DISKS=4 VM_EXTRA_DISK_GB=50 \
          USB_BURN_ON_DEPLOY=no ./deploy.sh deploy

        # Deploy to a different Proxmox host with Secure Boot testing
        PROXMOX_HOST=10.10.0.50 VMID=920 VM_NAME=debz-secureboot \
          VM_SECURE_BOOT=yes VM_TPM=yes \
          VM_MEMORY=8192 VM_CORES=8 \
          USB_BURN_ON_DEPLOY=no ./deploy.sh deploy

        # Large storage test VM — 8 extra disks × 100 GB on fireball zpool
        VMID=930 VM_NAME=debz-storage-test \
          VM_EXTRA_DISKS=8 VM_EXTRA_DISK_GB=100 \
          PROXMOX_DATA_STORE=fireball \
          USB_BURN_ON_DEPLOY=no ./deploy.sh deploy

  spawn

      Create and start a new Proxmox VM from an ISO that is already stored
      on Proxmox.  No ISO upload, no USB burn.  Used to spin up additional
      test nodes from the same ISO without re-uploading (fast).

      Behaves identically to 'deploy' except it skips the SCP upload step.
      Use ISO_NAME to specify the filename if the latest local ISO does not
      match what is already on Proxmox.

      ISO_NAME  ISO filename as listed in pvesm (default: basename of latest
                local ISO in OUTPUT_DIR, or newest .iso on Proxmox if no
                local ISO exists)
      All VM_* and PROXMOX_* variables apply.

      Examples:
        # Spin up a second test VM from the ISO already on Proxmox
        VMID=901 VM_NAME=debz-node2 ./deploy.sh spawn

        # Spawn a storage test node with 8 extra 100 GB disks
        VMID=950 VM_NAME=debz-stor \
          VM_MEMORY=4096 VM_CORES=4 \
          VM_EXTRA_DISKS=8 VM_EXTRA_DISK_GB=100 \
          ./deploy.sh spawn

        # Spawn from a specific named ISO already on Proxmox
        VMID=960 VM_NAME=debz-k8s-test \
          ISO_NAME=debz-trixie-amd64-20260316.iso \
          VM_MEMORY=16384 VM_CORES=8 \
          VM_EXTRA_DISKS=0 ./deploy.sh spawn

        # Spawn 3 nodes at once (different VMIDs, same ISO)
        for id in 901 902 903; do
          VMID=$id VM_NAME=debz-node-$id \
            VM_MEMORY=4096 USB_BURN_ON_DEPLOY=no \
            ./deploy.sh spawn
        done

  burn

      Write the latest ISO in OUTPUT_DIR to a USB block device using dd
      with bs=4M and oflag=sync.  Auto-detects a single removable drive
      by scanning /sys/block/*/removable.  Fails with a clear message if
      zero or more than one removable device is found — set USB_DEVICE
      explicitly to avoid ambiguity.

      The ISO is written raw; the USB will be bootable on any UEFI system
      (and most BIOS systems with CSM enabled).

      USB_DEVICE  /dev/sdX or /dev/nvmeXnY (auto-detected from removable)

      Examples:
        # Auto-detect the only plugged-in USB drive
        ./deploy.sh burn

        # Explicit device — safe when multiple drives are connected
        USB_DEVICE=/dev/sdb ./deploy.sh burn

        # Burn from a non-default output directory
        USB_DEVICE=/dev/sdc OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh burn

        # Build then burn in one shot (no Proxmox needed)
        ./deploy.sh build && USB_DEVICE=/dev/sdb ./deploy.sh burn


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  GOLDEN IMAGES & VM CLONING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  golden

      Build a fully-installed golden qcow2 disk image for a node template.
      Boots the live ISO headlessly in QEMU with KVM acceleration alongside
      a 32 MB FAT32 DEBZ-SEED disk containing answers.env.  The live ISO's
      debz-autoinstall.service detects the seed disk on boot and calls
      debz-install-target unattended.  QEMU exits when the installer shuts
      the VM down.  The resulting image is a complete, boot-ready ZFS
      install of the template profile.

      Templates and what they install:
        master   Salt master + WireGuard hub + Kubernetes control-plane
                 bootstrap tools + nginx + dnsmasq + nftables + chrony
        kvm      KVM hypervisor + libvirt + bridge networking + ovmf +
                 cpu-checker + nftables + chrony + salt-minion
        storage  ZFS NFS/iSCSI server + Samba + prometheus-node-exporter +
                 nftables + chrony + salt-minion
        vdi      Wayland streaming desktop + mediamtx SRT/HLS/WebRTC +
                 wf-recorder + FFmpeg + NVIDIA-optional + salt-minion

      Timeout: 1800 seconds.  Serial log: /tmp/debz-golden-serial.log
      Output:  /var/lib/debz/golden/golden-<TEMPLATE>.qcow2

      TEMPLATE      master | kvm | storage | vdi    (required)
      GOLDEN_OUTPUT custom output path              default: auto
      GOLDEN_FORMAT qcow2 | rootfs                  default: qcow2
      GOLDEN_ISO    path to the live ISO             default: latest in OUTPUT_DIR
      GOLDEN_SIZE   disk image size in GB            default: 40

      Examples:
        # Build a KVM hypervisor golden image (most common)
        TEMPLATE=kvm ./deploy.sh golden

        # Build a storage node image with a larger disk for ZFS datasets
        TEMPLATE=storage GOLDEN_SIZE=80 ./deploy.sh golden

        # Build all four templates back-to-back
        for t in master kvm storage vdi; do
          TEMPLATE=$t ./deploy.sh golden
        done

        # Build a VDI golden image from a specific ISO, write to NVMe
        TEMPLATE=vdi \
          GOLDEN_ISO=/var/lib/debz/golden/debz-trixie-amd64.iso \
          GOLDEN_OUTPUT=/mnt/nvme/gold/vdi.qcow2 \
          GOLDEN_SIZE=60 \
          ./deploy.sh golden

        # Build the master golden image and extract a rootfs image too
        TEMPLATE=master GOLDEN_FORMAT=rootfs ./deploy.sh golden

  stamp

      Create N copy-on-write qcow2 clones from a golden image using
      qemu-img create -b (backing file).  Each clone consumes only the
      delta from the golden — typically ~1 MB at creation time, growing
      only as the node writes to its disk.

      After cloning, debz-stamp-identity is run against each image:
        - Connects the qcow2 to a free /dev/nbdN via qemu-nbd
        - Imports the ZFS pool with an alternate root (read-write)
        - Injects /etc/hostname and /etc/hosts
        - Appends DEBZ_NODE_INDEX=N to /etc/debz/install-manifest.env
          (used by WireGuard IP assignment: wg1=10.78.0.N, etc.)
        - Clears /etc/machine-id (systemd regenerates on first boot)
        - Removes /var/lib/debz/firstboot-done so firstboot re-runs
        - Copies /etc/debz/hub.env from the host if present
        - Exports the pool and disconnects nbd on exit (trap-safe)

      The clones are ready to hand to debz-spawn or virt-install.

      TEMPLATE            master | kvm | storage | vdi  (required)
      STAMP_COUNT         number of clones to create    default: 1
      STAMP_BASE_HOSTNAME hostname prefix               default: same as TEMPLATE
      STAMP_BASE_INDEX    starting node index           default: 1
      STAMP_OUTPUT_DIR    directory for clone qcow2s    default: /var/lib/debz/clones

      Hostnames are formatted as <prefix>-<NN> with zero-padding:
        TEMPLATE=kvm STAMP_COUNT=3  →  kvm-01.qcow2, kvm-02.qcow2, kvm-03.qcow2

      Examples:
        # Stamp a single KVM clone (kvm-01)
        TEMPLATE=kvm ./deploy.sh stamp

        # Stamp a full rack of 8 KVM nodes (kvm-01 through kvm-08)
        TEMPLATE=kvm STAMP_COUNT=8 ./deploy.sh stamp

        # Add 3 more storage nodes to an existing stor-01..03 cluster
        TEMPLATE=storage STAMP_COUNT=3 \
          STAMP_BASE_HOSTNAME=stor STAMP_BASE_INDEX=4 \
          STAMP_OUTPUT_DIR=/mnt/nvme/clones \
          ./deploy.sh stamp

        # Stamp 16 VDI nodes with a custom hostname prefix
        TEMPLATE=vdi STAMP_COUNT=16 \
          STAMP_BASE_HOSTNAME=vdi STAMP_BASE_INDEX=1 \
          STAMP_OUTPUT_DIR=/var/lib/debz/clones \
          ./deploy.sh stamp

        # Build the master golden image then stamp a single master clone
        TEMPLATE=master ./deploy.sh golden
        TEMPLATE=master STAMP_COUNT=1 STAMP_BASE_HOSTNAME=master ./deploy.sh stamp


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  IMAGE CONVERSION & EXPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  vmdk

      Convert the latest ISO in OUTPUT_DIR to a VMDK disk image using
      qemu-img convert -f raw -O vmdk.  The VMDK is written alongside
      the ISO in OUTPUT_DIR.  Useful for importing into VMware ESXi,
      VMware Workstation, or VirtualBox.  Requires qemu-img.

      Examples:
        # Convert the latest ISO to VMDK
        ./deploy.sh vmdk

        # Convert from a non-default output directory
        OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh vmdk

        # Build then immediately convert
        ./deploy.sh build && ./deploy.sh vmdk

  rootfs

      Mount the ISO loopback, locate filesystem.squashfs, extract it
      via unsquashfs, size a new ext4 image with 512 MB headroom, and
      copy the extracted tree into it.  The ext4 image is suitable for
      bare-metal flashing via dd, Firecracker backing stores, or
      container imports.  Requires unsquashfs and mkfs.ext4.

      Examples:
        # Extract rootfs from the latest ISO
        ./deploy.sh rootfs

        # Extract from a specific output directory
        OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh rootfs

        # Extract rootfs then import into Docker as a base image
        ./deploy.sh rootfs
        ISO=$(./deploy.sh latest-iso)
        BASE=$(basename "$ISO" .iso)-rootfs.ext4
        sudo docker import "live-build/output/$BASE" debz:trixie

  firecracker

      Build a self-contained Firecracker microVM bundle directory
      containing: rootfs.ext4 (the live squashfs extracted to ext4),
      vmlinuz (kernel extracted from the ISO), vm-config.json (boot
      source + drive config + machine config: 2 vCPU, 1024 MiB RAM),
      and run.sh (convenience launcher: exec firecracker --no-api
      --config-file vm-config.json).

      Automatically calls 'rootfs' first if the ext4 image is missing.
      Requires the 'firecracker' binary in PATH on the host to run the
      bundle (it is pre-installed in the live ISO itself).

      Examples:
        # Build the Firecracker bundle from the latest ISO
        ./deploy.sh firecracker

        # Build from a specific output directory
        OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh firecracker

        # Full pipeline: build ISO → extract Firecracker bundle → launch
        ./deploy.sh build
        ./deploy.sh firecracker
        cd live-build/output/*-firecracker
        sudo ./run.sh

  aws-ami

      Export the latest ISO as an AWS EC2 AMI.  Steps:
        1. Convert ISO to a raw disk image (qemu-img).
        2. Upload the raw image to S3 (aws s3 cp).
        3. Start an EC2 import-snapshot task.
        4. Poll until the snapshot is ready (~5-15 min).
        5. Register an AMI from the snapshot (x86_64, HVM, UEFI,
           gp3 root volume, delete-on-termination).

      AWS credentials must be available in the environment via
      AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or via an IAM role
      if running from an EC2 instance.  The IAM principal needs:
        ec2:ImportSnapshot, ec2:DescribeImportSnapshotTasks,
        ec2:RegisterImage, s3:PutObject on the target bucket.

      AWS_BUCKET    S3 bucket name (must exist, writable)  required
      AWS_REGION    target AWS region                      default: us-east-1
      AWS_AMI_NAME  AMI name tag                           default: debz-<timestamp>

      Examples:
        # Publish to us-east-1 with a timestamped name
        AWS_BUCKET=my-debz-images ./deploy.sh aws-ami

        # Publish server profile to eu-west-1 with a meaningful name
        PROFILE=server \
          AWS_BUCKET=company-infra-images \
          AWS_REGION=eu-west-1 \
          AWS_AMI_NAME=debz-server-trixie-20260316 \
          ./deploy.sh aws-ami

        # Build then publish to three regions
        ./deploy.sh build
        for region in us-east-1 eu-west-1 ap-southeast-1; do
          AWS_BUCKET=my-debz-images \
            AWS_REGION=$region \
            AWS_AMI_NAME=debz-trixie-$(date +%Y%m%d) \
            ./deploy.sh aws-ami
        done


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  UTILITIES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  release

      Prepare a release bundle: copy every .iso from OUTPUT_DIR into
      release/ and write a sha256 checksum file alongside each one.
      The checksum file is named <iso>.sha256 and contains a single
      sha256sum-compatible line.  Run this before tagging a git release.

      Examples:
        # Package the latest build
        ./deploy.sh release

        # Package from a non-default output path
        OUTPUT_DIR=/mnt/nvme/iso ./deploy.sh release

        # Build, release, then tag
        ./deploy.sh build
        ./deploy.sh release
        git tag -a v1.0.0 -m "debz trixie 1.0.0"
        git push --tags

  latest-iso

      Print the absolute path of the most recently modified .iso file in
      OUTPUT_DIR.  Prints nothing and exits non-zero if no ISO is found.
      Useful for composing with other commands in shell pipelines.

      Examples:
        # Print the path
        ./deploy.sh latest-iso

        # Use in a variable
        ISO="$(./deploy.sh latest-iso)"
        echo "Latest ISO: $ISO  Size: $(du -sh "$ISO" | cut -f1)"

        # Mount the ISO loopback to inspect its contents
        ISO="$(./deploy.sh latest-iso)"
        sudo mount -o loop,ro "$ISO" /mnt/iso

        # Connect the ISO to nbd0 for direct inspection
        sudo qemu-nbd --connect=/dev/nbd0 "$(./deploy.sh latest-iso)"

  tree

      Print the repository directory tree using the 'tree' utility,
      excluding: work/, output/, *.deb, *.iso, and legacy/.
      Useful for a quick overview of what is in the repo without the
      build artifacts cluttering the view.  Requires 'tree'.

      Examples:
        ./deploy.sh tree
        ./deploy.sh tree | head -60
        ./deploy.sh tree | grep hook

  help

      Print this reference.  Pipe through less for paged reading:
        ./deploy.sh help | less
        ./deploy.sh help | less -R


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  REFERENCE: KEY FILES AND DIRECTORIES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Repository layout (run './deploy.sh tree' for full view):

    builder/
      Dockerfile            — build environment image
      container-build.sh    — runs inside the container, calls build-iso.sh
      build-iso.sh          — lb config + lb build

    live-build/config/
      package-lists/        — apt package lists baked into the ISO
      hooks/live/           — scripts that run inside the chroot at build time
      hooks/normal/         — cleanup hooks run after package install
      includes.chroot/      — files copied verbatim into the squashfs root

    live-build/config/includes.chroot/usr/local/sbin/
      debz-deploy-tui       — whiptail TUI (launched on TTY2 at live boot)
      debz-golden           — headless golden image builder
      debz-stamp-identity   — per-node identity injector (nbd + ZFS)
      debz-spawn            — VM/container/k8s deploy backend
      debz-autobootstrap    — 30s timer: WG reflector + Salt + kubeadm
      debz-apply-role       — in-place role activation via salt-call --local
      debz-k8s-join         — join this node to the Kubernetes cluster

    live-build/config/includes.chroot/usr/local/bin/
      debz-install-target   — main installer entry point
      debz-webui            — browser-based management UI (port 8080/8081)

    live-build/config/includes.chroot/srv/salt/roles/
      common.sls            — packages + chrony + nftables on every node
      kvm.sls               — libvirt + bridge + qemu on KVM nodes
      storage.sls           — NFS + iSCSI + Samba on storage nodes
      vdi.sls               — mediamtx + FFmpeg + NVIDIA-optional on VDI
      k8s-common.sls        — kubelet + kubeadm + containerd
      k8s-worker.sls        — includes k8s-common
      k8s-etcd.sls          — includes k8s-common, adds .kube dir

    /var/lib/debz/golden/   — golden qcow2 images (built by 'golden')
    /var/lib/debz/clones/   — CoW clone qcow2 images (built by 'stamp')
    /var/log/installer/     — installer logs (on the installed system)
    /var/log/debz/          — runtime logs (snapshots, firstboot, autobootstrap)

  WireGuard plane summary (memorise this — services bind here):
    wg0  10.77.0.0/16  :51820  enrollment only (unreliable on some hw — never bind services)
    wg1  10.78.0.0/16  :51821  management (Salt master binds here: 10.78.0.1)
    wg2  10.79.0.0/16  :51822  Kubernetes backend (kubelet --node-ip, Cilium)
    wg3  10.80.0.0/16  :51823  storage (NFS exports, iSCSI, ZFS replication)


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  COMMON WORKFLOWS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ── First time: build + deploy + USB ──────────────────────────────────────────
    ./deploy.sh full

  ── Iterative dev: rebuild ISO, redeploy to Proxmox, skip USB ─────────────────
    USB_BURN_ON_DEPLOY=no ./deploy.sh clean
    ./deploy.sh build
    ./deploy.sh deploy

  ── Quick ISO test without Proxmox: build + burn to USB ───────────────────────
    ./deploy.sh build
    USB_DEVICE=/dev/sdb ./deploy.sh burn

  ── Server ISO on a second Proxmox VM slot ────────────────────────────────────
    PROFILE=server VMID=910 VM_NAME=debz-server \
      VM_MEMORY=4096 VM_CORES=4 USB_BURN_ON_DEPLOY=no \
      ./deploy.sh full

  ── Build all golden images (do this once after each ISO build) ───────────────
    for t in master kvm storage vdi; do
      TEMPLATE=$t ./deploy.sh golden
    done

  ── Stand up a 4-node KVM cluster from scratch ────────────────────────────────
    ./deploy.sh build
    TEMPLATE=kvm ./deploy.sh golden
    TEMPLATE=kvm STAMP_COUNT=4 ./deploy.sh stamp
    # Clones ready at /var/lib/debz/clones/kvm-01..04.qcow2
    # Hand off to debz-spawn or virt-install

  ── Expand a storage cluster: add nodes 4-6 to an existing 3-node cluster ─────
    TEMPLATE=storage STAMP_COUNT=3 \
      STAMP_BASE_HOSTNAME=stor STAMP_BASE_INDEX=4 \
      STAMP_OUTPUT_DIR=/mnt/nvme/clones \
      ./deploy.sh stamp

  ── Full golden + stamp pipeline for all templates ────────────────────────────
    ./deploy.sh build
    for t in master kvm storage vdi; do
      TEMPLATE=$t ./deploy.sh golden
      TEMPLATE=$t STAMP_COUNT=2 ./deploy.sh stamp
    done

  ── Export to AWS us-east-1 and eu-west-1 ─────────────────────────────────────
    ./deploy.sh build
    for region in us-east-1 eu-west-1; do
      AWS_BUCKET=my-debz-images \
        AWS_REGION=$region \
        AWS_AMI_NAME=debz-trixie-$(date +%Y%m%d) \
        ./deploy.sh aws-ami
    done

  ── Export for VMware and test in VirtualBox ──────────────────────────────────
    ./deploy.sh build
    ./deploy.sh vmdk
    # Import live-build/output/*.vmdk into VMware/VirtualBox

  ── Firecracker microVM from latest ISO ───────────────────────────────────────
    ./deploy.sh build
    ./deploy.sh firecracker
    cd live-build/output/*-firecracker
    sudo ./run.sh

  ── Release a new version ─────────────────────────────────────────────────────
    ./deploy.sh validate
    ./deploy.sh build
    ./deploy.sh release
    git tag -a v1.1.0 -m "debz trixie 1.1.0"
    git push --tags

  ── Inspect the latest ISO without mounting ───────────────────────────────────
    isoinfo -l -i "$(./deploy.sh latest-iso)"
    # or
    sudo mount -o loop,ro "$(./deploy.sh latest-iso)" /mnt/iso && ls /mnt/iso

EOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

SUBCOMMAND="${1:-help}"

printf '[%s] [deploy] ════ debz deploy.sh %s  PROFILE=%s ARCH=%s ════\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SUBCOMMAND" "$PROFILE" "$ARCH"
printf '[%s] [deploy] Log: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_DEBZ_RUN_LOG"

case "$SUBCOMMAND" in
    build|iso)        cmd_build ;;
    deploy)           cmd_deploy ;;
    server-deploy)    cmd_server_deploy ;;
    proxmox-deploy)   cmd_proxmox_deploy ;;
    monitoring-deploy) cmd_monitoring_deploy ;;
    landing-deploy)   cmd_landing_deploy ;;
    lb-deploy)        cmd_lb_deploy ;;
    spawn)            cmd_spawn ;;
    burn)             cmd_burn ;;
    full)             cmd_full ;;
    full-release)     cmd_full_release ;;
    dl-upload)        cmd_dl_upload ;;
    clean)            cmd_clean ;;
    validate)         cmd_validate ;;
    release)          cmd_release ;;
    golden)           cmd_golden ;;
    stamp)            cmd_stamp ;;
    vmdk)             cmd_vmdk ;;
    images)           cmd_images "$@" ;;
    rootfs)           cmd_rootfs ;;
    firecracker)      cmd_firecracker ;;
    aws-ami)          cmd_aws_ami ;;
    builder-image)    cmd_builder_image ;;
    build-free)       cmd_build_free ;;
    build-pro)        cmd_build_pro ;;
    build-all)        cmd_build_all ;;
    site-deploy)         cmd_site_deploy ;;
    site-deploy-release) cmd_site_deploy_release ;;
    ia-upload)           cmd_ia_upload ;;
    r2-upload|publish)   cmd_publish "$@" ;;
    scc)              cmd_scc ;;
    k8s-ha)           cmd_k8s_ha ;;
    latest-iso)       cmd_latest_iso ;;
    tree)             cmd_tree ;;
    help|--help|-h)   cmd_help "${2:-}" ;;
    all)              _help_all ;;
    *)
        die "Unknown subcommand: '$SUBCOMMAND'. Run './deploy.sh help' for usage."
        ;;
esac
