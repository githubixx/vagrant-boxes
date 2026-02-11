box_name = "opensuse-leap-15.6"
cloud_image_url = "https://download.opensuse.org/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-kvm-and-xen.qcow2"
cloud_image_checksum = "none"

cpus = 2
memory = 2048
disk_size = "30720M"

# If JeOS Firstboot appears on the console, press Start once.
boot_wait    = "8s"
boot_command = ["<enter>"]

# Connect as root during build; minimal images may not ship sudo by default.
ssh_username = "root"
ssh_password = "vagrant"

# Ansible on the controller may require Python >= 3.7 on the guest.
# The shell provisioner bootstraps a suitable interpreter and symlinks it here.
ansible_python_interpreter = "/usr/local/bin/ansible-python"
