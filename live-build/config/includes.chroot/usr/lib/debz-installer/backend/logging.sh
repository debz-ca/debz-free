#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# logging.sh — installer logging setup (sourced after common.sh)
# Sets up per-subsystem log files and redirects output to master log.
# ---------------------------------------------------------------------------

# Requires: DEBZ_LOG_DIR (set in common.sh)

# Create log directory
mkdir -p "${DEBZ_LOG_DIR}"

# Master installer log
DEBZ_LOG="${DEBZ_LOG_DIR}/debz-installer.log"

# Subsystem logs
STORAGE_LOG="${DEBZ_LOG_DIR}/storage.log"
ZFS_LOG="${DEBZ_LOG_DIR}/zfs.log"
SECURITY_LOG="${DEBZ_LOG_DIR}/security.log"
NETWORK_LOG="${DEBZ_LOG_DIR}/network.log"
BOOTSTRAP_LOG="${DEBZ_LOG_DIR}/bootstrap.log"

export DEBZ_LOG STORAGE_LOG ZFS_LOG SECURITY_LOG NETWORK_LOG BOOTSTRAP_LOG

# Touch all log files so they exist from the start
touch \
    "$DEBZ_LOG" \
    "$STORAGE_LOG" \
    "$ZFS_LOG" \
    "$SECURITY_LOG" \
    "$NETWORK_LOG" \
    "$BOOTSTRAP_LOG"

# Redirect stdout and stderr to tee into DEBZ_LOG while still showing
# output to the terminal/console. Only redirect if not already done.
if [[ "${_DEBZ_LOGGING_INIT:-0}" != "1" ]]; then
    _DEBZ_LOGGING_INIT=1
    export _DEBZ_LOGGING_INIT
    exec > >(tee -a "$DEBZ_LOG") 2>&1
fi

log "Logging initialized. Master log: $DEBZ_LOG"
log "Subsystem logs: storage=$STORAGE_LOG zfs=$ZFS_LOG security=$SECURITY_LOG network=$NETWORK_LOG bootstrap=$BOOTSTRAP_LOG"
