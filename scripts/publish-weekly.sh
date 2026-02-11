#!/usr/bin/env bash
set -euo pipefail

# Wrapper around scripts/publish.sh intended for systemd timers / cron.
# - Adds locking (no concurrent runs)
# - Adds retries with backoff
# - Captures logs to packer/logs/

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

log() { printf '%s\n' "${*}" >&2; }

die() {
  log "ERROR: ${*}"
  exit 1
}

require_cmd() {
  command -v "${1}" >/dev/null 2>&1 || die "Missing required command: ${1}"
}

require_cmd date
require_cmd mkdir
require_cmd tee

# flock is used for locking; if missing, we fail hard to avoid concurrent publishes.
require_cmd flock

LOG_DIR="${PUBLISH_LOG_DIR:-packer/logs}"
mkdir -p "${LOG_DIR}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${LOG_DIR}/publish-${stamp}.log"

LOCK_PATH="${PUBLISH_LOCK_PATH:-packer_cache/publish.lock}"
mkdir -p "$(dirname "${LOCK_PATH}")"

# Retry settings (overridable)
RETRIES="${PUBLISH_RETRIES:-3}"
BACKOFF_SECONDS="${PUBLISH_BACKOFF_SECONDS:-30}"

# Default behavior is to build+release. You can override with e.g.
#   PUBLISH_ARGS="--no-build --no-release" scripts/publish-weekly.sh
PUBLISH_ARGS="${PUBLISH_ARGS:-}"

publish_args=()
if [[ -n "${PUBLISH_ARGS}" ]]; then
  # Intentionally split on whitespace to allow passing multiple flags.
  # If you need complex quoting, prefer setting args in the systemd unit ExecStart.
  read -r -a publish_args <<<"${PUBLISH_ARGS}"
fi

# Pass through positional args as box names (optional)
BOX_ARGS=("${@}")

# Token handling is performed by scripts/publish.sh. For non-interactive runs,
# ensure either HCP_ACCESS_TOKEN is set or `hcp auth print-access-token` works.
if ! command -v hcp >/dev/null 2>&1 && [[ -z "${HCP_ACCESS_TOKEN:-}" ]]; then
  die "Missing auth. Install+authenticate HCP CLI or set HCP_ACCESS_TOKEN."
fi

log "Writing log to: ${log_file}"

# Run everything under a lock to prevent overlapping builds/uploads.
# Use a subshell so we can pipe to tee while preserving lock scope.
(
  exec 9>"${LOCK_PATH}"
  if ! flock -n 9; then
    die "Another publish run is already active (lock: ${LOCK_PATH})"
  fi

  log "Lock acquired: ${LOCK_PATH}"
  log "PUBLISH_ARGS: ${PUBLISH_ARGS}"
  log "Boxes: ${BOX_ARGS[*]:-(all)}"

  attempt=1
  while true; do
    log "Attempt ${attempt}/${RETRIES}..."

    set +e
    ./scripts/publish.sh "${publish_args[@]}" "${BOX_ARGS[@]}"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
      log "Publish succeeded"
      exit 0
    fi

    if [[ ${attempt} -ge ${RETRIES} ]]; then
      log "Publish failed after ${RETRIES} attempts (rc=${rc})"
      exit "${rc}"
    fi

    sleep_for=$((BACKOFF_SECONDS * attempt))
    log "Publish failed (rc=${rc}); retrying in ${sleep_for}s"
    sleep "${sleep_for}"
    attempt=$((attempt + 1))
  done
) 2>&1 | tee -a "${log_file}"
