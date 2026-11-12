#!/usr/bin/env bash
set -euo pipefail

# Ensure we run from the repo root so relative paths and `vagrant` work reliably
# (even if invoked from an ephemeral directory that may get deleted).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

box_name="${1:-}"
if [[ -z "${box_name}" ]]; then
  echo "Usage: ${0} <box-name>" >&2
  exit 2
fi

var_file="packer/vars/${box_name}.pkrvars.hcl"
if [[ ! -f "${var_file}" ]]; then
  echo "Missing var file: ${var_file}" >&2
  exit 2
fi

download_with_backoff() {
  local url="${1}"
  local dest="${2}"

  if [[ -z "${url}" || -z "${dest}" ]]; then
    echo "download_with_backoff: missing url or dest" >&2
    return 2
  fi

  local -a delays=(3 6 9) # 3 retries -> 4 total attempts
  local attempt=1
  local max_attempts=$((1 + ${#delays[@]}))

  while (( attempt <= max_attempts )); do
    echo "Downloading (${attempt}/${max_attempts}): ${url}" >&2

    if command -v curl >/dev/null 2>&1; then
      if curl -L --fail -o "${dest}" "${url}"; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -O "${dest}" "${url}"; then
        return 0
      fi
    else
      echo "Neither curl nor wget found; cannot download: ${url}" >&2
      return 2
    fi

    if (( attempt == max_attempts )); then
      echo "Download failed after ${max_attempts} attempts: ${url}" >&2
      return 1
    fi

    local sleep_s="${delays[$((attempt - 1))]}"
    echo "Download failed; retrying in ${sleep_s}s..." >&2
    sleep "${sleep_s}"
    attempt=$((attempt + 1))
  done
}

maybe_cache_cloud_image() {
  local box_name="${1}"
  local var_file="${2}"

  # Only relevant for qcow2 cloud-image builds (not ISO/AutoYaST).
  if grep -qE '^\s*iso_url\s*=' "${var_file}"; then
    return 0
  fi

  local cloud_image_url
  cloud_image_url="$(
    grep -E '^\s*cloud_image_url\s*=' "${var_file}" \
      | head -n1 \
      | sed -E 's/^\s*cloud_image_url\s*=\s*"([^"]+)"\s*$/\1/'
  )"

  if [[ -z "${cloud_image_url}" ]]; then
    return 0
  fi

  # Only pre-cache remote downloads. Local paths (including already-patched images)
  # should be passed through unchanged.
  if [[ ! "${cloud_image_url}" =~ ^https?:// ]]; then
    return 0
  fi

  local cache_dir="packer_cache/cloud-images"
  mkdir -p "${cache_dir}"

  local url_marker="${cache_dir}/${box_name}.cloud.url"
  local cached_image="${cache_dir}/${box_name}.cloud.qcow2"
  local tmp_image="${cached_image}.tmp"

  if [[ -f "${cached_image}" && -f "${url_marker}" ]] && [[ "$(cat "${url_marker}")" == "${cloud_image_url}" ]]; then
    realpath "${cached_image}"
    return 0
  fi

  rm -f "${tmp_image}" 2>/dev/null || true
  download_with_backoff "${cloud_image_url}" "${tmp_image}"
  mv -f "${tmp_image}" "${cached_image}"
  echo "${cloud_image_url}" > "${url_marker}"

  realpath "${cached_image}"
}

maybe_cache_installer_iso() {
  local box_name="${1}"
  local var_file="${2}"

  # Only relevant for ISO/installer builds.
  if ! grep -qE '^\s*iso_url\s*=' "${var_file}"; then
    return 0
  fi

  local iso_url
  iso_url="$(
    grep -E '^\s*iso_url\s*=' "${var_file}" \
      | head -n1 \
      | sed -E 's/^\s*iso_url\s*=\s*"([^"]+)"\s*$/\1/'
  )"

  if [[ -z "${iso_url}" ]]; then
    return 0
  fi

  # Only pre-cache remote downloads.
  if [[ ! "${iso_url}" =~ ^https?:// ]]; then
    return 0
  fi

  local cache_dir="packer_cache/isos"
  mkdir -p "${cache_dir}"

  local url_marker="${cache_dir}/${box_name}.iso.url"
  local cached_iso="${cache_dir}/${box_name}.iso"
  local tmp_iso="${cached_iso}.tmp"

  if [[ -f "${cached_iso}" && -f "${url_marker}" ]] && [[ "$(cat "${url_marker}")" == "${iso_url}" ]]; then
    realpath "${cached_iso}"
    return 0
  fi

  rm -f "${tmp_iso}" 2>/dev/null || true
  download_with_backoff "${iso_url}" "${tmp_iso}"
  mv -f "${tmp_iso}" "${cached_iso}"
  echo "${iso_url}" > "${url_marker}"

  realpath "${cached_iso}"
}

maybe_patch_opensuse_cloud_image() {
  local box_name="${1}"
  local var_file="${2}"

  # Only relevant for qcow2 cloud-image builds (not ISO/AutoYaST).
  if grep -qE '^\s*iso_url\s*=' "${var_file}"; then
    return 0
  fi

  case "${box_name}" in
    opensuse-*) ;;
    *) return 0 ;;
  esac

  local cloud_image_url
  cloud_image_url="$(
    grep -E '^\s*cloud_image_url\s*=' "${var_file}" \
      | head -n1 \
      | sed -E 's/^\s*cloud_image_url\s*=\s*"([^"]+)"\s*$/\1/'
  )"

  if [[ -z "${cloud_image_url}" ]]; then
    return 0
  fi

  local cache_dir="packer_cache/cloud-images"
  mkdir -p "${cache_dir}"

  local ssh_cache_dir="packer_cache/ssh"
  mkdir -p "${ssh_cache_dir}"

  local ssh_key_priv="${ssh_cache_dir}/${box_name}.root_ssh_key"
  local ssh_key_pub="${ssh_key_priv}.pub"

  if [[ ! -f "${ssh_key_priv}" || ! -f "${ssh_key_pub}" ]]; then
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      echo "ssh-keygen not found; cannot generate SSH key for openSUSE communicator." >&2
      exit 2
    fi
    rm -f "${ssh_key_priv}" "${ssh_key_pub}"
    ssh-keygen -t rsa -b 4096 -N "" -f "${ssh_key_priv}" >/dev/null
    chmod 0600 "${ssh_key_priv}"
    chmod 0644 "${ssh_key_pub}"
  fi

  local url_marker="${cache_dir}/${box_name}.url"
  local orig_image="${cache_dir}/${box_name}.orig.qcow2"
  local patched_image="${cache_dir}/${box_name}.patched.qcow2"

  if [[ -f "${patched_image}" && -f "${url_marker}" ]] && [[ "$(cat "${url_marker}")" == "${cloud_image_url}" ]]; then
    realpath "${patched_image}"
    return 0
  fi

  echo "Preparing patched openSUSE image for unattended boot..." >&2
  echo "- source:  ${cloud_image_url}" >&2
  echo "- patched: ${patched_image}" >&2
  echo "- ssh key: ${ssh_key_priv}" >&2

  download_with_backoff "${cloud_image_url}" "${orig_image}"

  # Copy before customizing; virt-customize modifies the image in-place.
  if cp --reflink=auto "${orig_image}" "${patched_image}" 2>/dev/null; then
    true
  else
    cp "${orig_image}" "${patched_image}"
  fi

  if ! command -v virt-customize >/dev/null 2>&1; then
    echo "virt-customize not found; cannot patch openSUSE image to disable firstboot." >&2
    exit 2
  fi

  # libguestfs is more reliable with direct backend on some hosts.
  export LIBGUESTFS_BACKEND=direct

  # IMPORTANT: virt-customize prints progress to stdout; if this function is used
  # in a command substitution, that output would corrupt the returned path.
  # Redirect stdout to stderr so callers capture only the final path.
  virt-customize -a "${patched_image}" \
    --ssh-inject "root:file:${ssh_key_pub}" \
    --run-command 'set -eu

# Ensure the primary NIC comes up with DHCP. On openSUSE images the default
# network stack can be wicked; some minimal images come up with the interface DOWN
# unless an ifcfg file exists.
mkdir -p /etc/sysconfig/network
for dev in eth0 eth1; do
  cat > "/etc/sysconfig/network/ifcfg-${dev}" <<"EOF"
BOOTPROTO="dhcp"
STARTMODE="auto"
EOF
done

# Ensure DHCP works even when the NIC name differs at runtime (e.g. Vagrant/libvirt
# can present only eth1, or different predictable names). Create ifcfg files for
# whatever interfaces exist at boot and try to bring them up.
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/ghx-ensure-dhcp-all-nics <<"EOF"
#!/bin/sh
set -eu

if command -v ip >/dev/null 2>&1; then
  ifnames="$(ip -o link show | cut -d: -f2 | sed -e "s/^ *//" -e "s/ .*//" | cut -d@ -f1 | grep -v '^lo$' || true)"
else
  ifnames=""
fi

mkdir -p /etc/sysconfig/network

for dev in ${ifnames}; do
  ip link set dev "${dev}" up >/dev/null 2>&1 || true
  if [ ! -f "/etc/sysconfig/network/ifcfg-${dev}" ]; then
    cat > "/etc/sysconfig/network/ifcfg-${dev}" <<"EON"
BOOTPROTO="dhcp"
STARTMODE="auto"
EON
  fi
done

if command -v wicked >/dev/null 2>&1; then
  wicked ifup all >/dev/null 2>&1 || true
fi

if command -v dhclient >/dev/null 2>&1; then
  for dev in ${ifnames}; do
    dhclient -1 "${dev}" >/dev/null 2>&1 || true
  done
fi

exit 0
EOF
chmod 0755 /usr/local/sbin/ghx-ensure-dhcp-all-nics

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/ghx-ensure-dhcp-all-nics.service <<"EOF"
[Unit]
Description=Ensure DHCP on all NICs (first boot safety net)
After=systemd-udevd.service
Before=sshd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ghx-ensure-dhcp-all-nics

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_OFFLINE=1 systemctl enable ghx-ensure-dhcp-all-nics.service 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^wicked\\.service"; then
    SYSTEMD_OFFLINE=1 systemctl enable wicked.service 2>/dev/null || true
    SYSTEMD_OFFLINE=1 systemctl enable wicked-dhcp4.service 2>/dev/null || true
    SYSTEMD_OFFLINE=1 systemctl enable wicked-dhcp6.service 2>/dev/null || true
    SYSTEMD_OFFLINE=1 systemctl disable systemd-networkd.service 2>/dev/null || true
  else
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/20-wired-dhcp.network <<"EOF"
[Match]
Type=ethernet

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
    SYSTEMD_OFFLINE=1 systemctl enable systemd-networkd.service 2>/dev/null || true
    SYSTEMD_OFFLINE=1 systemctl enable systemd-resolved.service 2>/dev/null || true
  fi
fi
' \
    --run-command 'set -eu; printf "FIRSTBOOT=no\n" > /etc/sysconfig/firstboot || true' \
    --run-command 'set -eu; rm -f /etc/YaST2/firstboot.xml /etc/YaST2/firstboot* /var/lib/YaST2/firstboot* 2>/dev/null || true' \
    --run-command 'set -eu; mkdir -p /etc/systemd/system; for p in /usr/lib/systemd/system/*firstboot*.service /etc/systemd/system/*firstboot*.service; do [ -e "${p}" ] || continue; u="$(basename "${p}")"; ln -sf /dev/null "/etc/systemd/system/${u}"; done; true' \
    --run-command 'set -eu; if ! getent group wheel >/dev/null 2>&1; then groupadd -r wheel || true; fi' \
    --run-command 'set -eu; if ! id -u vagrant >/dev/null 2>&1; then useradd -m -s /bin/bash -G wheel vagrant; fi' \
    --run-command 'set -eu; echo "vagrant:vagrant" | chpasswd || true' \
    --run-command 'set -eu; echo "root:vagrant" | chpasswd || true' \
    --run-command 'set -eu; passwd -u root >/dev/null 2>&1 || true' \
    --run-command 'set -eu; mkdir -p /etc/sudoers.d; printf "vagrant ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/vagrant; chmod 0440 /etc/sudoers.d/vagrant' \
    --run-command 'set -eu; if [ -f /etc/ssh/sshd_config ]; then grep -q "^PasswordAuthentication" /etc/ssh/sshd_config && sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config || printf "\nPasswordAuthentication yes\n" >> /etc/ssh/sshd_config; fi' \
    --run-command 'set -eu; if [ -f /etc/ssh/sshd_config ]; then grep -q "^PermitRootLogin" /etc/ssh/sshd_config && sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config || printf "\nPermitRootLogin yes\n" >> /etc/ssh/sshd_config; fi' \
    --run-command 'set -eu; if [ -d /etc/ssh/sshd_config.d ]; then printf "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n" > /etc/ssh/sshd_config.d/90-packer.conf; fi' \
    --run-command 'set -eu; SYSTEMD_OFFLINE=1 systemctl enable sshd.service 2>/dev/null || SYSTEMD_OFFLINE=1 systemctl enable ssh.service 2>/dev/null || true' \
    --run-command 'set -eu; SYSTEMD_OFFLINE=1 systemctl disable firewalld.service 2>/dev/null || true; ln -sf /dev/null /etc/systemd/system/firewalld.service 2>/dev/null || true' \
    1>&2

  echo "${cloud_image_url}" > "${url_marker}"

  realpath "${patched_image}"
}

# Put packer downloads into a repo-local cache directory by default.
# This matters because many cloud image URLs are "current" or "latest" and
# would otherwise remain cached indefinitely under the user's home directory.
export PACKER_CACHE_DIR="${PACKER_CACHE_DIR:-packer_cache/packer}"
mkdir -p "${PACKER_CACHE_DIR}"

# Packer qemu builder requires output_directory to not exist.
rm -rf "output-${box_name}/qemu"

packer_args=(
  build
  -force
  -var-file "${var_file}"
)

shrink_env="${SHRINK:-none}"

case "${shrink_env}" in
  ""|none|0)
    ;;
  safe|1)
    packer_args+=( -var "shrink_enable=true" -var "shrink_mode=safe" )
    ;;
  full)
    packer_args+=( -var "shrink_enable=true" -var "shrink_mode=full" )
    ;;
  *)
    echo "Invalid SHRINK value: '${shrink_env}' (expected none|safe|full; aliases: 0->none, 1->safe)" >&2
    exit 2
    ;;
esac

packer_template="packer/templates/libvirt-cloudimg.pkr.hcl"
packer_init_dir="packer/templates"

# If the var-file defines iso_url, use the ISO installer (AutoYaST) template.
# Otherwise default to the cloud qcow2 template.
if grep -qE '^\s*iso_url\s*=' "${var_file}"; then
  packer_template="packer/templates/opensuse-autoyast/libvirt-opensuse-autoyast.pkr.hcl"
  packer_init_dir="packer/templates/opensuse-autoyast"
fi

# For ISO/installer builds, pre-download with retries and point Packer at the local file.
cached_installer_iso="$(maybe_cache_installer_iso "${box_name}" "${var_file}" || true)"
if [[ -n "${cached_installer_iso:-}" ]]; then
  packer_args+=( -var "iso_url=${cached_installer_iso}" )
fi

# openSUSE JeOS/Minimal-VM images can show an interactive firstboot screen that blocks SSH.
# Patch the qcow2 image offline and override cloud_image_url to the local patched path.
patched_cloud_image="$(maybe_patch_opensuse_cloud_image "${box_name}" "${var_file}" || true)"
if [[ -n "${patched_cloud_image:-}" ]]; then
  packer_args+=( -var "cloud_image_url=${patched_cloud_image}" )

  # For openSUSE qcow2 builds, we inject a deterministic root SSH key during
  # offline image patching. Pass it explicitly to the communicator.
  case "${box_name}" in
    opensuse-*)
      ssh_key_priv="packer_cache/ssh/${box_name}.root_ssh_key"
      if [[ -f "${ssh_key_priv}" ]]; then
        packer_args+=( -var "ssh_private_key_file=$(realpath "${ssh_key_priv}")" )
      fi
      ;;
  esac
fi

# For non-openSUSE cloud images, pre-download with retries and point Packer at the local file.
if [[ -z "${patched_cloud_image:-}" ]]; then
  cached_cloud_image="$(maybe_cache_cloud_image "${box_name}" "${var_file}" || true)"
  if [[ -n "${cached_cloud_image:-}" ]]; then
    packer_args+=( -var "cloud_image_url=${cached_cloud_image}" )
  fi
fi

packer init "${packer_init_dir}" >/dev/null

packer "${packer_args[@]}" "${packer_template}"

# Optional: automatically add the freshly built box to the local Vagrant box store
# so it becomes visible in `vagrant box list`.
#
# Config:
#   VAGRANT_ADD_BOX=1|0           (default: 1)
#   VAGRANT_BOX_NAMESPACE=name    (default: $USER, else local)
#   VAGRANT_BOX_PROVIDER=name     (default: libvirt)
vagrant_add_box="${VAGRANT_ADD_BOX:-1}"
vagrant_box_namespace="${VAGRANT_BOX_NAMESPACE:-${USER:-local}}"
vagrant_box_provider="${VAGRANT_BOX_PROVIDER:-libvirt}"
vagrant_box_version="${VAGRANT_BOX_VERSION:-}"
vagrant_box_version_auto_bump="${VAGRANT_BOX_VERSION_AUTO_BUMP:-1}"
vagrant_prune_old_versions="${VAGRANT_PRUNE_OLD_VERSIONS:-1}"
vagrant_box_arch="${VAGRANT_BOX_ARCH:-amd64}"

box_artifact="output-${box_name}/package.box"
vagrant_box_name="${vagrant_box_namespace}/${box_name}"

resolve_next_local_box_version() {
  local box_name="${1}"
  local provider="${2}"
  local arch="${3}"

  local base_date prefix
  base_date="$(date -u +%Y%m%d)"
  prefix="${base_date}.0."

  # Determine highest existing same-day patch and bump it.
  # Machine-readable output contains repeating groups of:
  # box-name, box-provider, box-version, box-architecture
  local next_patch
  next_patch="$(
    vagrant box list --machine-readable 2>/dev/null \
      | awk -F, -v want_name="${box_name}" -v want_provider="${provider}" -v want_arch="${arch}" -v prefix="${prefix}" '
          BEGIN { max=-1 }
          $3=="box-name" {bn=$4}
          $3=="box-provider" {bp=$4}
          $3=="box-version" {bv=$4}
          $3=="box-architecture" {
            ba=$4
            if (bn==want_name && bp==want_provider && (ba==want_arch || ba=="n/a") && bv ~ ("^" prefix "[0-9]+$")) {
              sub("^" prefix, "", bv)
              if ((bv+0) > max) max=bv+0
            }
          }
          END { if (max < 0) print 0; else print max+1 }
        '
  )"

  if [[ -z "${next_patch}" ]]; then
    next_patch="0"
  fi

  printf '%s' "${prefix}${next_patch}"
}

if [[ "${vagrant_add_box}" == "1" ]]; then
  if command -v vagrant >/dev/null 2>&1; then
    if [[ -f "${box_artifact}" ]]; then
      if [[ -z "${vagrant_box_version}" ]]; then
        if [[ "${vagrant_box_version_auto_bump}" == "1" ]]; then
          vagrant_box_version="$(resolve_next_local_box_version "${vagrant_box_name}" "${vagrant_box_provider}" "${vagrant_box_arch}" || true)"
        fi
        vagrant_box_version="${vagrant_box_version:-$(date -u +%Y%m%d).0.0}"
      fi

      if [[ "${vagrant_prune_old_versions}" == "1" ]]; then
        vagrant box remove -f --all --provider "${vagrant_box_provider}" --architecture "${vagrant_box_arch}" "${vagrant_box_name}" >/dev/null 2>&1 || true
      fi
      echo "Adding box to local Vagrant store: ${vagrant_box_name} (${vagrant_box_provider}, ${vagrant_box_version})" >&2

      # Vagrant does not allow --box-version when adding directly from a local .box file.
      # Use a metadata JSON pointing to the local box via file:// so versioning works.
      box_url="file://$(realpath "${box_artifact}")"
      metadata_file="$(mktemp -t "vagrant-metadata-${box_name}.XXXXXX.json")"
      trap 'rm -f "${metadata_file}" 2>/dev/null || true' RETURN

      printf '%s\n' \
        '{' \
        "  \"name\": \"${vagrant_box_name}\"," \
        '  "versions": [' \
        '    {' \
        "      \"version\": \"${vagrant_box_version}\"," \
        '      "providers": [' \
        '        {' \
        "          \"name\": \"${vagrant_box_provider}\"," \
        "          \"architecture\": \"${vagrant_box_arch}\"," \
        "          \"url\": \"${box_url}\"" \
        '        }' \
        '      ]' \
        '    }' \
        '  ]' \
        '}' \
        > "${metadata_file}"

      vagrant box add --force "${metadata_file}" >/dev/null
    else
      echo "Built box artifact not found; cannot add to Vagrant: ${box_artifact}" >&2
    fi
  else
    echo "vagrant not found; skipping automatic 'vagrant box add' (set VAGRANT_ADD_BOX=0 to silence)." >&2
  fi
fi
