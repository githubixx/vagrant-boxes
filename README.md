# Libvirt Vagrant boxes/images (Packer + Ansible)

Build minimal Vagrant base boxes for the **libvirt** provider using **HashiCorp Packer** (qemu builder) and provision them using **Ansible**.

This repo is intentionally focused on **minimal guest packages** suitable for **Ansible + Molecule** workflows. This repo can be used to build your own images locally on a Linux host. For requirements see below.

## Goals

- Have a Python version installed supported by Ansible
- Every box has `eth0` interface
- Boxes are based on Cloud images as published by Linux distributions
- Support optional image shrinking to keep box sizes small
- Minimal changes to original images (only what's needed to make it work with Ansible + Molecule + network connectivity)
- Focus on server functionality

## Supported targets

The following targets can be built locally:

- Ubuntu: 22.04, 24.04, 26.04
- Debian: 12, 13
- Fedora: 42, 43, 44
- Rocky Linux: 9, 10
- AlmaLinux: 9, 10
- Arch Linux
- openSUSE Leap: 15.6, 16.0

## Host prerequisites

### Needed

- `packer`
- QEMU/KVM + libvirt (`qemu-system-x86_64`, `virsh`, etc.)
- `vagrant` + `vagrant-libvirt`
- Python tooling for provisioning/tests: `ansible-core`, `molecule`, `molecule-vagrant` (see `requirements.txt`)

### HCP Vagrant Registry deprecation

HashiCorp is [deprecating HCP Vagrant Registry](https://developer.hashicorp.com/hcp/docs/vagrant/hcp-vagrant-eol): new box creation ended October 1, 2026, and registry operations end December 31, 2026. Registry publishing support has been removed from this repository. Build boxes locally as described below, or host them elsewhere if you need to share them; Vagrant itself remains available.

If you installed the former publishing timer, disable it with `sudo systemctl disable --now vagrant-box-publish.timer`.

## Quick start

```bash
# Install host deps (example)
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt

# Build a box
make build BOX=ubuntu-24.04

# By default, builds also run `vagrant box add` so the result shows up in `vagrant box list`.
# The auto-added box version defaults to `$(date -u +%Y%m%d).0.<patch>` and auto-increments `<patch>` on the same day.
# Override with `VAGRANT_BOX_VERSION=...` (disables auto-bump) or disable auto-bump via `VAGRANT_BOX_VERSION_AUTO_BUMP=0`.
# To avoid stale versions lingering in `vagrant box list`, existing local versions are removed first
# (same name + provider). Disable with `VAGRANT_PRUNE_OLD_VERSIONS=0`.
# Disable with:
# VAGRANT_ADD_BOX=0 make build BOX=ubuntu-24.04
# Note: Vagrant does not support `--box-version` when adding directly from a local `.box` file; the script uses a temporary Vagrant metadata JSON (with a `file://` URL) so the version shows up correctly.
# Architecture defaults to `amd64`; override with `VAGRANT_BOX_ARCH=...`.

# Build all boxes (sequential; stops on first failure)
make build-all

# Refresh caches + rebuild all boxes.
# By default this also re-adds boxes to Vagrant so local versions auto-bump.
# To rebuild without touching your local Vagrant box store, run:
# VAGRANT_ADD_BOX=0 make cache-refresh-all
make cache-refresh-all

# Use the box locally
vagrant init ./output-ubuntu-24.04/package.box
vagrant up --provider=libvirt
vagrant ssh

# Molecule (runs Vagrant with libvirt)
# Generate one scenario per packer/vars/*.pkrvars.hcl (scenario name: <box>-libvirt)
make molecule-gen

# Then run e.g.
molecule test -s ubuntu-24.04-libvirt
molecule test -s ubuntu-22.04-libvirt
molecule test -s archlinux-libvirt
```

## Notes on “minimal packages”

Provisioning first updates the guest to the latest available packages (including security updates), then installs only what’s typically required for Vagrant + Ansible usage:

- SSH server
- `sudo`
- Python (already present on most cloud images via cloud-init)
- `rsync` (common Vagrant synced folder mechanism)
- `qemu-guest-agent`

Note: `/tmp` and `/var/tmp` are cleaned via a **first-boot systemd oneshot** (`box-firstboot-cleanup.service`).
This avoids breaking Ansible during image build while still delivering a clean box for consumers.

## Molecule

This repo uses **molecule-vagrant** to test the boxes via **Vagrant + libvirt**.

### Generate scenarios

Scenarios are generated from `packer/vars/*.pkrvars.hcl`:

- Scenario name: `<box>-libvirt` (e.g. `ubuntu-24.04-libvirt`)
- Built box package: `./output-<box>/package.box` (added to Vagrant by the scenario's `dependency` step)

Generate/refresh all scenarios:

```bash
make molecule-gen
```

This writes/updates directories under `molecule/` (e.g. `molecule/ubuntu-24.04-libvirt/`).
If you manually edit a generated scenario, rerunning `make molecule-gen` may overwrite it.

### Run scenarios

```bash
molecule test -s ubuntu-24.04-libvirt
molecule converge -s ubuntu-22.04-libvirt
molecule verify -s ubuntu-22.04-libvirt
molecule test -s archlinux-libvirt

# Debug / verbosity
# Note: `-v/--verbose` is a *global* Molecule option (it must come before the subcommand).
molecule --debug -vvv test -s archlinux-libvirt
```

If you see an error like `molecule/.../molecule.yml glob failed`, ensure you're running Molecule from the repo root and re-run `make molecule-gen`.

### Prerequisites / gotchas

- Ensure `vagrant-libvirt` is installed and working on the host.
- If you use `direnv` + `.envrc` to auto-activate a venv, note that **VS Code tasks** and other non-interactive executions may not automatically load it.
  - Quick check: `which molecule` should point into your venv.
  - Reliable option: run Molecule via `direnv exec . molecule …`.
- The generated scenarios converge by importing `ansible/packer.yml` (so roles resolve via the playbook directory without hardcoded `ANSIBLE_ROLES_PATH`).
- If libvirt isn’t your default provider, use:

```bash
VAGRANT_DEFAULT_PROVIDER=libvirt molecule test -s ubuntu-24.04-libvirt
```

- The scenario expects the box file to exist locally (build it first with `make build BOX=<box>`).
- Scenarios add the `.box` into Vagrant by name via `vagrant box add` in the `dependency` step (avoids absolute paths in the repo).
  - Box name: `<namespace>/<box>` (e.g. `example/archlinux`)
    - The namespace is controlled by `VAGRANT_BOX_NAMESPACE` (defaults to `$USER`, or `local` if unset). Set it before both building and generating scenarios to use the same box name.
    - If you previously used `VAGRANT_CLOUD_NAMESPACE`, set `VAGRANT_BOX_NAMESPACE` to that value to keep the same local box names.
  - Box provider: `libvirt` only
  - Box architecture: `amd64` only
  - Box version defaults to the **latest locally installed** version for that box/provider/arch (falls back to `$(date -u +%Y%m%d).0.0` if none exists).
    - Override via `BOX_VERSION=YYYYMMDD.x.y`.
    - Implemented by generating a small Vagrant **metadata JSON** pointing at the local `.box` via `file://…`.

### Verify

Each scenario includes a `verify.yml` that performs a simple smoke test:

- `python3` is present (`command -v python3`)
- `python3` can execute and import basic stdlib modules (`json`, `ssl`)

Run it with:

```bash
molecule verify -s <box>-libvirt
```

## Checksums

Variables default `cloud_image_checksum` to `"none"` for convenience.
For reproducible builds, set a real checksum in `packer/vars/*.pkrvars.hcl`.

## Packer download cache (cloud images)

Many `cloud_image_url` values in `packer/vars/*.pkrvars.hcl` point to moving targets like `current` or `latest`.
Packer caches downloads, so you may otherwise keep using an older image indefinitely.

This repo sets `PACKER_CACHE_DIR` to a repo-local directory by default (`packer_cache/packer`).

To force fresh downloads:

```bash
make cache-clean

# then rebuild
make build BOX=ubuntu-24.04
```

Convenience targets:

- `make cache-refresh BOX=<name>`: clean cache, then rebuild that box
- `make cache-refresh-all`: clean cache, then rebuild all boxes

## Arch Linux

Arch builds use the official qcow2 images published at `geo.mirror.pkgbuild.com/images/latest/`.

### Arch networking (libvirt/Molecule)

If `molecule converge -s archlinux-libvirt` (or `vagrant up --provider=libvirt`) appears to hang at `Waiting for domain to get an IP address...`, the guest likely isn't getting DHCP.

Some cloud images may boot under Vagrant/libvirt without a working network configuration (e.g. cloud-init is disabled or no datasource is detected), resulting in an interface that stays down and never gets an IP.

This repo fixes that during image build (so Molecule/Vagrant can obtain an IP during `create`) by ensuring the baked image has a generic DHCP setup:

- remove/avoid `MACAddress=` pinning in cloud-init-generated networkd files (so NIC matching works when the MAC changes)
- provide a generic `systemd-networkd` DHCP config (`/etc/systemd/network/20-wired-dhcp.network`) for Arch Linux and Debian/Ubuntu
- (Arch Linux only) disable cloud-init networking (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`)

To reduce distro differences during testing, the images standardize interface naming to `eth0`/`eth1`.

- A systemd `.link` override (`/etc/systemd/network/99-ghx-eth0.link`) keeps kernel interface names.
- A small systemd oneshot (`ghx-rename-primary-nic-to-eth0.service`) renames the primary ethernet interface to `eth0` if the guest boots with only `eth1` (seen on some images).

Molecule scenarios also configure a deterministic static IP on the libvirt `private_network`. This avoids DHCP lease churn causing `molecule verify` to appear “stuck” while it tries to SSH to an old IP.

Note: Molecule writes a cached `instance_config.yml` inside its ephemeral directory (often under `.../tmp/molecule.*`). `molecule verify` may reuse that cached IP. If you run commands from inside the ephemeral directory or you reboot and the guest DHCP lease changes, the cached IP can become stale. The simplest fix is to run Molecule from the repo root and `molecule destroy -s <scenario>` (or delete the scenario’s ephemeral directory) and then re-run `molecule converge`.

## Optional image shrinking (host-side)

By default, builds do **not** require extra host dependencies.
If you enable shrinking, the build will:

- Optionally run `virt-sysprep` and `virt-sparsify` (if installed)
- Always run `qemu-img convert -c` to compress the final qcow2

Enable it with:

```bash
SHRINK=safe make build BOX=ubuntu-24.04
```

It also applies to `build-all`:

```bash
SHRINK=full make build-all
```

Strict mode (recommended for CI) fails fast if `libguestfs` tooling is missing:

```bash
SHRINK=full make build BOX=ubuntu-24.04
```

Supported values: `none` (default), `safe`, `full` (aliases: `0` -> `none`, `1` -> `safe`).

Recommended host packages:

- `qemu-img` (often `qemu-utils`)
- `libguestfs-tools` (provides `virt-sysprep`/`virt-sparsify`)
