box_name = "almalinux-9"
cloud_image_url = "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
cloud_image_checksum = "none"

# AlmaLinux 9 GenericCloud images require x86-64-v2 CPU features; QEMU's default
# `qemu64` model may be too old and can trigger: "Fatal glibc error: CPU does not
# support x86-64-v2" early in boot.
qemu_cpu_model = "host"

cpus = 2
memory = 2048
disk_size = "20480M"
