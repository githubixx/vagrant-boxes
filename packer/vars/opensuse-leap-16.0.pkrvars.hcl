box_name = "opensuse-leap-16.0"

# Leap 16 publishes several "Minimal-VM" images. We use the kvm-and-xen variant.
cloud_image_url      = "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-kvm-and-xen.qcow2"
cloud_image_checksum = "none"

cpus   = 2
memory = 2048

# The Minimal-VM kvm-and-xen qcow2 has a 24GiB virtual size; Packer/qemu cannot shrink it.
disk_size = "30720M"

disk_interface = "virtio"
net_device     = "virtio-net"

# Leap 16.0 installer appears to require a newer virtual platform than i440fx/PIIX.
# Use q35 + host CPU model (KVM) to expose modern CPU features.
qemu_machine_type = "q35"
qemu_cpu_model    = "host"

# Connect as root during build; Leap Minimal-VM may not ship sudo by default.
ssh_username = "root"
ssh_password = "vagrant"

# Ansible on the controller may require Python >= 3.7 on the guest.
ansible_python_interpreter = "/usr/local/bin/ansible-python"

# If JeOS Firstboot still appears on the console, press Start once.
boot_wait    = "8s"
boot_command = ["<enter>"]
