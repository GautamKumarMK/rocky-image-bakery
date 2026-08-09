#!/bin/bash
set -euo pipefail

echo "Starting SRE Lab Provisioning..."

# ── Config ────────────────────────────────────────────────────────────
# Packer's post-processor now publishes the final image here and keeps
# this symlink pointed at the latest build — independent of
# output-golden/, which is safe to delete when rerunning Packer.
GOLDEN_IMAGE="/var/lib/libvirt/images/rocky10-golden-latest.qcow2"

export VM_HOSTNAME="${VM_HOSTNAME:-sre-compute-node}"
export VM_FQDN="${VM_FQDN:-node.lab.local}"
export USER_NAME="${USER_NAME:-gautam}"
export TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
export MY_PUBLIC_KEY
MY_PUBLIC_KEY=$(cat ~/.ssh/server_keys.pub)

SEED_DIR="$(pwd)/instance-seed"
DISK_DIR="/home/gautam/virtual_machines/instances"
INSTANCE_DISK="${DISK_DIR}/${VM_HOSTNAME}.qcow2"

mkdir -p "${SEED_DIR}" "${DISK_DIR}"

# Fail fast with a clear message if a domain with this name is already
# defined in libvirt — covers the case where the instance disk was
# deleted by hand but the domain was never `virsh undefine`'d. Without
# this check, virt-install would still fail later, just with a less
# obvious error at the very end of the script.
if virsh dominfo "${VM_HOSTNAME}" >/dev/null 2>&1; then
  echo "Domain '${VM_HOSTNAME}' is already defined in libvirt. Run 'virsh undefine ${VM_HOSTNAME}' (add --remove-all-storage if you also want its disk deleted) before re-provisioning under this name, or choose a different VM_HOSTNAME." >&2
  exit 1
fi


# ── 1. Render user-data from template ───────────────────────────────
echo "Generating cloud-init user-data..."
# shell variables in the template are NOT expanded here.
# SC2016 is intentional: envsubst expects a literal variable list.
# shellcheck disable=SC2016
envsubst '${VM_HOSTNAME} ${VM_FQDN} ${USER_NAME} ${MY_PUBLIC_KEY} ${TIMEZONE}' \
  < instance-seed/cloud-init-compute.yaml.tpl \
  > "${SEED_DIR}/cloud-init-compute.yaml"

# ── 2. Generate a fresh meta-data with a unique instance-id ─────────
# cloud-init's NoCloud datasource caches "have I already run for this
# instance-id" under /var/lib/cloud/instances/<id>/. Reusing a static
# meta-data file across clones means the SECOND clone silently skips
# user-data entirely (no user, no fluent-bit patch, no health gate).
cat > "${SEED_DIR}/meta-data" <<EOF
instance-id: ${VM_HOSTNAME}-$(date +%s)
local-hostname: ${VM_HOSTNAME}
EOF

# SELinux label fix — uncomment if your host is Rocky/RHEL (not needed on Ubuntu)
# sudo chcon -t virt_image_t /dev/vm-storage/sre-node-data

# ── 3. Create a copy-on-write overlay instead of booting the golden
# image directly. QEMU opens the backing file (golden image)
# READ-ONLY through this path — guest writes land only in the
# overlay, so the golden qcow2 is never modified no matter what the
# instance does to its own disk. Requires the backing path
# (GOLDEN_IMAGE, here a stable symlink) to keep existing/resolving
# for the life of every VM built from it — don't delete or move it
# out from under running instances.
if [ -f "${INSTANCE_DISK}" ]; then
  echo "Disk ${INSTANCE_DISK} already exists — refusing to overwrite. Remove it first if intentional." >&2
  exit 1
fi
echo "Creating CoW overlay disk for ${VM_HOSTNAME}..."
RESOLVED_GOLDEN="$(readlink -f "${GOLDEN_IMAGE}")"
qemu-img create -f qcow2 -F qcow2 -b "${RESOLVED_GOLDEN}" "${INSTANCE_DISK}"

# ── 4. Provision the instance ───────────────────────────────────────
echo "Provisioning ${VM_HOSTNAME} (CoW overlay on golden image, golden untouched)..."
virt-install \
  --name "${VM_HOSTNAME}" \
  --memory 4096 \
  --vcpus 4 \
  --disk path="${INSTANCE_DISK}",format=qcow2,cache=none \
  --osinfo rocky10 \
  --network default \
  --cloud-init "user-data=${SEED_DIR}/cloud-init-compute.yaml,meta-data=${SEED_DIR}/meta-data" \
  --noautoconsole

echo "Provisioning complete. Check IPs with: virsh net-dhcp-leases default"