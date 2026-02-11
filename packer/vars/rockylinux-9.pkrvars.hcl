box_name = "rockylinux-9"
cloud_image_url = "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
cloud_image_checksum = "none"

# Rocky 9.7 generic cloud images require a newer CPU feature set than QEMU's
# default virtual CPU provides (x86-64-v1). Use the host CPU model under KVM.
qemu_cpu_model = "host"

cpus = 2
memory = 2048
disk_size = "20480M"
