#!/usr/bin/env bash
set -euo pipefail

vars_dir="packer/vars"
molecule_dir="molecule"

if [[ ! -d "${vars_dir}" ]]; then
  echo "Missing vars dir: ${vars_dir}" >&2
  exit 2
fi

mkdir -p "${molecule_dir}"

mapfile -t var_files < <(find "${vars_dir}" -maxdepth 1 -type f -name '*.pkrvars.hcl' | sort)

if [[ ${#var_files[@]} -eq 0 ]]; then
  echo "No var files found in ${vars_dir}" >&2
  exit 2
fi

echo "Generating Molecule scenarios from ${#var_files[@]} var files"

box_namespace="${VAGRANT_BOX_NAMESPACE:-${USER:-local}}"

ip_octet=101

for vf in "${var_files[@]}"; do
  box="$(basename "${vf}" .pkrvars.hcl)"
  scenario="${box}-libvirt"
  scenario_path="${molecule_dir}/${scenario}"

  mkdir -p "${scenario_path}"

  molecule_yml_template=$(cat <<'YAML'
---
dependency:
  name: shell
  command: >-
    bash -eu -o pipefail -c '
      if [ -n "$${MOLECULE_SCENARIO_DIRECTORY:-}" ]; then
        repo_root="$$(cd "$${MOLECULE_SCENARIO_DIRECTORY}/../.." && pwd -P)"
      else
        repo_root="$$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
      fi

      detect_latest_local_version() {
        vagrant box list --machine-readable 2>/dev/null \
          | awk -F, -v want_name="__NAMESPACE__/__BOX__" -v want_provider="libvirt" -v want_arch="amd64" "
              BEGIN { }
              \$$3==\"box-name\" {bn=\$$4}
              \$$3==\"box-provider\" {bp=\$$4}
              \$$3==\"box-version\" {bv=\$$4}
              \$$3==\"box-architecture\" {
                ba=\$$4
                if (bn==want_name && bp==want_provider && (ba==want_arch || ba==\"n/a\")) print bv
              }
            " \
          | sort -V \
          | tail -n1
      }

      box_version="$${BOX_VERSION:-$$(detect_latest_local_version)}"
      box_version="$${box_version:-$$(date -u +%Y%m%d).0.0}"

      box_file="$$repo_root/output-__BOX__/package.box"
      if [ ! -f "$$box_file" ]; then
        echo "Missing box file: $$box_file" >&2
        exit 2
      fi

      box_url="file://$$box_file"
      metadata_file="$$(mktemp -t "vagrant-metadata-__BOX__.XXXXXX.json")"
      trap "rm -f '$$metadata_file' 2>/dev/null || true" EXIT

      printf "%s\n" \
        "{" \
        "  \"name\": \"__NAMESPACE__/__BOX__\"," \
        "  \"versions\": [" \
        "    {" \
        "      \"version\": \"$$box_version\"," \
        "      \"providers\": [" \
        "        {" \
        "          \"name\": \"libvirt\"," \
        "          \"architecture\": \"amd64\"," \
        "          \"url\": \"$$box_url\"" \
        "        }" \
        "      ]" \
        "    }" \
        "  ]" \
        "}" \
        > "$$metadata_file"

      vagrant box add --force "$$metadata_file"
    '

driver:
  name: vagrant

platforms:
  - name: instance
    box: "__NAMESPACE__/__BOX__"
    provider: libvirt
    interfaces:
      - network_name: private_network
        ip: 192.168.121.__IP__
    config_options:
      # Keep using the box-baked Vagrant insecure key so repeated `molecule converge`
      # doesn't break when instances are reused.
      ssh.insert_key: false

provisioner:
  name: ansible

ansible:
  playbooks:
    converge: converge.yml

verifier:
  name: ansible

YAML
)

  molecule_yml="${molecule_yml_template//__BOX__/${box}}"
  molecule_yml="${molecule_yml//__NAMESPACE__/${box_namespace}}"
  molecule_yml="${molecule_yml//__IP__/${ip_octet}}"
  printf '%s\n' "${molecule_yml}" > "${scenario_path}/molecule.yml"

  ip_octet=$((ip_octet + 1))

  cat > "${scenario_path}/converge.yml" <<'YAML'
---
- name: Converge
  import_playbook: ../../ansible/packer.yml
YAML

  cat > "${scenario_path}/cleanup.yml" <<'YAML'
---
- name: Cleanup (no-op)
  hosts: all
  gather_facts: false
  tasks: []
YAML

  cat > "${scenario_path}/verify.yml" <<'YAML'
---
- name: Verify
  hosts: all
  gather_facts: false
  tasks:
    - name: Verify python3 exists
      ansible.builtin.raw: command -v python3
      register: python3_path
      changed_when: false
      failed_when: python3_path.rc != 0

    - name: Verify python3 runs and can import basics
      ansible.builtin.raw: >-
        python3 -c 'import sys, json, ssl; print(sys.version.split()[0]); print(json.dumps({"ok": True}))'
      register: python3_smoke
      changed_when: false
      failed_when: python3_smoke.rc != 0

    - name: Show python3 smoke output
      ansible.builtin.debug:
        var: python3_smoke.stdout_lines
YAML

done

echo "Done. Scenarios created under ${molecule_dir}/ (e.g. molecule test -s ubuntu-24.04-libvirt)"
