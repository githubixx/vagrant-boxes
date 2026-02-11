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
  repo_root = abspath("${path.root}/../../..")
  http_dir  = "${local.repo_root}/packer/http/${var.box_name}"
}

variable "box_name" {
  type = string
}

variable "iso_url" {
  type = string
}

variable "iso_checksum" {
  type = string
}

variable "install_repo_url" {
  type        = string
  description = "Installation source repo URL (required for network installer ISOs)."
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

variable "shrink_enable" {
  type    = bool
  default = false
}

variable "shrink_mode" {
  type        = string
  default     = "safe"
  description = "Shrink mode when shrink_enable=true: safe|full"
}

source "qemu" "opensuse_iso" {
  accelerator    = "kvm"
  headless       = true
  disk_size      = var.disk_size
  disk_interface = var.disk_interface
  net_device     = var.net_device
  format         = "qcow2"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Serve AutoYaST profile over HTTP.
  http_directory = local.http_dir

  # Agama/openSUSE installers typically boot via GRUB2. This sequence:
  # - stops the timeout, edits the default entry, appends kernel params,
  # - then boots the edited entry.
  boot_wait = "10s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><down><down><down><down><down><down><down>",
    "<end>",
    " autoyast=http://{{ .HTTPIP }}:{{ .HTTPPort }}/autoyast.xml",
    " install=${var.install_repo_url}",
    " language=en_US",
    " console=ttyS0,115200n8",
    "<f10><wait>"
  ]

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "90m"

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

  shutdown_command = "sudo shutdown -h now"

  vm_name          = var.box_name
  output_directory = "${local.repo_root}/output-${var.box_name}/qemu"
  cpus             = var.cpus
  memory           = var.memory
}

build {
  name    = var.box_name
  sources = ["source.qemu.opensuse_iso"]

  provisioner "ansible" {
    playbook_file = "${local.repo_root}/ansible/packer.yml"
    user          = var.ssh_username
    extra_arguments = [
      "-e", "ansible_python_interpreter=/usr/bin/python3",
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
