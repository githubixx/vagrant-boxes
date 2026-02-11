#!/usr/bin/env bash
set -euo pipefail

shrink_enable="${SHRINK_ENABLE:-false}"
shrink_mode="${SHRINK_MODE:-safe}"
output_dir="${PACKER_OUTPUT_DIR:-}"
box_name="${BOX_NAME:-unknown}"

if [[ "${shrink_enable}" != "true" ]]; then
  exit 0
fi

if [[ "${shrink_mode}" != "safe" && "${shrink_mode}" != "full" ]]; then
  echo "[shrink] Invalid SHRINK_MODE: '${shrink_mode}' (expected safe|full)" >&2
  exit 2
fi

if [[ -z "${output_dir}" || ! -d "${output_dir}" ]]; then
  echo "[shrink] PACKER_OUTPUT_DIR is missing or not a directory: '${output_dir}'" >&2
  exit 2
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "[shrink] qemu-img not found. Install qemu-utils/qemu-img on the host." >&2
  exit 2
fi

if [[ "${shrink_mode}" == "full" ]]; then
  if ! command -v virt-sysprep >/dev/null 2>&1; then
    echo "[shrink] virt-sysprep not found but SHRINK_MODE=full. Install libguestfs-tools." >&2
    exit 2
  fi
  if ! command -v virt-sparsify >/dev/null 2>&1; then
    echo "[shrink] virt-sparsify not found but SHRINK_MODE=full. Install libguestfs-tools." >&2
    exit 2
  fi
fi

mapfile -t candidates < <(find "${output_dir}" -maxdepth 2 -type f \( -name '*.qcow2' -o -name '*.img' \) | sort)

# Some templates (cloud images) produce an extensionless qcow2 file named after the box,
# e.g. output-<box>/qemu/<box>. Detect those by probing qemu-img info.
if [[ ${#candidates[@]} -eq 0 ]]; then
  mapfile -t probe_files < <(find "${output_dir}" -maxdepth 2 -type f | sort)
  for f in "${probe_files[@]}"; do
    if qemu-img info "${f}" >/dev/null 2>&1; then
      candidates+=("${f}")
    fi
  done
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "[shrink] No disk image found in ${output_dir}" >&2
  exit 2
fi

image="${candidates[0]}"

# Prefer the largest file if multiple images are present.
if [[ ${#candidates[@]} -gt 1 ]]; then
  image="$(ls -S "${candidates[@]}" | head -n1)"
fi

fmt="$(qemu-img info "${image}" 2>/dev/null | awk -F': ' '/file format/ {print $2; exit}')"
if [[ -z "${fmt}" ]]; then
  fmt="qcow2"
fi

echo "[shrink] Box: ${box_name}"
echo "[shrink] Image: ${image} (${fmt})"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# 1) virt-sysprep (safe subset). Do NOT remove user home dirs or ssh host keys.
if command -v virt-sysprep >/dev/null 2>&1; then
  echo "[shrink] Running virt-sysprep (safe operations)"
  # Exclude operations that commonly break connectivity.
  virt-sysprep \
    --operations defaults,-ssh-userdir,-ssh-hostkeys,-customize \
    -a "${image}" \
    || {
      echo "[shrink] virt-sysprep failed; continuing" >&2
    }
else
  echo "[shrink] virt-sysprep not found (skipping). Install libguestfs-tools to enable." >&2
fi

# 2) virt-sparsify (best size wins)
if command -v virt-sparsify >/dev/null 2>&1; then
  echo "[shrink] Running virt-sparsify"
  sparsified="${tmp_dir}/sparsified.$(basename "${image}")"
  virt-sparsify "${image}" "${sparsified}"
  mv -f "${sparsified}" "${image}"
else
  echo "[shrink] virt-sparsify not found (skipping). Install libguestfs-tools to enable." >&2
fi

# 3) Always: qcow2 compression via qemu-img convert
compressed="${tmp_dir}/compressed.$(basename "${image}")"
echo "[shrink] Running qemu-img convert (qcow2, compressed)"
qemu-img convert -p -f "${fmt}" -O qcow2 -c "${image}" "${compressed}"
mv -f "${compressed}" "${image}"

echo "[shrink] Done"
