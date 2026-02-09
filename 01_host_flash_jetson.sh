#!/bin/bash
###############################################################################
# 01_host_flash_jetson.sh
#
# PURPOSE: Run this script on a BARE-METAL Ubuntu 22.04 (or 20.04) x86 host
#          to flash JetPack 6.2 (L4T R36.4.3) to a Jetson Orin Nano 8GB
#          Developer Kit via NVMe SSD.
#
# WORKS WITH: Live Ubuntu sessions (persistent recommended), bare-metal installs
#
# PREREQUISITES:
#   - x86 Ubuntu host (bare metal or live USB with persistence, NOT WSL/VM)
#   - Jetson Orin Nano 8GB with NVMe SSD installed
#   - USB-C data cable connecting Jetson to host
#   - Internet connection on host
#   - At least 40GB free writable disk space
#
# FOR LIVE USB SESSIONS:
#   Re-flash your USB/SD card with Rufus and set the "Persistent partition
#   size" slider to at least 50GB. This ensures files go to disk, not RAM.
#   Without persistence, 8GB RAM laptops will crash during the 15GB+ download.
#
# USAGE:
#   chmod +x 01_host_flash_jetson.sh
#   ./01_host_flash_jetson.sh
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

# Check Ubuntu
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
    [[ "$CONTINUE" != "y" ]] && exit 1
fi

# --- Check available storage ---
echo ""
echo "--- Checking available storage ---"

# Determine best working directory
WORK_DIR=""
check_space() {
    local dir=$1
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        local avail=$(df -BG "$dir" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
        echo "$avail"
    else
        echo "0"
    fi
}

# Priority: home dir > /tmp > external mount
HOME_SPACE=$(check_space "$HOME")
TMP_SPACE=$(check_space "/tmp")

echo "Home directory space: ${HOME_SPACE}GB"
echo "/tmp space: ${TMP_SPACE}GB"

if [ "$HOME_SPACE" -ge 40 ]; then
    WORK_DIR="$HOME/jetson-flash"
    echo "Using home directory for working space."
elif [ "$TMP_SPACE" -ge 40 ]; then
    WORK_DIR="/tmp/jetson-flash"
    echo "Using /tmp for working space."
else
    echo ""
    echo "WARNING: Not enough writable disk space found (need ~40GB)."
    echo ""
    echo "If running from a live USB/SD, you likely need PERSISTENT storage."
    echo "Solutions:"
    echo "  1. Re-flash your USB/SD with Rufus and set 'Persistent partition' to 50GB+"
    echo "  2. Mount an external USB drive:"
    echo "     sudo mkdir -p /mnt/external"
    echo "     sudo mount /dev/sdX1 /mnt/external  (replace sdX1 with your drive)"
    echo "  3. Mount a non-encrypted internal partition"
    echo ""
    echo "If you have mounted external storage, enter the path now."
    read -p "Working directory path (or 'quit'): " CUSTOM_DIR
    if [[ "$CUSTOM_DIR" == "quit" ]]; then
        exit 1
    fi
    WORK_DIR="$CUSTOM_DIR/jetson-flash"

    # Verify the custom directory is writable
    mkdir -p "$WORK_DIR" 2>/dev/null || {
        echo "ERROR: Cannot create directory at $WORK_DIR"
        echo "Make sure the path is writable."
        exit 1
    }
    CUSTOM_SPACE=$(check_space "$WORK_DIR")
    if [ "$CUSTOM_SPACE" -lt 40 ]; then
        echo "WARNING: Only ${CUSTOM_SPACE}GB available at $WORK_DIR."
        read -p "Continue anyway? (y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    fi
fi

echo "Working directory: $WORK_DIR"
mkdir -p "$WORK_DIR"

# --- Step 1: Enable repositories and install prerequisites ---
echo ""
echo "--- Step 1: Installing prerequisites ---"
echo "This will enable universe/multiverse repos and install required packages."
echo ""
read -p "Proceed? (y/n): " PROCEED
[[ "$PROCEED" != "y" ]] && exit 1

# Enable universe and multiverse repositories (needed for live sessions)
sudo add-apt-repository -y universe 2>/dev/null || true
sudo add-apt-repository -y multiverse 2>/dev/null || true
sudo apt-get update

# Install all prerequisites - try as group first, fall back to individual
sudo apt-get install -y \
    git wget curl python3 python3-pip \
    qemu-user-static \
    device-tree-compiler \
    libxml2-utils \
    sshpass \
    abootimg \
    nfs-kernel-server \
    openssh-server \
    binutils \
    cpio \
    udev \
    lz4 \
    lbzip2 \
    bzip2 \
    xxd \
    libfdt-dev \
    2>/dev/null || {
        echo ""
        echo "Bulk install had issues. Installing individually..."
        # Critical packages
        for pkg in git wget curl python3 device-tree-compiler libxml2-utils \
                   binutils cpio udev lz4 bzip2 openssh-server; do
            sudo apt-get install -y "$pkg" 2>/dev/null || echo "  WARN: $pkg failed"
        done
        # Optional packages - try but don't fail
        for pkg in python3-pip qemu-user-static sshpass abootimg nfs-kernel-server \
                   lbzip2 xxd libfdt-dev; do
            sudo apt-get install -y "$pkg" 2>/dev/null || echo "  Note: $pkg not available (may not be critical)"
        done
    }

echo "Prerequisites installed"

# --- Step 2: Get JP6 Flash Scripts ---
echo ""
echo "--- Step 2: Getting JetPack 6 flash scripts ---"
echo ""

cd "$WORK_DIR"

if [ -d "jp6-flash-jetson-linux" ]; then
    echo "jp6-flash-jetson-linux already exists."
    read -p "Re-download? (y/n): " REDOWNLOAD
    if [[ "$REDOWNLOAD" == "y" ]]; then
        rm -rf jp6-flash-jetson-linux
    fi
fi

if [ ! -d "jp6-flash-jetson-linux" ]; then
    echo "Downloading JP6 flash scripts..."
    # Try git clone first, fall back to wget zip
    if command -v git &> /dev/null; then
        timeout 30 git clone https://github.com/jetsonhacks/jp6-flash-jetson-linux.git 2>/dev/null || {
            echo "git clone failed or timed out. Downloading ZIP instead..."
            wget -q --show-progress "https://github.com/jetsonhacks/jp6-flash-jetson-linux/archive/refs/heads/main.zip" -O jp6.zip
            unzip -q jp6.zip
            mv jp6-flash-jetson-linux-main jp6-flash-jetson-linux
            rm jp6.zip
        }
    else
        echo "git not available. Downloading ZIP..."
        wget -q --show-progress "https://github.com/jetsonhacks/jp6-flash-jetson-linux/archive/refs/heads/main.zip" -O jp6.zip
        unzip -q jp6.zip
        mv jp6-flash-jetson-linux-main jp6-flash-jetson-linux
        rm jp6.zip
    fi
fi

cd jp6-flash-jetson-linux

# --- Step 3: Setup Environment & Download L4T ---
echo ""
echo "--- Step 3: Setting up environment and downloading L4T R36.4.3 ---"
echo "This downloads ~15GB (BSP + Root Filesystem)."
echo ""

# Check if already downloaded
if [ -d "R36.4.3/Linux_for_Tegra" ]; then
    echo "L4T R36.4.3 already downloaded and extracted."
    read -p "Re-download? (y/n): " REDOWNLOAD
    if [[ "$REDOWNLOAD" != "y" ]]; then
        echo "Skipping download, using existing files."
    else
        rm -rf R36.4.3
        echo ""
        echo "=== BOARD SELECTION ==="
        echo "Select option 1: jetson-orin-nano-devkit"
        echo ""
        bash ./setup_jetson_env.sh
        bash ./download_and_extract.sh
    fi
else
    read -p "Proceed with ~15GB download? (y/n): " PROCEED
    [[ "$PROCEED" != "y" ]] && exit 1

    echo ""
    echo "=== BOARD SELECTION ==="
    echo "Select option 1: jetson-orin-nano-devkit"
    echo ""
    bash ./setup_jetson_env.sh

    echo ""
    echo "Downloading BSP and Root Filesystem (~15GB total)..."
    echo "This may take 15-30 minutes depending on your internet speed."
    echo ""
    bash ./download_and_extract.sh
fi

echo "L4T R36.4.3 ready"

# --- Step 4: Check for Jetson in Recovery Mode ---
echo ""
echo "--- Step 4: Verify Jetson is in Force Recovery Mode ---"
echo ""
echo "Make sure your Jetson Orin Nano is in Force Recovery Mode:"
echo "  1. New NVMe SSD installed in M.2 slot"
echo "  2. Power off (disconnect power cable)"
echo "  3. Jumper pins 9 (FC REC) and 10 (GND) on button header"
echo "     (or use 'Boot into Recovery' from UEFI BIOS menu)"
echo "  4. USB-C cable from Jetson to this host"
echo "  5. Reconnect power"
echo ""
read -p "Press ENTER when Jetson is in Force Recovery Mode..."

# Disable USB autosuspend (helps with flashing reliability)
sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend' 2>/dev/null || true

# Check USB
if lsusb | grep -qi "nvidia"; then
    echo "NVIDIA device detected on USB!"
    lsusb | grep -i nvidia
else
    echo "WARNING: No NVIDIA device detected on USB."
    echo ""
    echo "Troubleshooting:"
    echo "  - Try a different USB-C cable (must be data-capable)"
    echo "  - Try a different USB port"
    echo "  - Verify jumper is on correct pins (9 and 10)"
    echo "  - Try flipping the USB-C connector 180 degrees"
    echo ""
    read -p "Continue anyway? (y/n): " CONTINUE
    [[ "$CONTINUE" != "y" ]] && exit 1
fi

# --- Step 5: Flash the Jetson ---
echo ""
echo "--- Step 5: Flashing the Jetson ---"
echo ""
echo "IMPORTANT:"
echo "  - Select option 1: Jetson Orin Nano Developer Kit (NVMe)"
echo "  - DO NOT unplug anything during flashing!"
echo "  - Process takes ~20-30 minutes"
echo ""
read -p "Ready to flash? (y/n): " PROCEED
[[ "$PROCEED" != "y" ]] && exit 1

bash ./flash_jetson.sh R36.4.3

echo ""
echo "=============================================="
echo "  Flashing Complete!"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo "  1. Power off the Jetson"
echo "  2. REMOVE the recovery jumper from pins 9-10"
echo "  3. Connect monitor, keyboard, mouse, ethernet to Jetson"
echo "  4. Power on the Jetson"
echo "  5. Complete Ubuntu OEM first-boot setup (create user, etc.)"
echo "  6. Once logged in on the Jetson, run:"
echo "     git clone https://github.com/YoussGm3o8/jetson_setup.git"
echo "     cd jetson_setup"
echo "     chmod +x 02_jetson_post_flash_setup.sh"
echo "     ./02_jetson_post_flash_setup.sh"
echo ""
