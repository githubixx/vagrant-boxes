#!/usr/bin/env bash
set -euo pipefail

# Clean repo-local caches used by this project.
#
# This helps when cloud image URLs point to "current" or "latest" and you want
# to force a re-download.
#
# Env:
#   PACKER_CACHE_DIR   Cache dir used by packer downloads (default: packer_cache/packer)
#   CACHE_CLEAN_ALL=1  Also remove SSH keys and other ancillary cache (default: 0)

log() { printf '%s\n' "${*}" >&2; }

die() {
  log "ERROR: ${*}"
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

cache_clean_all="${CACHE_CLEAN_ALL:-0}"
packer_cache_dir="${PACKER_CACHE_DIR:-packer_cache/packer}"

# Safety: only allow deleting paths within this repo.
abs_packer_cache_dir="$(ROOT_DIR="${ROOT_DIR}" PACKER_CACHE_DIR="${packer_cache_dir}" python3 - <<'PY'
import os

root = os.path.realpath(os.environ["ROOT_DIR"])
d = os.path.realpath(os.environ["PACKER_CACHE_DIR"])

print(d)
ok = (os.path.commonpath([root, d]) == root) and (d != root)
print("OK" if ok else "NO")
PY
)"
abs_dir="$(printf '%s\n' "${abs_packer_cache_dir}" | head -n1)"
ok_flag="$(printf '%s\n' "${abs_packer_cache_dir}" | tail -n1)"

if [[ "${ok_flag}" != "OK" ]]; then
  die "Refusing to delete PACKER_CACHE_DIR outside repo: ${packer_cache_dir} (${abs_dir})"
fi

log "Cleaning caches..."
log "- PACKER_CACHE_DIR: ${packer_cache_dir} (${abs_dir})"

rm -rf -- "${abs_dir}" || true

# openSUSE offline patching cache (original + patched qcow2 + url marker)
rm -rf packer_cache/cloud-images || true

if [[ "${cache_clean_all}" == "1" ]]; then
  rm -rf packer_cache/ssh || true
fi

log "Done"
