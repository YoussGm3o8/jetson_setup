# Jetson Orin Nano 8GB - JetPack 6.2 Flash & Setup

Flash JetPack 6.2 (L4T R36.4.3) to a Jetson Orin Nano 8GB Developer Kit with NVMe SSD boot.

## What You Need

- **Host**: x86 laptop/PC booted into Ubuntu 22.04 (live USB/SD works)
- **Jetson**: Orin Nano 8GB Developer Kit
- **SSD**: NVMe PCIe M.2 2280 (128GB+ recommended, 256GB+ ideal)
- **Cable**: USB-C data cable (not charge-only)
- **Jumper**: For Force Recovery Mode pins (or use UEFI BIOS menu)
- **Peripherals**: Monitor, keyboard, mouse, ethernet for Jetson

## Step-by-Step Instructions

### On the Host (Ubuntu x86 laptop):

```bash
# 1. Install prerequisites
sudo apt-get update
sudo apt-get install -y git wget python3 qemu-user-static device-tree-compiler \
    libxml2-utils sshpass abootimg nfs-kernel-server openssh-server \
    binutils cpio udev lz4 lbzip2

# 2. Clone this repo
git clone https://github.com/YoussGm3o8/jetson-orin-nano-setup.git
cd jetson-orin-nano-setup

# 3. Clone JP6 flash tools, download BSP + rootfs (~15GB)
git clone https://github.com/jetsonhacks/jp6-flash-jetson-linux.git
cd jp6-flash-jetson-linux
bash ./setup_jetson_env.sh        # Select: 1) jetson-orin-nano-devkit
bash ./download_and_extract.sh    # Downloads ~15GB, takes a while

# 4. Put Jetson in Force Recovery Mode:
#    - Power off Jetson (disconnect power)
#    - Jumper pins 9 (FC REC) and 10 (GND) on button header
#    - Connect USB-C from Jetson to host laptop
#    - Reconnect power to Jetson
#    Verify: lsusb | grep -i nvidia  (should show NVIDIA device)

# 5. Flash the Jetson
bash ./flash_jetson.sh R36.4.3
# Select option 1: Jetson Orin Nano Developer Kit (NVMe)
# Wait ~20-30 minutes
```

### On the Jetson (after flash):

```bash
# 1. Remove recovery jumper, connect peripherals + ethernet, power on
# 2. Complete Ubuntu OEM first-boot setup
# 3. Open terminal and run:

# Clone this repo on the Jetson
git clone https://github.com/YoussGm3o8/jetson-orin-nano-setup.git
cd jetson-orin-nano-setup

# Run the post-flash setup script
chmod +x 02_jetson_post_flash_setup.sh
./02_jetson_post_flash_setup.sh
```

## What Gets Installed (Post-Flash)

| Component | Version | Notes |
|-----------|---------|-------|
| JetPack | 6.2 | Full suite: CUDA, cuDNN, TensorRT, VPI |
| Docker | Latest | With NVIDIA Container Toolkit |
| ROS 2 | Humble | Ubuntu 22.04 compatible |
| Isaac ROS | 3.2 | Latest for JetPack 6.2 + Orin Nano |
| ZED SDK | 4.2 | For L4T 36.x (JetPack 6) |
| ZED ROS 2 | Latest | Wrapper built in Isaac ROS workspace |
| jtop | Latest | Jetson system monitor |

## Isaac ROS Note

**Isaac ROS 4.x does NOT support Orin Nano** (only Jetson Thor + JetPack 7.0).
Use **Isaac ROS 3.2** (release-3.2) which supports JetPack 6.2 on Orin Nano.

## Troubleshooting

### WSL/VM won't work for flashing
The Jetson USB device re-enumerates during flashing, breaking WSL/VM USB passthrough.
Use bare-metal Ubuntu (live USB/SD card boot works fine).

### Flash fails with "Unsupported device"
Try: `sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'`
Also try a different USB cable or USB port.

### NVMe SSD not detected in UEFI
- Check PCI devices: `pci` command in UEFI shell
- If no NVMe controller in PCI list, SSD hardware is dead
- Reseat the SSD, try a different SSD

### Power budget
Orin Nano Dev Kit provides 36W total. The SoC uses ~15W. Keep SSD power draw under 8-10W.
Gen 3 NVMe drives (e.g., WD Blue SN570) draw less power than Gen 4 drives.
