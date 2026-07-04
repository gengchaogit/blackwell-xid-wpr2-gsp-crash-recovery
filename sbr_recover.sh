#!/bin/bash
# Blackwell SBR (Secondary Bus Reset) GPU Recovery Script
# Resolves NVRM: _kgspRpcRecvPoll: GSP RM heartbeat timed out and WPR2 lockup issues
# Re-applies 16GB BAR1 for GB206/RTX 5060 Ti before loading the NVIDIA driver.
#
# Warning: This script stops display managers and kills processes using NVIDIA GPUs.
# Use it when your GPU has fallen off the bus (Xid 79 / Xid 154 / GSP crash).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
RUNTIME_MODPROBE_BLOCK=/run/modprobe.d/block-nvidia-sbr-recover.conf

echo -e "${YELLOW}==================================================${NC}"

restore_rebar() {
    echo "  Running native PCI BAR resize..."
    /root/native_resize_bar.sh --no-bind
}

verify_rebar() {
    local bad_rebar=0
    local mem_size

    # Iterate over ALL NVIDIA GPUs dynamically
    for bdf in $(lspci -Dnn | awk '/NVIDIA/ && /10de:/ && /VGA|3D/ {print $1}'); do
        # Extract the size of the prefetchable BAR that is in Gigabytes (G)
        mem_size=$(lspci -v -s "$bdf" | grep -E 'Memory at .* \(64-bit, prefetchable\) \[size=' | grep -oE 'size=[0-9]+G' | tail -n 1 | cut -d= -f2)
        
        if [ -z "$mem_size" ]; then
            echo -e "${RED}  ${bdf}: Physical BAR size is less than 1G (Native Resize failed).${NC}"
            bad_rebar=1
        else
            echo -e "${GREEN}  ${bdf}: Physical BAR size dynamically verified at ${mem_size}.${NC}"
        fi
    done

    return "$bad_rebar"
}

echo -e "${YELLOW}  Blackwell SBR GPU Recovery Script${NC}"
echo -e "${YELLOW}==================================================${NC}"

# 1. Collect bridge information (MUST be done before removing devices)
echo -e "${YELLOW}[1/7] Collecting upstream PCIe bridges for NVIDIA GPUs...${NC}"
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
echo -e "${GREEN}  Found bridges: ${bridges[*]:-none}${NC}"

# 2. Stop GPU processes
echo -e "${YELLOW}[2/7] Stopping all GPU processes...${NC}"
mkdir -p /run/modprobe.d
cat > "$RUNTIME_MODPROBE_BLOCK" <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidia_peermem
EOF

systemctl isolate multi-user.target 2>/dev/null || true
systemctl stop display-manager gdm lightdm sddm docker containerd nvidia-persistenced 2>/dev/null || true
pkill -9 -f 'vllm|sglang|llama|nvidia-smi|nvtop|cuda' 2>/dev/null || true
if command -v fuser &>/dev/null; then
    for dev in /dev/nvidia*; do
        fuser -k -9 "$dev" 2>/dev/null || true
    done
fi
sleep 2

# 3. Unload driver modules before removing devices.
echo -e "${YELLOW}[3/7] Unloading NVIDIA driver modules...${NC}"
for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
    if lsmod | grep -q "^${mod} "; then
        rmmod "$mod" 2>/dev/null || true
        sleep 1
    fi
done
sleep 1
if lsmod | grep -q '^nvidia'; then
    echo -e "${RED}  NVIDIA modules are still loaded; refusing to continue into PCIe reset.${NC}"
    lsmod | grep '^nvidia' || true
    rm -f "$RUNTIME_MODPROBE_BLOCK"
    exit 1
fi

# 4. Remove devices
echo -e "${YELLOW}[4/7] Removing all NVIDIA PCIe devices...${NC}"
for bdf in $(lspci -D | awk '/NVIDIA/ {print $1}'); do
    if [ -f "/sys/bus/pci/devices/${bdf}/remove" ]; then
        echo 1 > "/sys/bus/pci/devices/${bdf}/remove" 2>/dev/null || true
    fi
done
sleep 2

# 5. Execute SBR
echo -e "${YELLOW}[5/7] Performing Secondary Bus Reset (SBR) on upstream bridges to clear WPR2...${NC}"
for bridge in "${bridges[@]}"; do
    echo "  - SBR on bridge $bridge"
    setpci -s "$bridge" BRIDGE_CONTROL.w=0040:0040 2>/dev/null || true
    sleep 1
    setpci -s "$bridge" BRIDGE_CONTROL.w=0000:0040 2>/dev/null || true
done
sleep 3

# 6. Rescan bus, clear WPR2, and restore ReBAR before the driver binds.
echo -e "${YELLOW}[6/7] Rescanning PCIe bus, clearing WPR2, and restoring ReBAR...${NC}"
echo 1 > /sys/bus/pci/rescan
sleep 3
count=$(lspci -D | grep -i nvidia | grep -E 'VGA|3D controller' | wc -l)
echo -e "${GREEN}  Found $count GPUs on PCIe bus${NC}"

echo -e "${YELLOW}  First ReBAR pass...${NC}"
restore_rebar

echo -e "${YELLOW}  FLR pass on all NVIDIA GPUs to clear WPR2...${NC}"
for bdf in $(lspci -Dnn | awk '/NVIDIA/ && /10de:/ && /VGA|3D/ {print $1}'); do
    if [ -f "/sys/bus/pci/devices/${bdf}/reset" ]; then
        echo "  - FLR $bdf"
        echo 1 > "/sys/bus/pci/devices/${bdf}/reset" 2>/dev/null || true
    else
        echo -e "${YELLOW}  - ${bdf} has no sysfs reset file${NC}"
    fi
done
sleep 3

echo -e "${YELLOW}  Second ReBAR pass after FLR...${NC}"
restore_rebar

if ! verify_rebar; then
    echo -e "${RED}  Refusing to load NVIDIA driver with mismatched hardware ReBAR state.${NC}"
    echo -e "${RED}  Check dmesg for rebar_mod errors.${NC}"
    exit 1
fi

# 7. Reload modules
echo -e "${YELLOW}[7/7] Loading NVIDIA driver...${NC}"
rm -f "$RUNTIME_MODPROBE_BLOCK"
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    modprobe "$mod" 2>/dev/null || true
done

# Manually bind devices (required because udev ignores them during the blacklist window)
for bdf in $(lspci -Dnn | awk '/NVIDIA/ && /10de:/ && /VGA|3D/ {print $1}'); do
    echo "$bdf" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
done


sleep 2
echo -e "${YELLOW}==================================================${NC}"
target_gpu_count=0
smi_target_count=0
smi_bdfs=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | tr 'A-F' 'a-f' | sed 's/^00000000:/0000:/' || true)
for bdf in $(lspci -Dnn | awk '/NVIDIA/ && /10de:/ && /VGA|3D/ {print $1}'); do
    target_gpu_count=$((target_gpu_count + 1))
    if echo "$smi_bdfs" | grep -qx "$bdf"; then
        smi_target_count=$((smi_target_count + 1))
    fi
done
nvidia-smi -L 2>/dev/null || true
if [ "$smi_target_count" -eq "$target_gpu_count" ] && verify_rebar; then
    echo -e "${GREEN}✓ SBR Recovery Successful!${NC}"
else
    echo -e "${RED}✗ Recovery Failed: ${smi_target_count}/${target_gpu_count} target GPUs visible in nvidia-smi${NC}"
    exit 1
fi
