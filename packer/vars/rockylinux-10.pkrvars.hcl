box_name = "rockylinux-10"
cloud_image_url = "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
cloud_image_checksum = "none"

# Rocky Linux 10 cloud images may require a newer CPU feature set than QEMU's
# default virtual CPU provides. Use the host CPU model under KVM.
qemu_cpu_model = "host"

cpus = 2
memory = 2048
disk_size = "20480M"
