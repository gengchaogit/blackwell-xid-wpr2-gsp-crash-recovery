#!/bin/bash
# Blackwell SBR (Secondary Bus Reset) GPU Recovery Script
# Resolves NVRM: _kgspRpcRecvPoll: GSP RM heartbeat timed out and WPR2 lockup issues
#
# Warning: This script stops display managers and kills processes using NVIDIA GPUs.
# Use it when your GPU has fallen off the bus (Xid 79 / Xid 154 / GSP crash).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}==================================================${NC}"
echo -e "${YELLOW}  Blackwell SBR GPU Ultimate Recovery Script${NC}"
echo -e "${YELLOW}==================================================${NC}"

# 1. Collect bridge information (MUST be done before removing devices)
echo -e "${YELLOW}[1/6] Collecting upstream PCIe bridges for NVIDIA GPUs...${NC}"
bridges=()
for bdf in $(lspci -D | grep -i nvidia | grep -E 'VGA|3D controller' | awk '{print $1}'); do
    bus_hex=$(echo "$bdf" | sed 's/0000://' | cut -d: -f1)
    for bridge_dir in /sys/bus/pci/devices/0000:*/; do
        if [ -d "${bridge_dir}pci_bus/0000:${bus_hex}" ]; then
            bridge=$(basename "$bridge_dir")
            if [[ ! " ${bridges[*]} " =~ " ${bridge} " ]]; then
                bridges+=("$bridge")
            fi
        fi
    done
done
echo -e "${GREEN}  ✓ Found bridges: ${bridges[*]}${NC}"

# 2. Stop GPU processes
echo -e "${YELLOW}[2/6] Stopping all GPU processes...${NC}"
systemctl stop display-manager 2>/dev/null || true
if command -v fuser &>/dev/null; then
    for dev in /dev/nvidia*; do
        fuser -k "$dev" 2>/dev/null || true
    done
fi
sleep 2

# 3. Remove devices
echo -e "${YELLOW}[3/6] Removing all NVIDIA GPU PCIe devices...${NC}"
for bdf in $(lspci -D | grep -i nvidia | awk '{print $1}'); do
    if [ -f "/sys/bus/pci/devices/${bdf}/remove" ]; then
        echo 1 > "/sys/bus/pci/devices/${bdf}/remove" 2>/dev/null || true
    fi
done
sleep 2

# 4. Unload driver modules
echo -e "${YELLOW}[4/6] Unloading NVIDIA driver modules...${NC}"
for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if lsmod | grep -q "^${mod} "; then
        rmmod "$mod" 2>/dev/null || true
    fi
done
sleep 1

# 5. Execute SBR
echo -e "${YELLOW}[5/6] Performing Secondary Bus Reset (SBR) on upstream bridges to clear WPR2...${NC}"
for bridge in "${bridges[@]}"; do
    echo "  - SBR on bridge $bridge"
    setpci -s "$bridge" BRIDGE_CONTROL.w=0040:0040 2>/dev/null || true
    sleep 1
    setpci -s "$bridge" BRIDGE_CONTROL.w=0000:0040 2>/dev/null || true
done
sleep 3

# 6. Rescan bus
echo -e "${YELLOW}[6/6] Rescanning PCIe bus and reloading drivers...${NC}"
echo 1 > /sys/bus/pci/rescan
sleep 3
count=$(lspci -D | grep -i nvidia | grep -E 'VGA|3D controller' | wc -l)
echo -e "${GREEN}  ✓ Found $count GPUs${NC}"

# Reload modules
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    modprobe "$mod" 2>/dev/null || true
done

sleep 2
echo -e "${YELLOW}==================================================${NC}"
nvidia-smi -L 2>/dev/null && echo -e "${GREEN}✓ SBR Recovery Successful!${NC}" || echo -e "${RED}✗ Recovery Failed${NC}"
