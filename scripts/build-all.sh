#!/usr/bin/env bash
set -euo pipefail

vars_dir="packer/vars"

if [[ ! -d "${vars_dir}" ]]; then
  echo "Missing vars directory: ${vars_dir}" >&2
  exit 2
fi

mapfile -t var_files < <(find "${vars_dir}" -maxdepth 1 -type f -name '*.pkrvars.hcl' | sort)

if [[ ${#var_files[@]} -eq 0 ]]; then
  echo "No var files found in ${vars_dir}" >&2
  exit 2
fi

echo "Building ${#var_files[@]} boxes"
echo "SHRINK=${SHRINK:-0}"

for vf in "${var_files[@]}"; do
  box="$(basename "${vf}" .pkrvars.hcl)"
  echo
  echo "==> Building: ${box}"
  ./scripts/build.sh "${box}"
done

echo
echo "All builds completed successfully"
