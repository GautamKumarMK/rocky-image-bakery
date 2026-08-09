packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ─────────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────────

variable "source_image" {
  type        = string
  description = "Path or URL to the Rocky 10 GenericCloud qcow2 base image."
  default     = "Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "source_checksum" {
  type        = string
  description = "sha256:<hash> for source_image. Use 'none' only in dev."
  default     = "none"
}

variable "output_dir" {
  type    = string
  description = "Scratch build directory. Treat as EPHEMERAL — safe to delete between Packer runs. The final artifact is published to libvirt_image_dir, not left here."
  default = "output-golden"
}

variable "libvirt_image_dir" {
  type        = string
  description = "Stable publish location for the final optimized image, used as the backing file for CoW instance overlays. Defaults to libvirt's standard image store, which sits inside libvirt's default AppArmor trust boundary on Debian/Ubuntu hosts — no manual profile edits needed to let qemu read it."
  default     = "/var/lib/libvirt/images"
}

variable "vm_name_prefix" {
  type    = string
  default = "rocky10-golden"
}

variable "disk_size" {
  type        = number
  description = "Disk size in MB. Packer resizes source qcow2 to this; cloud-init growpart fills the partition."
  default     = 20480 # 20 GB
}

variable "memory" {
  type    = number
  default = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

variable "build_user" {
  type        = string
  description = "Ephemeral SSH user for the Packer communicator. Removed in shutdown_command."
  default     = "packer"
}

variable "build_private_key_file" {
  type        = string
  description = "Path to the private key matching the public key embedded in nocloud/user-data. Injected by build.sh."
}

variable "loki_host" {
  type        = string
  description = "Hostname/IP of the Loki instance. Replaces __LOKI_HOST__ in fluent-bit.conf at build time."
  default     = "loki.lab.local"
}

# ─────────────────────────────────────────────────────────────────
# Locals
# ─────────────────────────────────────────────────────────────────

locals {
  # Strips hyphens, spaces, colons, and the 'Z' from the UTC timestamp
  # Result: "20260729223045"
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
  image_name = "${var.vm_name_prefix}-${local.timestamp}.qcow2"
  # Name as it exists after the compression step, and as it will be
  # published under libvirt_image_dir.
  optimized_name = "optimized-${local.image_name}"
}

# ─────────────────────────────────────────────────────────────────
# Source
# ─────────────────────────────────────────────────────────────────

source "qemu" "rocky10_golden" {
  # ── Base image ────────────────────────────────────────────────
  iso_url      = var.source_image
  iso_checksum = var.source_checksum
  disk_image   = true # source is a bootable qcow2, not an ISO

  # ── Output ────────────────────────────────────────────────────
  format           = "qcow2"
  disk_interface   = "virtio"
  output_directory = var.output_dir
  vm_name          = local.image_name
  # Packer resizes the copied source image to disk_size MB.
  # cloud-init growpart + resize_rootfs in nocloud/user-data.tpl
  # fills the partition on first boot so provisioners don't run out
  # of space.
  # NOTE: output image retains a backing-file chain to source_image.
  # Flatten before distributing:
  #   qemu-img convert -O qcow2 -c output-golden/rocky10-golden.qcow2 flat.qcow2
  disk_size = var.disk_size

  # ── VM resources ──────────────────────────────────────────────
  memory      = var.memory
  cpus        = var.cpus
  accelerator = "kvm"
  headless    = true
  net_device  = "virtio-net"

  # ── Cloud-init NoCloud seed ────────────────────────────────────
  # Only creates the ephemeral build user + expands the root fs.
  # build.sh (envsubst) renders user-data.tpl → user-data before
  # this runs, embedding the build public key.
  cd_files = [
    "${path.root}/nocloud/meta-data",
    "${path.root}/nocloud/user-data",
  ]
  cd_label = "cidata"

  # ── SSH communicator ───────────────────────────────────────────
  communicator         = "ssh"
  ssh_username         = var.build_user
  ssh_private_key_file = var.build_private_key_file
  ssh_timeout          = "10m"

  # ── Boot ──────────────────────────────────────────────────────
  # GenericCloud images boot directly; no boot_command needed.
  # 20 s gives QEMU time to start before we begin polling SSH.

  boot_command = [
    "<up><wait><tab><wait>",
    " inst.text inst.ks=cdrom:/ks.cfg ",
    " console=ttyS0 ",                  
    "<enter><wait>"
  ]

  boot_wait = "20s"

  qemuargs = [
    ["-machine", "type=q35,accel=kvm"],
    ["-serial", "file:serial-boot.log"],
    ["-cpu", "host"], # <-- Ties the image build to hardware compatible with host cpu -->
  ]

  # ── Shutdown ───────────────────────────────────────────────────
  # 1. Reset cloud-init state so per-instance user-data runs fresh
  #    on every VM cloned from this image.
  # 2. Remove the ephemeral build user (fails-fast if already gone).
  # 3. Power off.
  shutdown_command = join(" ; ", [
      "sudo cloud-init clean --logs",
      "sudo rm -f /etc/ssh/ssh_host_*",                                  # Scrub SSH host keys
      "sudo truncate -s 0 /etc/machine-id",                              # Clear machine-id (systemd will regenerate)
      "sudo dnf clean all",                                              # Save disk space
      "sudo rm -f /etc/NetworkManager/system-connections/*.nmconnection",
      "sudo passwd -l packer",                                           # Lock the provisioner account password
      "sudo usermod -s /sbin/nologin packer",                            # Prevent shell access for the provisioner account
      "rm -f ~/.ssh/authorized_keys ~/.bash_history",                    # Scrub SSH keys and bash history
      "history -c",                                                      # Clear current session history
      "sudo shutdown -P now"
  ])
  
  shutdown_timeout = "5m"
}

# ─────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────

build {
  name    = "rocky10-golden"
  sources = ["source.qemu.rocky10_golden"]

  provisioner "file" {
    source      = "${path.root}/files/check-cloud-init.py"
    destination = "/tmp/check-cloud-init.py"
  }

  # ── 0: Wait for build-time cloud-init ─────────────────────────
  # The NoCloud seed only creates the build user; block until it
  # finishes so the system is stable before provisioners touch it.
  provisioner "shell" {
    inline = [
      "until cloud-init status 2>/dev/null | grep -qE 'status: (done|error|degraded)'; do sleep 2; done",
      "python3 /tmp/check-cloud-init.py",
    ]
  }
  # ── 1: System update ──────────────────────────────────────────
  # Always reboot after update so the running kernel matches the
  # installed packages. expect_disconnect tells Packer to wait for
  # SSH to reconnect instead of treating the drop as a failure.
  provisioner "shell" {
    inline            = ["sudo dnf -y update && sudo reboot"]
    expect_disconnect = true
    timeout           = "20m"
  }

  provisioner "shell" {
    inline       = ["echo 'back after post-update reboot'"]
    pause_before = "30s" # let the VM settle before next step
  }

  # ── 2: Repos ──────────────────────────────────────────────────
  # Upload the Fluent Bit repo file before enabling EPEL so dnf
  # makecache can pull all three at once.
  provisioner "file" {
    source      = "${path.root}/files/fluent-bit.repo"
    destination = "/tmp/fluent-bit.repo"
  }

  provisioner "shell" {
    inline = [
      "sudo dnf install -y dnf-plugins-core",
      "sudo dnf config-manager --set-enabled crb",
      "sudo dnf install -y epel-release",
      "sudo rpm --import https://packages.fluentbit.io/fluentbit.key",
      "sudo install -m 644 /tmp/fluent-bit.repo /etc/yum.repos.d/fluent-bit.repo",
      "sudo dnf makecache --assumeyes",
    ]
  }

  # ── 3: Packages ───────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo dnf install -y qemu-guest-agent tcpdump numactl sysstat iperf3 firewalld ipset fluent-bit cloud-utils-growpart",
      # fail2ban and python3-systemd live in EPEL, which is now enabled.
      "sudo dnf install -y fail2ban python3-systemd",
      "rpm -qi fluent-bit || echo 'fluent-bit not installed'",
      # FIX: Defensively assert the user exists before modifying
      "sudo getent passwd fluent-bit || sudo useradd --system --no-create-home --shell /sbin/nologin fluent-bit",
      "sudo usermod -aG systemd-journal fluent-bit"
    ]
    timeout = "15m"
  }

  # ── 4: Config files ───────────────────────────────────────────
  # Upload all static config files in one provisioner, then move
  # them into place with sudo.
  provisioner "file" {
    sources = [
      "${path.root}/files/sshd-hardening.conf",
      "${path.root}/files/ssh-banner.txt",
      "${path.root}/files/sysctl-hardening.conf",
      "${path.root}/files/fail2ban-jail.local",
      "${path.root}/files/fluent-bit.conf",
      "${path.root}/files/goss.yaml",
      "${path.root}/files/pwquality.conf",
      "${path.root}/files/faillock.conf",
      "${path.root}/files/limits-hardening.conf",
    ]
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 644 /tmp/sshd-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf",
      "sudo install -m 644 /tmp/ssh-banner.txt       /etc/ssh/banner.txt",
      "sudo install -m 644 /tmp/sysctl-hardening.conf /etc/sysctl.d/99-hardening.conf",
      "sudo install -m 644 /tmp/fail2ban-jail.local  /etc/fail2ban/jail.local",
      # Prepare the buffer directory for Fluent Bit
      "sudo mkdir -p /var/log/fluent-bit/buffers",
      # Substitute Loki host placeholder before the file goes into place.
      # instance=unset is intentional: per-instance cloud-init patches it.
      "sudo sed -i 's|__LOKI_HOST__|${var.loki_host}|g' /tmp/fluent-bit.conf",
      "sudo install -m 644 /tmp/fluent-bit.conf      /etc/fluent-bit/fluent-bit.conf",
      "sudo install -m 644 /tmp/pwquality.conf       /etc/security/pwquality.conf",
      "sudo install -m 644 /tmp/faillock.conf         /etc/security/faillock.conf",
      "sudo install -m 644 /tmp/limits-hardening.conf /etc/security/limits.d/99-hardening.conf",
      # Enable faillock and pwhistory in the PAM stack via authselect.
      "sudo authselect select sssd with-faillock with-pwhistory --force",
      # --- SELinux Context Restoration ---
      "echo 'Restoring SELinux file contexts...'",
      "sudo restorecon -Rv /etc/ssh /etc/sysctl.d /etc/fail2ban /etc/fluent-bit /var/log/fluent-bit /etc/security /etc/security/limits.d"
    ]
  }

  # ── 5: Services, firewall, sysctl ─────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl enable --now firewalld",
      "sudo systemctl enable --now fail2ban",
      "sudo systemctl enable --now chronyd",
      # Validate new sshd drop-in, then reload (reload != restart;
      # existing Packer SSH session survives).
      "sudo sshd -t",
      "sudo systemctl reload sshd",
      "sudo firewall-cmd --permanent --add-service=ssh",
      "sudo firewall-cmd --reload",
      "sudo firewall-cmd --query-service=ssh",
      "sudo sysctl --system",
      "sudo fail2ban-client status sshd",
      "sudo fail2ban-client get sshd bantime"
      # fluent-bit is intentionally NOT started here.
      # Its config still has instance=unset; per-instance cloud-init
      # patches that label and starts the service on first clone boot.
    ]
  }

  # ── 6: Formal Validation Gate (Goss) ──────────────────────────
  provisioner "shell" {
    inline = [
      "echo 'Downloading Goss for validation...'",
      "curl -sL https://github.com/goss-org/goss/releases/download/v0.4.10/goss_0.4.10_linux_x86_64.tar.gz -o /tmp/goss.tar.gz",
      
      "echo 'Verifying SHA256 checksum...'",
      "echo '26e365428946294bcec0c61d867bb3c8349f39feb3d0e6f59084e98632785cc7  /tmp/goss.tar.gz' | sha256sum -c -",
      
      "echo 'Extracting and setting permissions...'",
      "tar -xzf /tmp/goss.tar.gz -C /tmp goss",
      "chmod +rx /tmp/goss",
      
      "echo 'Running Goss validation suite...'",
      "sudo /tmp/goss -g /tmp/goss.yaml validate --format documentation",
      
      "echo 'Cleaning up validation artifacts...'",
      "rm -f /tmp/goss /tmp/goss.tar.gz /tmp/goss.yaml"
    ]
  }

  # We combine the optimization and checksum generation into a single 
  # step to ensure the hash matches the final compressed artifact.
  post-processor "shell-local" {
    inline = [
      "echo 'Compressing QCOW2 image...'",
      "qemu-img convert -p -O qcow2 -c ${var.output_dir}/${local.image_name} ${var.output_dir}/optimized-${local.image_name}",
      
      "echo 'Generating SHA256 checksum for optimized image...'",
      "cd ${var.output_dir} && sha256sum optimized-${local.image_name} > optimized-${local.image_name}.sha256; cd ..",
      
      "echo 'Cleaning up unoptimized original...'",
      "rm -f ${var.output_dir}/${local.image_name}",

      "echo 'Publishing golden image to ${var.libvirt_image_dir} (stable path, survives output_dir cleanup)...'",
      "sudo mkdir -p ${var.libvirt_image_dir}",
      "sudo mv ${var.output_dir}/${local.optimized_name} ${var.libvirt_image_dir}/${local.optimized_name}",
      "sudo mv ${var.output_dir}/${local.optimized_name}.sha256 ${var.libvirt_image_dir}/${local.optimized_name}.sha256",
      
      # world-readable is enough for qemu to open it as a backing file —
      # no need to guess/chown to a specific qemu process user, and the
      # host is Ubuntu (AppArmor) so no restorecon is needed here.
      "sudo chmod 644 ${var.libvirt_image_dir}/${local.optimized_name}",
      "sudo chmod 644 ${var.libvirt_image_dir}/${local.optimized_name}.sha256",

      "echo 'Updating rocky10-golden-latest.qcow2 symlink atomically...'",
      "sudo ln -sfn ${var.libvirt_image_dir}/${local.optimized_name} ${var.libvirt_image_dir}/rocky10-golden-latest.qcow2.tmp",
      "sudo mv -T ${var.libvirt_image_dir}/rocky10-golden-latest.qcow2.tmp ${var.libvirt_image_dir}/rocky10-golden-latest.qcow2",

      "echo 'Published: ${var.libvirt_image_dir}/rocky10-golden-latest.qcow2 -> ${local.optimized_name}'",
      "echo 'NOTE: previous timestamped images in ${var.libvirt_image_dir} are left in place — do not delete one that a running instance overlay still depends on. Check with: qemu-img info <instance>.qcow2 | grep backing'"
    ]
  }
}