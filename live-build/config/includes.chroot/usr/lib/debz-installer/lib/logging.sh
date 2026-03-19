#!/usr/bin/env bash
# Sourced by debz-install-target — sets DEBZ_*_LOG paths and k_log_section
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# shellcheck disable=SC2034
DEBZ_STORAGE_LOG="${DEBZ_LOG_DIR}/storage.log"
# shellcheck disable=SC2034
DEBZ_ZFS_LOG="${DEBZ_LOG_DIR}/zfs.log"
# shellcheck disable=SC2034
DEBZ_SECURITY_LOG="${DEBZ_LOG_DIR}/security.log"
# shellcheck disable=SC2034
DEBZ_NETWORK_LOG="${DEBZ_LOG_DIR}/network.log"
# shellcheck disable=SC2034
DEBZ_BOOTSTRAP_LOG="${DEBZ_LOG_DIR}/bootstrap.log"

k_log_section() {
  local title="$1"
  k_log "========== ${title} =========="
}

k_log_to() {
  local logfile="$1"
  shift
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile" >&2
}
