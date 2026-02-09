#!/bin/bash
###############################################################################
# 01_host_flash_jetson.sh
#
# PURPOSE: Run this script on a BARE-METAL Ubuntu 22.04 (or 20.04) x86 host
#          to flash JetPack 6.2 (L4T R36.4.3) to a Jetson Orin Nano 8GB
#          Developer Kit via NVMe SSD.
#
# PREREQUISITES:
#   - x86 Ubuntu host (bare metal, NOT WSL/VM)
#   - Jetson Orin Nano 8GB in Force Recovery Mode
#   - USB-C data cable connecting Jetson to host
#   - NVMe SSD installed in Jetson
#   - Internet connection on host
#
# USAGE:
#   chmod +x 01_host_flash_jetson.sh
#   ./01_host_flash_jetson.sh
#
# This script will:
#   1. Install prerequisites (git, wget, etc.)
#   2. Clone the JetsonHacks JP6 flash repo
#   3. Download L4T R36.4.3 BSP and rootfs (~15GB total)
#   4. Extract and prepare the flash environment
#   5. Flash the Jetson (QSPI firmware + NVMe rootfs)
#
# Total time: ~30-45 minutes depending on internet speed
###############################################################################

set -e

echo "=============================================="
echo "  Jetson Orin Nano 8GB - JetPack 6.2 Flasher"
echo "  L4T R36.4.3 | NVMe SSD Boot"
echo "=============================================="
echo ""

# --- Safety Checks ---

# Must not run on ARM
if [ "$(arch)" == "aarch64" ]; then
    echo "ERROR: This script must run on an x86_64 host, not ARM/aarch64."
    exit 1
fi

# Must be on Ubuntu
if ! command -v lsb_release &> /dev/null; then
    echo "ERROR: This script requires Ubuntu. lsb_release not found."
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs)
echo "Detected Ubuntu version: $UBUNTU_VERSION"

if [[ "$UBUNTU_VERSION" != "20.04" && "$UBUNTU_VERSION" != "22.04" ]]; then
    echo "WARNING: Ubuntu $UBUNTU_VERSION is not officially supported."
    echo "         Recommended: 22.04 or 20.04"
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        exit 1
    fi
fi

# Check for Jetson in recovery mode
echo ""
echo "--- Step 0: Checking for Jetson in Force Recovery Mode ---"
echo ""
echo "Make sure your Jetson Orin Nano is in Force Recovery Mode:"
echo "  1. Power off the Jetson (disconnect power cable)"
echo "  2. Place a jumper across pins 9 (FC REC) and 10 (GND) on the button header"
echo "     (OR select 'Boot into Recovery' from UEFI BIOS menu)"
echo "  3. Connect USB-C cable from Jetson to this host"
echo "  4. Reconnect power to the Jetson"
echo ""
read -p "Press ENTER when the Jetson is in Force Recovery Mode..."

# Check if NVIDIA device is visible
if lsusb | grep -qi "nvidia"; then
    echo "✓ NVIDIA device detected on USB!"
    lsusb | grep -i nvidia
else
    echo "WARNING: No NVIDIA device detected on USB."
    echo "The Jetson may not be in Force Recovery Mode."
    echo ""
    echo "Troubleshooting:"
    echo "  - Try a different USB-C cable (must be data-capable)"
    echo "  - Try a different USB port on the host"
    echo "  - Try running: sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'"
    echo "  - Verify the jumper is on the correct pins"
    echo ""
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        exit 1
    fi
fi

# --- Step 1: Install Prerequisites ---
echo ""
echo "--- Step 1: Installing prerequisites ---"
echo "This will install: git, wget, python3, qemu-user-static, etc."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    exit 1
fi

sudo apt-get update
sudo apt-get install -y git wget python3 python3-pip qemu-user-static \
    device-tree-compiler libxml2-utils sshpass abootimg nfs-kernel-server \
    openssh-server binutils cpio udev lz4 lbzip2

# --- Step 2: Clone JP6 Flash Scripts ---
echo ""
echo "--- Step 2: Cloning JetsonHacks JP6 flash scripts ---"
echo ""

WORK_DIR="$HOME/jetson-flash"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ -d "jp6-flash-jetson-linux" ]; then
    echo "jp6-flash-jetson-linux already exists, pulling latest..."
    cd jp6-flash-jetson-linux
    git pull
    cd ..
else
    git clone https://github.com/jetsonhacks/jp6-flash-jetson-linux.git
fi

cd jp6-flash-jetson-linux

# --- Step 3: Download & Extract L4T Files ---
echo ""
echo "--- Step 3: Downloading L4T R36.4.3 BSP and Root Filesystem ---"
echo "This will download ~15GB total. Make sure you have enough disk space (~40GB free needed)."
echo ""

# Check available disk space
AVAIL_GB=$(df -BG "$WORK_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
echo "Available disk space: ${AVAIL_GB}GB"
if [ "$AVAIL_GB" -lt 40 ]; then
    echo "WARNING: Less than 40GB available. You may run out of space."
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        exit 1
    fi
fi

read -p "Proceed with download? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    exit 1
fi

bash ./download_and_extract.sh

# --- Step 4: Flash the Jetson ---
echo ""
echo "--- Step 4: Flashing the Jetson ---"
echo ""
echo "IMPORTANT: The Jetson must still be in Force Recovery Mode."
echo "This will flash QSPI firmware and the NVMe SSD."
echo "The process takes ~20-30 minutes."
echo ""
echo "When prompted, select option 1: Jetson Orin Nano Developer Kit (NVMe)"
echo ""
read -p "Ready to flash? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    exit 1
fi

bash ./flash_jetson.sh R36.4.3

echo ""
echo "=============================================="
echo "  Flashing Complete!"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Power off the Jetson"
echo "  2. REMOVE the recovery jumper from pins 9-10"
echo "  3. Connect monitor, keyboard, mouse, and ethernet to the Jetson"
echo "  4. Power on the Jetson"
echo "  5. Complete the Ubuntu OEM first-boot setup"
echo "  6. Once logged in, run 02_jetson_post_flash_setup.sh on the Jetson"
echo ""
