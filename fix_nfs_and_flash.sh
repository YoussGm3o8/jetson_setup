#!/bin/bash
###############################################################################
# fix_nfs_and_flash.sh
#
# PURPOSE: Fix the NFS export error on live Ubuntu sessions (overlayfs)
#          and flash the Jetson Orin Nano in one go.
#
# PROBLEM: Live Ubuntu uses overlayfs (casper-rw) which does NOT support
#          NFS export. The l4t_initrd_flash.sh tool requires NFS to serve
#          the rootfs to the Jetson during flashing. This causes:
#            exportfs: .../rootfs does not support NFS export
#          And the flash only generates images but never writes them.
#
# SOLUTION: Create an ext4 loopback filesystem on the persistent partition,
#           move the rootfs into it, and re-run the flash. ext4 supports
#           NFS export natively.
#
# USAGE:
#   chmod +x fix_nfs_and_flash.sh
#   sudo ./fix_nfs_and_flash.sh
#
# PREREQUISITES:
#   - Already ran download_and_extract.sh (L4T files are present)
#   - Jetson in Force Recovery Mode (jumper pins 9-10, USB-C connected)
#   - At least 10GB free persistent storage on the SD card
###############################################################################

set -e

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo"
    echo "Usage: sudo ./fix_nfs_and_flash.sh"
    exit 1
fi

echo "=============================================="
echo "  NFS Fix + Jetson Flash Tool"
echo "  Fixes overlayfs NFS export issue"
echo "=============================================="
echo ""

# --- Locate Linux_for_Tegra ---
L4T_DIR=""
SEARCH_PATHS=(
    "$HOME/jetson-flash/jp6-flash-jetson-linux/R36.4.3/Linux_for_Tegra"
    "/home/ubuntu/jetson-flash/jp6-flash-jetson-linux/R36.4.3/Linux_for_Tegra"
    "$(pwd)/R36.4.3/Linux_for_Tegra"
    "$(pwd)/Linux_for_Tegra"
)

for path in "${SEARCH_PATHS[@]}"; do
    if [ -d "$path/rootfs" ] && [ -f "$path/flash.sh" ]; then
        L4T_DIR="$path"
        break
    fi
done

if [ -z "$L4T_DIR" ]; then
    echo "ERROR: Cannot find Linux_for_Tegra directory."
    echo "Searched:"
    for path in "${SEARCH_PATHS[@]}"; do
        echo "  $path"
    done
    echo ""
    read -p "Enter the full path to Linux_for_Tegra: " L4T_DIR
    if [ ! -d "$L4T_DIR/rootfs" ]; then
        echo "ERROR: $L4T_DIR/rootfs does not exist"
        exit 1
    fi
fi

echo "Found L4T at: $L4T_DIR"
echo ""

# --- Check Jetson in Recovery Mode ---
echo "--- Checking for Jetson in Force Recovery Mode ---"
if lsusb | grep -qi "nvidia"; then
    echo "NVIDIA device detected!"
    lsusb | grep -i nvidia
else
    echo "WARNING: No NVIDIA device found on USB."
    echo "Make sure:"
    echo "  1. Jetson is powered off"
    echo "  2. Jumper on pins 9 (FC REC) and 10 (GND)"
    echo "  3. USB-C connected from Jetson to this computer"
    echo "  4. Power on the Jetson"
    echo ""
    read -p "Continue anyway? (y/n): " CONT
    [[ "$CONT" != "y" ]] && exit 1
fi
echo ""

# --- Check if NFS fix is needed ---
echo "--- Checking filesystem type ---"
ROOTFS_FSTYPE=$(df -T "$L4T_DIR/rootfs" 2>/dev/null | awk 'NR==2 {print $2}')
echo "rootfs filesystem type: $ROOTFS_FSTYPE"

if [[ "$ROOTFS_FSTYPE" == "ext4" || "$ROOTFS_FSTYPE" == "ext3" || "$ROOTFS_FSTYPE" == "xfs" ]]; then
    echo "Filesystem supports NFS export. No fix needed."
    NFS_FIX_NEEDED=false
else
    echo "Filesystem ($ROOTFS_FSTYPE) does NOT support NFS export."
    echo "Will create ext4 loopback filesystem to fix this."
    NFS_FIX_NEEDED=true
fi
echo ""

if $NFS_FIX_NEEDED; then
    # --- Calculate rootfs size ---
    echo "--- Calculating rootfs size ---"
    ROOTFS_SIZE_KB=$(du -sk "$L4T_DIR/rootfs" 2>/dev/null | awk '{print $1}')
    ROOTFS_SIZE_MB=$((ROOTFS_SIZE_KB / 1024))
    # Add 30% headroom for ext4 overhead and temp files
    IMG_SIZE_MB=$(( (ROOTFS_SIZE_MB * 130) / 100 ))
    # Minimum 6GB
    if [ "$IMG_SIZE_MB" -lt 6000 ]; then
        IMG_SIZE_MB=6000
    fi
    echo "Rootfs size: ${ROOTFS_SIZE_MB}MB"
    echo "Image size (with headroom): ${IMG_SIZE_MB}MB"

    # --- Check available space ---
    AVAIL_MB=$(df -BM "$L4T_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'M')
    echo "Available space: ${AVAIL_MB}MB"

    if [ "$AVAIL_MB" -lt "$IMG_SIZE_MB" ]; then
        echo ""
        echo "ERROR: Not enough space for ext4 image."
        echo "Need ${IMG_SIZE_MB}MB but only ${AVAIL_MB}MB available."
        echo ""
        echo "Options:"
        echo "  1. Mount an external USB drive and specify its path"
        echo "  2. Free up space on the persistent partition"
        echo ""
        read -p "Enter path for ext4 image (or 'quit'): " IMG_PATH_DIR
        [[ "$IMG_PATH_DIR" == "quit" ]] && exit 1
    else
        IMG_PATH_DIR="$(dirname "$L4T_DIR")"
    fi

    EXT4_IMG="$IMG_PATH_DIR/rootfs_ext4.img"
    echo ""
    echo "Will create ext4 image at: $EXT4_IMG (${IMG_SIZE_MB}MB)"
    read -p "Proceed? (y/n): " PROCEED
    [[ "$PROCEED" != "y" ]] && exit 1

    # --- Create ext4 loopback image ---
    echo ""
    echo "--- Creating ext4 loopback filesystem ---"
    echo "This may take a few minutes..."

    if [ -f "$EXT4_IMG" ]; then
        echo "Image file already exists. Reusing it."
    else
        # Use fallocate (fast) or dd (fallback)
        fallocate -l "${IMG_SIZE_MB}M" "$EXT4_IMG" 2>/dev/null || \
            dd if=/dev/zero of="$EXT4_IMG" bs=1M count="$IMG_SIZE_MB" status=progress
        echo "Formatting as ext4..."
        mkfs.ext4 -F -q "$EXT4_IMG"
    fi

    # --- Mount and copy rootfs ---
    echo ""
    echo "--- Moving rootfs to ext4 filesystem ---"
    echo "This will take several minutes (copying ~${ROOTFS_SIZE_MB}MB)..."

    MOUNT_POINT="$L4T_DIR/rootfs_ext4_mount"
    mkdir -p "$MOUNT_POINT"
    mount -o loop "$EXT4_IMG" "$MOUNT_POINT"

    # Check if rootfs is already on ext4 (re-run case)
    if [ -d "$L4T_DIR/rootfs_original" ]; then
        echo "rootfs_original already exists (previous fix attempt)."
        echo "Copying from rootfs_original to ext4 mount..."
        cp -a "$L4T_DIR/rootfs_original/." "$MOUNT_POINT/"
    else
        echo "Backing up original rootfs directory name..."
        mv "$L4T_DIR/rootfs" "$L4T_DIR/rootfs_original"
        echo "Copying rootfs to ext4 filesystem..."
        cp -a "$L4T_DIR/rootfs_original/." "$MOUNT_POINT/"
    fi

    # Unmount from temp location
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"

    # Mount ext4 image as the actual rootfs directory
    mkdir -p "$L4T_DIR/rootfs"
    mount -o loop "$EXT4_IMG" "$L4T_DIR/rootfs"

    echo "rootfs is now on ext4 loopback filesystem."
    echo ""

    # Verify NFS export works
    echo "--- Verifying NFS export support ---"
    exportfs -o rw,nohide,insecure,no_subtree_check,async,no_root_squash \
        127.0.0.1:"$L4T_DIR/rootfs" 2>/dev/null && {
        echo "NFS export test PASSED!"
        exportfs -u 127.0.0.1:"$L4T_DIR/rootfs" 2>/dev/null
    } || {
        echo "WARNING: NFS export test failed. Proceeding anyway..."
    }
    echo ""
fi

# --- Clean old flash artifacts ---
echo "--- Cleaning previous flash artifacts ---"
rm -rf "$L4T_DIR/tools/kernel_flash/images" 2>/dev/null
rm -rf "$L4T_DIR/bootloader/signed" 2>/dev/null
rm -f "$L4T_DIR/bootloader/flashcmd.txt" 2>/dev/null
rm -f "$L4T_DIR/tools/kernel_flash/initrdflashparam.txt" 2>/dev/null
echo "Cleaned."

# --- Restart NFS services ---
echo ""
echo "--- Restarting NFS services ---"
killall rpcbind 2>/dev/null || true
sleep 1
systemctl restart rpcbind 2>/dev/null || rpcbind 2>/dev/null || true
systemctl restart nfs-kernel-server 2>/dev/null || true
echo "NFS services restarted."

# --- Disable USB autosuspend ---
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true

# --- Flash the Jetson ---
echo ""
echo "=============================================="
echo "  Ready to flash!"
echo "=============================================="
echo ""
echo "Board: jetson-orin-nano-devkit"
echo "Target: NVMe (nvme0n1p1)"
echo "Method: initrd flash over USB network"
echo ""
echo "This will take 20-30 minutes. DO NOT unplug anything!"
echo ""
read -p "Start flashing now? (y/n): " FLASH
[[ "$FLASH" != "y" ]] && { echo "Aborted."; exit 0; }

cd "$L4T_DIR"

echo ""
echo "========== FLASHING STARTED =========="
echo ""

./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs \
    --network usb0 \
    jetson-orin-nano-devkit internal

FLASH_EXIT=$?

echo ""
if [ $FLASH_EXIT -eq 0 ]; then
    echo "=============================================="
    echo "  FLASH SUCCESSFUL!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Power off the Jetson"
    echo "  2. REMOVE the recovery jumper from pins 9-10"
    echo "  3. Connect monitor, keyboard, mouse, ethernet"
    echo "  4. Power on - Ubuntu first-boot setup will appear"
    echo "  5. After setup, run on the Jetson:"
    echo "     git clone https://github.com/YoussGm3o8/jetson_setup.git"
    echo "     cd jetson_setup && chmod +x *.sh"
    echo "     ./02_jetson_post_flash_setup.sh"
else
    echo "=============================================="
    echo "  FLASH FAILED (exit code: $FLASH_EXIT)"
    echo "=============================================="
    echo ""
    echo "Check the output above for errors."
    echo "Common issues:"
    echo "  - USB cable disconnected or loose"
    echo "  - Jetson fell out of recovery mode"
    echo "  - Insufficient disk space for image generation"
fi

# --- Cleanup ext4 mount if used ---
if $NFS_FIX_NEEDED && mountpoint -q "$L4T_DIR/rootfs" 2>/dev/null; then
    echo ""
    echo "Note: ext4 rootfs is still mounted at $L4T_DIR/rootfs"
    echo "It will be automatically unmounted when you reboot."
fi
