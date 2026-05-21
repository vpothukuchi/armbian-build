#!/bin/bash
# ti-first-boot-resize.sh — Safe first-boot rootfs expansion
#
# Uses parted + partx + resize2fs.  Deliberately avoids fdisk (which
# rewrites the MBR disk signature, invalidating all PARTUUIDs) and
# partprobe (which issues BLKRRPART and can deadlock on a busy root).
#
# partx -u uses BLKPG_RESIZE_PARTITION ioctl — updates only the kernel's
# in-memory view of the affected partition; safe on a mounted root.

set -euo pipefail

FLAG=/var/lib/ti-first-boot-resize-done

[[ -f "$FLAG" ]] && exit 0

log() { echo "[ti-resize] $*"; }

ROOT_DEV=$(findmnt -n -o SOURCE /)
DISK_KNAME=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null)
PART_NUM=$(lsblk -no partn  "$ROOT_DEV" 2>/dev/null)
DISK="/dev/$DISK_KNAME"

if [[ -z "$DISK_KNAME" || -z "$PART_NUM" ]]; then
    log "Cannot determine parent disk for $ROOT_DEV — skipping"
    touch "$FLAG"
    exit 0
fi

# Check if the partition already fills the disk (within 2048 sectors / 1 MiB)
DISK_SECTORS=$(blockdev --getsz "$DISK")          # 512-byte sectors
PART_END_S=$(parted -sm "$DISK" unit s print \
    | awk -F: -v p="$PART_NUM" '$1==p{gsub("s","",$3); print $3}')

if [[ -n "$PART_END_S" && "$PART_END_S" -ge $((DISK_SECTORS - 2048)) ]]; then
    log "$ROOT_DEV already at end of $DISK — nothing to do"
    touch "$FLAG"
    exit 0
fi

log "Expanding $ROOT_DEV on $DISK (partition $PART_NUM)..."

# 1. Resize the partition table entry (no MBR signature change)
parted -s "$DISK" resizepart "$PART_NUM" 100%

# 2. Tell the kernel about the new partition boundary (BLKPG ioctl, not BLKRRPART)
partx -u --nr "$PART_NUM" "$DISK" || partx -u "$DISK" || true
udevadm settle --timeout=5 || true

# 3. Grow the live ext4 filesystem to fill the enlarged partition
resize2fs "$ROOT_DEV"

touch "$FLAG"
log "Done — $(df -h "$ROOT_DEV" | awk 'NR==2{print $2 " total, " $4 " free"}')"
