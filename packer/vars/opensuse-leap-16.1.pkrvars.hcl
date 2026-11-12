box_name = "opensuse-leap-16.1"

cloud_image_url      = "https://download.opensuse.org/distribution/leap/16.1/appliances/Leap-16.1-Minimal-VM.x86_64-kvm-and-xen.qcow2"
cloud_image_checksum = "none"

cloud_init_user_data_file = "packer/cloud-init/opensuse-leap-16.0/user-data"

cpus      = 2
memory    = 2048
disk_size = "30720M"

disk_interface = "virtio"
net_device     = "virtio-net"

qemu_machine_type = "q35"
qemu_cpu_model    = "host"

ssh_username               = "root"
ssh_password               = "vagrant"
ansible_python_interpreter = "/usr/local/bin/ansible-python"

boot_wait    = "8s"
boot_command = ["<enter>"]
