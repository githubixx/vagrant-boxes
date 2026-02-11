packer {
  required_version = ">= 1.9.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.0"
    }
    vagrant = {
      source  = "github.com/hashicorp/vagrant"
      version = ">= 1.0.0"
    }
  }
}

locals {
  # This template lives under packer/templates/, so the repository root is two levels up.
  repo_root = abspath("${path.root}/../..")

  cloud_init_user_data = fileexists("${local.repo_root}/packer/cloud-init/${var.box_name}/user-data") ? "${local.repo_root}/packer/cloud-init/${var.box_name}/user-data" : "${local.repo_root}/packer/cloud-init/common/user-data"
}

variable "box_name" {
  type = string
}

variable "cloud_image_url" {
  type = string
}

variable "cloud_image_checksum" {
  type    = string
  default = "none"
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 2048
}

variable "disk_size" {
  type    = string
  default = "20480M"
}

variable "disk_interface" {
  type    = string
  default = "virtio"
}

variable "net_device" {
  type    = string
  default = "virtio-net"
}

variable "boot_wait" {
  type        = string
  default     = "0s"
  description = "Optional boot wait before sending boot_command (e.g. 5s)."
}

variable "boot_command" {
  type        = list(string)
  default     = []
  description = "Optional boot command sequence (e.g. ['<enter>'])."
}

variable "qemu_cpu_model" {
  type        = string
  default     = "qemu64"
  description = "QEMU CPU model (e.g. qemu64, host)."
}

variable "qemu_machine_type" {
  type        = string
  default     = "pc"
  description = "QEMU machine type (e.g. pc, q35)."
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type    = string
  default = "vagrant"
}

variable "ssh_private_key_file" {
  type        = string
  default     = ""
  description = "Optional path to an SSH private key used by the communicator. If empty, password auth is used."
}

variable "ansible_python_interpreter" {
  type        = string
  default     = "/usr/bin/python3"
  description = "Python interpreter path used by Ansible on the guest."
}

variable "shrink_enable" {
  type    = bool
  default = false
}

variable "shrink_mode" {
  type        = string
  default     = "safe"
  description = "Shrink mode when shrink_enable=true: safe|full"
}

source "qemu" "libvirt" {
  accelerator    = "kvm"
  headless       = true
  disk_image     = true
  iso_url        = var.cloud_image_url
  iso_checksum   = var.cloud_image_checksum
  format         = "qcow2"
  disk_size      = var.disk_size
  disk_interface = var.disk_interface
  net_device     = var.net_device

  boot_wait    = var.boot_wait
  boot_command = var.boot_command

  cd_label = "cidata"
  cd_files = [
    local.cloud_init_user_data,
    "${local.repo_root}/packer/cloud-init/common/meta-data",
  ]

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_private_key_file = var.ssh_private_key_file != "" ? var.ssh_private_key_file : null
  ssh_timeout  = "30m"

  qemuargs = [
    ["-cpu", var.qemu_cpu_model],
    ["-machine", "type=${var.qemu_machine_type},accel=kvm"],
    ["-serial", "file:${local.repo_root}/packer/logs/${var.box_name}.serial.log"],
    ["-device", "virtio-serial"],
    [
      "-chardev",
      "socket,id=qga0,path=${local.repo_root}/output-${var.box_name}/qemu/qga.sock,server=on,wait=off",
    ],
    [
      "-device",
      "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
    ],
  ]

  shutdown_command = var.ssh_username == "root" ? "shutdown -h now" : "sudo shutdown -h now"

  vm_name          = var.box_name
  output_directory = "${local.repo_root}/output-${var.box_name}/qemu"
  cpus             = var.cpus
  memory           = var.memory
}

build {
  name    = var.box_name
  sources = ["source.qemu.libvirt"]

  provisioner "shell" {
    inline = [
      "set -eu",
      "SUDO='' ; if [ \"$(id -u)\" != '0' ]; then SUDO='sudo'; fi",
      "if command -v cloud-init >/dev/null 2>&1; then (command -v timeout >/dev/null 2>&1 && $SUDO timeout 600 cloud-init status --wait) || $SUDO cloud-init status --wait || true; fi",
      "# openSUSE Leap 15.6 may ship an older /usr/bin/python3 (<3.7) which newer Ansible can't run on.",
      "if [ -r /etc/os-release ] && grep -qiE 'suse|opensuse' /etc/os-release; then target=/usr/local/bin/ansible-python; pick_py=''; for cand in /usr/bin/python3.13 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python3; do if [ -x \"$cand\" ] && \"$cand\" -c \"import sys; raise SystemExit(0 if sys.version_info >= (3,7) else 1)\" >/dev/null 2>&1; then pick_py=\"$cand\"; break; fi; done; if [ -z \"$pick_py\" ] && command -v zypper >/dev/null 2>&1; then $SUDO zypper -n refresh >/dev/null 2>&1 || true; $SUDO zypper -n install -y python311 python311-base >/dev/null 2>&1 || $SUDO zypper -n install -y python310 python310-base >/dev/null 2>&1 || true; for cand in /usr/bin/python3.13 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python3; do if [ -x \"$cand\" ] && \"$cand\" -c \"import sys; raise SystemExit(0 if sys.version_info >= (3,7) else 1)\" >/dev/null 2>&1; then pick_py=\"$cand\"; break; fi; done; fi; if [ -n \"$pick_py\" ]; then $SUDO mkdir -p /usr/local/bin; $SUDO ln -sf \"$pick_py\" \"$target\"; $SUDO chmod 0755 \"$target\" || true; fi; fi",
    ]
  }

  provisioner "ansible" {
    playbook_file = "${local.repo_root}/ansible/packer.yml"
    user          = var.ssh_username
    extra_arguments = [
      "-e", "ansible_python_interpreter=${var.ansible_python_interpreter}",
    ]
  }

  post-processor "shell-local" {
    environment_vars = [
      "SHRINK_ENABLE=${var.shrink_enable}",
      "SHRINK_MODE=${var.shrink_mode}",
      "PACKER_OUTPUT_DIR=${local.repo_root}/output-${var.box_name}/qemu",
      "BOX_NAME=${var.box_name}",
    ]
    inline = [
      "set -euo pipefail",
      "${local.repo_root}/scripts/shrink-image.sh",
    ]
  }

  post-processor "vagrant" {
    output              = "${local.repo_root}/output-${var.box_name}/package.box"
    keep_input_artifact = true
    provider_override   = "libvirt"
  }
}
