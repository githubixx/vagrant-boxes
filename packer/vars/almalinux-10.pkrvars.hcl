box_name = "almalinux-10"
cloud_image_url = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
cloud_image_checksum = "none"

# AlmaLinux 10 targets newer x86-64 baselines (x86-64-v2). QEMU's default CPU
# model can be too old and can fail early in boot (glibc x86-64-v2).
qemu_cpu_model = "host"

cpus = 2
memory = 2048
disk_size = "20480M"
