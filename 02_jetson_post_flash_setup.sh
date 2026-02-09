#!/bin/bash
###############################################################################
# 02_jetson_post_flash_setup.sh
#
# PURPOSE: Run this ON THE JETSON after first boot (OEM setup complete).
#          Installs everything needed for the NOMAD project:
#          - JetPack 6.2 components (CUDA, cuDNN, TensorRT)
#          - Docker + NVIDIA Container Toolkit
#          - ZED SDK 4.2
#          - Tailscale VPN
#          - MAVLink Router
#          - NOMAD repository + Python environment
#          - Docker images (Isaac ROS)
#          - Firewall rules
#          - Systemd service
#
# PREREQUISITES:
#   - Jetson Orin Nano 8GB freshly flashed with JetPack 6.2 (L4T R36.4.3)
#   - OEM first-boot completed (user: mad, hostname: ubuntu)
#   - Internet connection (ethernet recommended)
#   - Cube Orange flight controller plugged in (optional, for MAVLink)
#   - ZED 2i camera plugged in (optional, for verification)
#
# USAGE:
#   chmod +x 02_jetson_post_flash_setup.sh
#   ./02_jetson_post_flash_setup.sh
#
# ESTIMATED TIME: ~60-90 minutes (mostly downloads/builds)
###############################################################################

set -e

echo "=============================================="
echo "  NOMAD - Jetson Orin Nano 8GB Setup"
echo "  JetPack 6.2 | Docker | Isaac ROS | ZED"
echo "=============================================="
echo ""

# --- Safety Check ---
if [ "$(arch)" != "aarch64" ]; then
    echo "ERROR: This script must run ON the Jetson (aarch64), not an x86 host."
    exit 1
fi

# Get the current user
CURRENT_USER=$(whoami)
echo "Running as user: $CURRENT_USER"
echo ""

# Track what gets installed for summary
INSTALLED=()
SKIPPED=()
FAILED=()

###############################################################################
# STEP 1: System Update
###############################################################################
echo "=== Step 1/12: System Update ==="
read -p "Update and upgrade system packages? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get autoremove -y
    INSTALLED+=("System Update")
else
    SKIPPED+=("System Update")
fi

###############################################################################
# STEP 2: Install JetPack 6.2
###############################################################################
echo ""
echo "=== Step 2/12: Install JetPack 6.2 ==="
echo "Installs: CUDA, cuDNN, TensorRT, VPI, Multimedia API"
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    sudo apt-get install -y nvidia-jetpack || {
        echo "WARNING: nvidia-jetpack install had issues. Trying components..."
        sudo apt-get install -y cuda-toolkit-12-6 libcudnn9 libnvinfer-dev \
            libnvinfer-plugin-dev vpi3-dev 2>/dev/null || true
    }

    # Add CUDA to PATH
    if ! echo "$PATH" | grep -q "/usr/local/cuda/bin"; then
        echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
    fi
    INSTALLED+=("JetPack 6.2")
else
    SKIPPED+=("JetPack 6.2")
fi

###############################################################################
# STEP 3: Install System Dependencies
###############################################################################
echo ""
echo "=== Step 3/12: System Dependencies ==="
echo "git, curl, wget, python3, pip, ffmpeg, ufw, libusb, etc."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    sudo apt-get install -y \
        git curl wget \
        python3 python3-pip python3-venv \
        libusb-1.0-0-dev \
        ffmpeg ufw \
        htop tmux nano vim tree net-tools \
        mavlink-router || {
            # mavlink-router may not be in default repos
            echo "Note: mavlink-router not in repos, will install separately if needed."
            sudo apt-get install -y \
                git curl wget python3 python3-pip python3-venv \
                libusb-1.0-0-dev ffmpeg ufw htop tmux nano vim tree net-tools
        }
    INSTALLED+=("System Dependencies")
else
    SKIPPED+=("System Dependencies")
fi

###############################################################################
# STEP 4: Install Docker + NVIDIA Container Toolkit
###############################################################################
echo ""
echo "=== Step 4/12: Docker + NVIDIA Container Toolkit ==="
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    # Install Docker
    if command -v docker &> /dev/null; then
        echo "Docker already installed: $(docker --version)"
    else
        # Try apt first (JetPack may include it)
        sudo apt-get install -y docker.io docker-compose 2>/dev/null || {
            # Install from Docker official repo
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        }
    fi

    # Add user to docker group
    sudo usermod -aG docker $CURRENT_USER

    # Install NVIDIA Container Toolkit
    if dpkg -l | grep -q nvidia-container-toolkit; then
        echo "NVIDIA Container Toolkit already installed."
    else
        sudo apt-get install -y nvidia-container-toolkit 2>/dev/null || {
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
                sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
            sudo apt-get update
            sudo apt-get install -y nvidia-container-toolkit
        }
    fi

    # Configure Docker with NVIDIA runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    # Set NVIDIA as default runtime
    if [ -f /etc/docker/daemon.json ]; then
        if ! grep -q '"default-runtime"' /etc/docker/daemon.json; then
            sudo python3 -c "
import json
with open('/etc/docker/daemon.json', 'r') as f:
    config = json.load(f)
config['default-runtime'] = 'nvidia'
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(config, f, indent=4)
"
            sudo systemctl restart docker
        fi
    fi

    INSTALLED+=("Docker + NVIDIA Container Toolkit")
else
    SKIPPED+=("Docker")
fi

###############################################################################
# STEP 5: Install ZED SDK 4.2
###############################################################################
echo ""
echo "=== Step 5/12: ZED SDK 4.2 ==="
echo "For ZED 2i camera support on L4T 36.4"
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    if [ -f /usr/local/zed/lib/libsl_zed.so ]; then
        echo "ZED SDK already installed."
    else
        echo "Downloading ZED SDK 4.2 for JetPack 6..."
        cd ~
        wget -q --show-progress "https://download.stereolabs.com/zedsdk/4.2/l4t36.4/jetsons" -O zed_sdk.run || {
            echo "Download failed. You may need to download manually from:"
            echo "https://www.stereolabs.com/developers/release"
            FAILED+=("ZED SDK")
        }
        if [ -f zed_sdk.run ]; then
            chmod +x zed_sdk.run
            echo "Running ZED SDK installer (silent mode, skipping object detection module)..."
            ./zed_sdk.run -- silent skip_od_module
            rm -f zed_sdk.run
            echo "Verifying ZED SDK..."
            ls -la /usr/local/zed/lib/libsl_zed.so && echo "ZED SDK installed successfully" || echo "ZED SDK verification failed"
        fi
    fi
    INSTALLED+=("ZED SDK 4.2")
else
    SKIPPED+=("ZED SDK")
fi

###############################################################################
# STEP 6: Install Tailscale
###############################################################################
echo ""
echo "=== Step 6/12: Tailscale VPN ==="
echo "For remote access to the Jetson over Tailscale network."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    if command -v tailscale &> /dev/null; then
        echo "Tailscale already installed."
    else
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    echo ""
    echo "Starting Tailscale..."
    sudo tailscale up --hostname=ubuntu
    echo ""
    echo "Tailscale IP:"
    tailscale ip -4 || echo "Authenticate in browser first"
    INSTALLED+=("Tailscale")
else
    SKIPPED+=("Tailscale")
fi

###############################################################################
# STEP 7: Clone NOMAD Repository
###############################################################################
echo ""
echo "=== Step 7/12: Clone NOMAD Repository ==="
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    cd ~
    if [ -d "NOMAD" ]; then
        echo "NOMAD repo already exists. Pulling latest..."
        cd NOMAD && git pull && cd ~
    else
        git clone https://github.com/YoussGm3o8/NOMAD.git
    fi
    INSTALLED+=("NOMAD Repository")
else
    SKIPPED+=("NOMAD Repository")
fi

###############################################################################
# STEP 8: Setup Python Environment
###############################################################################
echo ""
echo "=== Step 8/12: Python Virtual Environment ==="
echo "Creates venv and installs NOMAD Python dependencies."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    cd ~/NOMAD
    if [ -d "venv" ]; then
        echo "Venv already exists."
        read -p "Recreate it? (y/n): " RECREATE
        if [[ "$RECREATE" == "y" ]]; then
            rm -rf venv
            python3 -m venv venv
        fi
    else
        python3 -m venv venv
    fi

    source venv/bin/activate
    pip install --upgrade pip

    # Install requirements
    if [ -f "edge_core/requirements-jetson.txt" ]; then
        echo "Installing from edge_core/requirements-jetson.txt..."
        pip install -r edge_core/requirements-jetson.txt
    else
        echo "requirements-jetson.txt not found. Installing key packages manually..."
        pip install \
            fastapi==0.115.0 \
            "uvicorn[standard]==0.32.0" \
            pydantic==2.10.0 \
            pydantic-settings==2.6.0 \
            pymavlink==2.4.42 \
            pyzmq==26.2.0 \
            opencv-python==4.10.0.84 \
            psutil==6.1.0 \
            httpx==0.28.0 \
            python-dotenv==1.0.1 \
            pytest==8.3.0 \
            pytest-asyncio==0.24.0
        # PyTorch and Ultralytics - use Jetson-optimized builds if available
        pip install ultralytics==8.3.0 || echo "Note: ultralytics may need manual install"
    fi

    deactivate
    INSTALLED+=("Python Environment")
else
    SKIPPED+=("Python Environment")
fi

###############################################################################
# STEP 9: Configure MAVLink Router
###############################################################################
echo ""
echo "=== Step 9/12: MAVLink Router ==="
echo "Routes MAVLink from Cube Orange to Edge Core, Vision, and Ground Station."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    # Install mavlink-router if not already
    if ! command -v mavlink-routerd &> /dev/null; then
        echo "Installing mavlink-router from source..."
        sudo apt-get install -y git meson ninja-build pkg-config gcc g++ systemd
        cd /tmp
        git clone https://github.com/mavlink-router/mavlink-router.git 2>/dev/null || true
        cd mavlink-router
        git submodule update --init --recursive
        meson setup build .
        ninja -C build
        sudo ninja -C build install
        cd ~
    fi

    # Configure
    sudo mkdir -p /etc/mavlink-router
    if [ -f ~/NOMAD/transport/mavlink_router/main.conf ]; then
        sudo cp ~/NOMAD/transport/mavlink_router/main.conf /etc/mavlink-router/
        echo "Copied NOMAD MAVLink router config."
    else
        echo "Creating default MAVLink router config..."
        sudo tee /etc/mavlink-router/main.conf > /dev/null <<'MAVEOF'
[General]
TcpServerPort = 5760

[UartEndpoint cube]
Device = /dev/ttyACM0
Baud = 921600

[UdpEndpoint edge_core]
Mode = Normal
Address = 127.0.0.1
Port = 14550

[UdpEndpoint vision]
Mode = Normal
Address = 127.0.0.1
Port = 14551

[UdpEndpoint gcs]
Mode = Normal
Address = 100.76.127.17
Port = 14550
MAVEOF
    fi

    sudo systemctl enable mavlink-router 2>/dev/null || true
    INSTALLED+=("MAVLink Router")
else
    SKIPPED+=("MAVLink Router")
fi

###############################################################################
# STEP 10: Configure Environment
###############################################################################
echo ""
echo "=== Step 10/12: Environment Configuration ==="
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    cd ~/NOMAD
    if [ -f config/env/jetson.env ] && [ ! -f .env ]; then
        cp config/env/jetson.env .env
        echo "Copied jetson.env to .env"
    elif [ -f .env ]; then
        echo ".env already exists."
    else
        echo "No jetson.env found. Creating default .env..."
        cat > .env <<'ENVEOF'
# NOMAD Environment Configuration
TAILSCALE_IP=100.75.218.89
GCS_IP=100.76.127.17
HOSTNAME=ubuntu
USERNAME=mad

# Edge Core
EDGE_CORE_PORT=8000
MAVLINK_PORT=14550
VISION_PORT=14551

# Video
RTSP_PORT=8554
MEDIAMTX_API_PORT=9997

# ZED
ZED_CAMERA_MODEL=zed2i
ENVEOF
    fi
    INSTALLED+=("Environment Config")
else
    SKIPPED+=("Environment Config")
fi

###############################################################################
# STEP 11: Configure Firewall
###############################################################################
echo ""
echo "=== Step 11/12: Firewall (UFW) ==="
echo "Allows Tailscale subnet + local network access."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    # Tailscale subnet rules
    sudo ufw allow from 100.0.0.0/8 to any port 22 proto tcp
    sudo ufw allow from 100.0.0.0/8 to any port 8000 proto tcp
    sudo ufw allow from 100.0.0.0/8 to any port 8554 proto tcp
    sudo ufw allow from 100.0.0.0/8 to any port 14550 proto udp

    # Local network rules
    sudo ufw allow from 192.168.0.0/16 to any port 22 proto tcp
    sudo ufw allow from 192.168.0.0/16 to any port 8000 proto tcp

    # Enable firewall
    echo "y" | sudo ufw enable
    sudo ufw status
    INSTALLED+=("Firewall")
else
    SKIPPED+=("Firewall")
fi

###############################################################################
# STEP 12: Build Docker Images
###############################################################################
echo ""
echo "=== Step 12/12: Build Docker Images ==="
echo "Builds Isaac ROS + NOMAD Docker images."
echo "Base image: nvcr.io/nvidia/isaac/ros:humble-ros2_humble-20240402.1-l4t"
echo "This will take 30-60 minutes and download several GB."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    cd ~/NOMAD

    # Need to be in docker group - check
    if ! groups | grep -q docker; then
        echo "WARNING: User not in docker group yet. Running with sudo..."
        echo "After this script, log out and back in for docker group to take effect."
        DOCKER_CMD="sudo docker"
        COMPOSE_CMD="sudo docker compose"
    else
        DOCKER_CMD="docker"
        COMPOSE_CMD="docker compose"
    fi

    # Pull base image first
    echo "Pulling Isaac ROS base image (this is large, ~10GB+)..."
    $DOCKER_CMD pull nvcr.io/nvidia/isaac/ros:humble-ros2_humble-20240402.1-l4t || {
        echo "WARNING: Failed to pull base image. Docker compose build may handle it."
    }

    # Build
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "compose.yaml" ]; then
        echo "Building NOMAD Docker images..."
        $COMPOSE_CMD build isaac-ros || echo "WARNING: isaac-ros build failed"
        $COMPOSE_CMD build jetson-video-stream 2>/dev/null || echo "Note: jetson-video-stream build skipped or failed"
        INSTALLED+=("Docker Images")
    else
        echo "No docker-compose file found. Skipping Docker build."
        echo "You may need to build manually after cloning NOMAD."
        SKIPPED+=("Docker Images")
    fi
else
    SKIPPED+=("Docker Images")
fi

###############################################################################
# Install jtop (Jetson stats monitor)
###############################################################################
echo ""
echo "--- Installing jtop (Jetson system monitor) ---"
sudo pip3 install -U jetson-stats 2>/dev/null || \
    sudo pip3 install -U jetson-stats --break-system-packages 2>/dev/null || \
    echo "Note: jtop install failed, install manually later"

# Add user to dialout group (for Cube Orange serial access)
sudo usermod -aG dialout $CURRENT_USER

###############################################################################
# OPTIONAL: Install Systemd Service
###############################################################################
echo ""
read -p "Install NOMAD systemd service (auto-start on boot)? (y/n): " PROCEED
if [[ "$PROCEED" == "y" ]]; then
    if [ -f ~/NOMAD/infra/nomad.service ]; then
        sudo cp ~/NOMAD/infra/nomad.service /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable nomad
        echo "NOMAD service installed and enabled."
        INSTALLED+=("Systemd Service")
    else
        echo "nomad.service not found in ~/NOMAD/infra/. Skipping."
        SKIPPED+=("Systemd Service")
    fi
else
    SKIPPED+=("Systemd Service")
fi

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo "=============================================="
echo "  NOMAD Setup Complete!"
echo "=============================================="
echo ""
echo "INSTALLED:"
for item in "${INSTALLED[@]}"; do
    echo "  + $item"
done
echo ""
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo "SKIPPED:"
    for item in "${SKIPPED[@]}"; do
        echo "  - $item"
    done
    echo ""
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILED:"
    for item in "${FAILED[@]}"; do
        echo "  ! $item"
    done
    echo ""
fi

echo "=============================================="
echo "  IMPORTANT: Reboot to apply all changes"
echo "  sudo reboot"
echo "=============================================="
echo ""
echo "After reboot, verify:"
echo "  jtop                          # Jetson system monitor"
echo "  nvcc --version                # CUDA version"
echo "  docker run --rm hello-world   # Docker test"
echo "  tailscale ip -4               # Tailscale IP"
echo "  sudo systemctl status mavlink-router"
echo ""
echo "Run NOMAD:"
echo "  cd ~/NOMAD"
echo "  docker compose up -d isaac-ros"
echo "  docker compose logs -f"
echo ""
echo "Or manually:"
echo "  cd ~/NOMAD && source venv/bin/activate"
echo "  python3 -m edge_core.main --port 8000"
echo ""
echo "Test from Ground Station (Windows):"
echo "  curl http://\$(tailscale ip -4):8000/health"
echo "  ssh $CURRENT_USER@\$(tailscale ip -4)"
echo ""
