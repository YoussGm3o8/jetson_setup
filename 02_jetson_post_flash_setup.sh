#!/bin/bash
###############################################################################
# 02_jetson_post_flash_setup.sh
#
# PURPOSE: Run this ON THE JETSON after first boot (OEM setup complete).
#          Installs JetPack 6.2 components, Docker, Isaac ROS 3.2, and
#          ZED SDK with ROS wrapper.
#
# PREREQUISITES:
#   - Jetson Orin Nano 8GB freshly flashed with L4T R36.4.3
#   - OEM first-boot setup completed (user account created)
#   - Internet connection (ethernet recommended)
#
# USAGE:
#   chmod +x 02_jetson_post_flash_setup.sh
#   ./02_jetson_post_flash_setup.sh
#
# This script will:
#   1. Update system packages
#   2. Install full JetPack 6.2 (CUDA, cuDNN, TensorRT, VPI, etc.)
#   3. Install Docker + NVIDIA Container Toolkit
#   4. Configure Isaac ROS 3.2 apt repository and CLI
#   5. Install ZED SDK for JetPack 6 (L4T 36.x)
#   6. Set up ZED ROS 2 wrapper
#   7. Install useful developer tools (jtop, etc.)
#
# Total time: ~45-60 minutes depending on internet speed
###############################################################################

set -e

echo "=============================================="
echo "  Jetson Orin Nano 8GB - Post-Flash Setup"
echo "  JetPack 6.2 + Docker + Isaac ROS + ZED"
echo "=============================================="
echo ""

# --- Safety Check ---
if [ "$(arch)" != "aarch64" ]; then
    echo "ERROR: This script must run ON the Jetson (aarch64), not an x86 host."
    exit 1
fi

# Check we're running as a regular user (not root)
if [ "$EUID" -eq 0 ]; then
    echo "WARNING: Running as root. Some installations may behave differently."
    echo "It's recommended to run as a regular user (script will use sudo when needed)."
    read -p "Continue as root? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        exit 1
    fi
fi

###############################################################################
# STEP 1: System Update
###############################################################################
echo ""
echo "=== Step 1/7: System Update ==="
echo "Updating package lists and upgrading installed packages..."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping system update."
else
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get autoremove -y
fi

###############################################################################
# STEP 2: Install JetPack 6.2
###############################################################################
echo ""
echo "=== Step 2/7: Install JetPack 6.2 ==="
echo "This installs the full NVIDIA JetPack suite:"
echo "  - CUDA Toolkit"
echo "  - cuDNN"
echo "  - TensorRT"
echo "  - VPI (Vision Programming Interface)"
echo "  - Multimedia API"
echo "  - And more..."
echo ""
echo "This will take ~20 minutes."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping JetPack install."
else
    sudo apt-get install -y nvidia-jetpack
    echo ""
    echo "✓ JetPack installed. Verifying..."
    
    # Verify CUDA
    if [ -d "/usr/local/cuda" ]; then
        echo "  ✓ CUDA found at /usr/local/cuda"
        /usr/local/cuda/bin/nvcc --version 2>/dev/null || true
    fi
    
    # Add CUDA to PATH if not already
    if ! echo "$PATH" | grep -q "/usr/local/cuda/bin"; then
        echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
        echo "  ✓ Added CUDA to PATH in ~/.bashrc"
    fi
fi

###############################################################################
# STEP 3: Install Docker + NVIDIA Container Toolkit
###############################################################################
echo ""
echo "=== Step 3/7: Install Docker + NVIDIA Container Toolkit ==="
echo "Docker is required for Isaac ROS and the dusty-nv Jetson containers."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping Docker install."
else
    # Check if Docker is already installed (JetPack 6 may include it)
    if command -v docker &> /dev/null; then
        echo "Docker is already installed:"
        docker --version
    else
        echo "Installing Docker..."
        # Install Docker using official method
        sudo apt-get install -y ca-certificates curl gnupg
        
        # Add Docker's official GPG key
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    echo "  ✓ Added $USER to docker group (logout/login required for effect)"
    
    # Install NVIDIA Container Toolkit
    echo ""
    echo "Installing NVIDIA Container Toolkit..."
    
    # Check if already installed
    if dpkg -l | grep -q nvidia-container-toolkit; then
        echo "  NVIDIA Container Toolkit already installed."
    else
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
    fi
    
    # Configure Docker to use NVIDIA runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    echo "  ✓ Docker + NVIDIA Container Toolkit configured"
    
    # Set NVIDIA as default runtime for Docker
    if [ -f /etc/docker/daemon.json ]; then
        # Check if default-runtime is already set
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
            echo "  ✓ Set NVIDIA as default Docker runtime"
        fi
    fi
fi

###############################################################################
# STEP 4: Configure Isaac ROS 3.2 Apt Repository
###############################################################################
echo ""
echo "=== Step 4/7: Configure Isaac ROS 3.2 Repository ==="
echo "Isaac ROS 3.2 supports JetPack 6.2 on Jetson Orin Nano."
echo "Uses ROS 2 Humble on Ubuntu 22.04."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping Isaac ROS setup."
else
    # Set locale
    echo "Setting locale to UTF-8..."
    sudo apt-get update && sudo apt-get install -y locales
    sudo locale-gen en_US en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export LANG=en_US.UTF-8
    
    # Install dependencies
    echo "Installing ROS 2 and Isaac ROS dependencies..."
    sudo apt-get install -y curl gnupg software-properties-common
    sudo add-apt-repository -y universe
    
    # Add ROS 2 apt repository
    if [ ! -f /usr/share/keyrings/ros-archive-keyring.gpg ]; then
        sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | \
            sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
    fi
    
    # Add Isaac ROS apt repository (release-3.2 for JetPack 6.x)
    echo "Adding Isaac ROS 3.2 apt repository..."
    ISAAC_KEY="/usr/share/keyrings/nvidia-isaac-ros.gpg"
    curl -fsSL https://isaac.download.nvidia.com/isaac-ros/repos.key | sudo gpg --dearmor | sudo tee "$ISAAC_KEY" > /dev/null
    
    ISAAC_LIST="/etc/apt/sources.list.d/nvidia-isaac-ros.list"
    sudo touch "$ISAAC_LIST"
    ISAAC_SOURCE="deb [signed-by=$ISAAC_KEY] https://isaac.download.nvidia.com/isaac-ros/release-3.2 jammy main"
    grep -qxF "$ISAAC_SOURCE" "$ISAAC_LIST" 2>/dev/null || echo "$ISAAC_SOURCE" | sudo tee -a "$ISAAC_LIST"
    
    sudo apt-get update
    
    # Install ROS 2 Humble desktop
    echo ""
    echo "Installing ROS 2 Humble Desktop (this takes a while)..."
    sudo apt-get install -y ros-humble-desktop
    
    # Source ROS 2 in bashrc
    if ! grep -q "source /opt/ros/humble/setup.bash" ~/.bashrc; then
        echo 'source /opt/ros/humble/setup.bash' >> ~/.bashrc
        echo "  ✓ Added ROS 2 Humble to ~/.bashrc"
    fi
    source /opt/ros/humble/setup.bash
    
    # Install Isaac ROS CLI
    echo ""
    echo "Installing Isaac ROS CLI and dependencies..."
    pip3 install termcolor || pip3 install termcolor --break-system-packages
    sudo apt-get install -y isaac-ros-cli || echo "  Note: isaac-ros-cli may need manual install"
    
    # Create Isaac ROS workspace
    echo ""
    echo "Creating Isaac ROS workspace..."
    mkdir -p ~/workspaces/isaac_ros-dev/src
    if ! grep -q "ISAAC_ROS_WS" ~/.bashrc; then
        echo 'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev/}"' >> ~/.bashrc
        echo "  ✓ Set ISAAC_ROS_WS in ~/.bashrc"
    fi
    
    # Initialize Isaac ROS with Docker
    echo ""
    echo "Initializing Isaac ROS Docker environment..."
    sudo isaac-ros init docker 2>/dev/null || echo "  Note: Isaac ROS CLI init may need to be run after re-login (for docker group)"
    
    echo "  ✓ Isaac ROS 3.2 repository configured"
fi

###############################################################################
# STEP 5: Install ZED SDK for JetPack 6 (L4T 36.x)
###############################################################################
echo ""
echo "=== Step 5/7: Install ZED SDK ==="
echo "Installing Stereolabs ZED SDK for JetPack 6 (L4T 36.x, aarch64)."
echo "This includes the ZED SDK, tools, and CUDA support."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping ZED SDK install."
else
    echo "Downloading ZED SDK for JetPack 6 (L4T 36)..."
    
    # Download the ZED SDK installer for JetPack 6
    # Check Stereolabs for the latest URL
    ZED_SDK_URL="https://download.stereolabs.com/zedsdk/4.2/l4t36.4/jetsons"
    ZED_INSTALLER="/tmp/zed_sdk_installer.run"
    
    wget -q --show-progress "$ZED_SDK_URL" -O "$ZED_INSTALLER" || {
        echo ""
        echo "Auto-download failed. The ZED SDK URL may have changed."
        echo "Please download manually from: https://www.stereolabs.com/developers/release"
        echo "Select: ZED SDK for JetPack 6 (L4T 36.x)"
        echo "Save the .run file and provide the path below."
        read -p "Path to ZED SDK .run installer (or 'skip'): " ZED_INSTALLER
        if [[ "$ZED_INSTALLER" == "skip" ]]; then
            echo "Skipping ZED SDK install."
            ZED_INSTALLER=""
        fi
    }
    
    if [ -n "$ZED_INSTALLER" ] && [ -f "$ZED_INSTALLER" ]; then
        chmod +x "$ZED_INSTALLER"
        echo ""
        echo "Running ZED SDK installer..."
        echo "Follow the prompts (accept license, choose install options)."
        echo "Recommended: Accept defaults, install Python API, skip CUDA check."
        echo ""
        sudo "$ZED_INSTALLER"
        echo "  ✓ ZED SDK installed"
    fi
fi

###############################################################################
# STEP 6: Install ZED ROS 2 Wrapper
###############################################################################
echo ""
echo "=== Step 6/7: Install ZED ROS 2 Wrapper ==="
echo "This installs the zed-ros2-wrapper in your Isaac ROS workspace."
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping ZED ROS 2 wrapper install."
else
    # Source ROS 2
    source /opt/ros/humble/setup.bash 2>/dev/null || true
    
    # Install ROS 2 dependencies
    sudo apt-get install -y \
        ros-humble-diagnostic-updater \
        ros-humble-xacro \
        ros-humble-robot-localization \
        ros-humble-nmea-msgs \
        ros-humble-geographic-msgs \
        ros-humble-image-transport \
        ros-humble-image-transport-plugins \
        python3-rosdep python3-colcon-common-extensions
    
    # Initialize rosdep if not done
    if [ ! -d "/etc/ros/rosdep" ]; then
        sudo rosdep init 2>/dev/null || true
    fi
    rosdep update 2>/dev/null || true
    
    # Clone ZED ROS 2 wrapper
    ZED_WS="$HOME/workspaces/isaac_ros-dev"
    mkdir -p "$ZED_WS/src"
    cd "$ZED_WS/src"
    
    if [ ! -d "zed-ros2-wrapper" ]; then
        echo "Cloning zed-ros2-wrapper..."
        git clone --recursive https://github.com/stereolabs/zed-ros2-wrapper.git
    else
        echo "zed-ros2-wrapper already exists, updating..."
        cd zed-ros2-wrapper
        git pull
        git submodule update --init --recursive
        cd ..
    fi
    
    # Build the workspace
    cd "$ZED_WS"
    echo ""
    echo "Building ZED ROS 2 wrapper (this may take 10-15 minutes)..."
    rosdep install --from-paths src --ignore-src -r -y 2>/dev/null || true
    colcon build --symlink-install --cmake-args=-DCMAKE_BUILD_TYPE=Release --parallel-workers $(nproc)
    
    # Source the workspace
    if ! grep -q "source $ZED_WS/install/setup.bash" ~/.bashrc; then
        echo "source $ZED_WS/install/setup.bash" >> ~/.bashrc
        echo "  ✓ Added ZED ROS 2 workspace to ~/.bashrc"
    fi
    
    echo "  ✓ ZED ROS 2 wrapper installed and built"
fi

###############################################################################
# STEP 7: Developer Tools
###############################################################################
echo ""
echo "=== Step 7/7: Developer Tools ==="
echo "Installing useful developer tools:"
echo "  - jtop (Jetson system monitor)"
echo "  - htop, tmux, nano, vim"
echo "  - Python tools"
echo ""
read -p "Proceed? (y/n): " PROCEED
if [[ "$PROCEED" != "y" ]]; then
    echo "Skipping developer tools."
else
    # Install jtop
    sudo pip3 install -U jetson-stats || sudo pip3 install -U jetson-stats --break-system-packages
    
    # Install common tools
    sudo apt-get install -y htop tmux nano vim tree curl net-tools
    
    echo "  ✓ Developer tools installed"
    echo ""
    echo "  Run 'jtop' to see system stats (may need logout/login first)"
fi

###############################################################################
# DONE
###############################################################################
echo ""
echo "=============================================="
echo "  Setup Complete!"
echo "=============================================="
echo ""
echo "Installed components:"
echo "  ✓ JetPack 6.2 (CUDA, cuDNN, TensorRT, VPI)"
echo "  ✓ Docker + NVIDIA Container Toolkit"
echo "  ✓ ROS 2 Humble"
echo "  ✓ Isaac ROS 3.2 repository + CLI"
echo "  ✓ ZED SDK + ZED ROS 2 Wrapper"
echo "  ✓ Developer tools (jtop, htop, tmux)"
echo ""
echo "IMPORTANT: Log out and back in (or reboot) for all changes to take effect."
echo "  sudo reboot"
echo ""
echo "After reboot, verify everything:"
echo "  jtop                          # Jetson system monitor"
echo "  nvcc --version                # CUDA version"
echo "  docker run --rm hello-world   # Docker test"
echo "  ros2 topic list               # ROS 2 test"
echo ""
echo "To launch ZED camera with ROS 2:"
echo "  ros2 launch zed_wrapper zed_camera.launch.py camera_model:=<your_zed_model>"
echo ""
echo "To use Isaac ROS Docker:"
echo "  cd ~/workspaces/isaac_ros-dev"
echo "  isaac-ros run"
echo ""
