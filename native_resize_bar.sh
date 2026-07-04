#!/bin/bash
# Native Sysfs PCI BAR Resizer for NVIDIA GPUs
# Dynamically calculates and sets the maximum supported BAR size for each GPU.

echo "Starting native sysfs PCI BAR resize (Dynamic Mode)..."

# Ensure we have root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

DO_BIND=1
if [ "${1:-}" = "--no-bind" ]; then
    DO_BIND=0
fi

# Find all NVIDIA GPUs
for gpu_path in /sys/bus/pci/devices/*; do
    vendor=$(cat $gpu_path/vendor 2>/dev/null)
    device=$(cat $gpu_path/device 2>/dev/null)
    
    # 0x10de is NVIDIA
    if [ "$vendor" = "0x10de" ]; then
        # Check if it's a VGA/3D controller (class 0x030000 or 0x030200)
        class=$(cat $gpu_path/class 2>/dev/null)
        if [[ "$class" != 0x0300* ]] && [[ "$class" != 0x0302* ]]; then
            continue
        fi
        
        bdf=$(basename $gpu_path)
        echo ""
        echo "Found NVIDIA GPU at $bdf (Device ID: $device)"
        
        # Stop driver binding if bound
        if [ -d "$gpu_path/driver" ]; then
            echo "  Unbinding driver for $bdf..."
            echo "$bdf" > $gpu_path/driver/unbind 2>/dev/null || true
        fi
        
        # Dynamically iterate over all resizeable resources for this GPU
        for res_file in $gpu_path/resource*_resize; do
            [ -e "$res_file" ] || continue
            
            mask=$(cat "$res_file" 2>/dev/null || echo "")
            if [ -z "$mask" ]; then continue; fi
            
            # Use python to mathematically extract the highest supported bit from the hex mask
            # Each bit 'i' corresponds to a BAR size of 2^(i+20) bytes.
            max_idx=$(python3 -c "import sys; print(max([i for i in range(64) if (int(sys.argv[1], 16) & (1<<i))] + [-1]))" "$mask" 2>/dev/null)
            
            if [ -n "$max_idx" ] && [ "$max_idx" -ge 0 ]; then
                res_name=$(basename "$res_file")
                echo "  Dynamically detected max BAR index $max_idx for $res_name."
                echo "$max_idx" > "$res_file" 2>/dev/null || echo "  Failed to write $max_idx to $res_name"
            fi
        done
        
        # Trigger PCI rescan for this specific device to apply the new window
        echo 1 > /sys/bus/pci/rescan
        
        # Re-bind driver
        if [ "$DO_BIND" -eq 1 ]; then
            echo "  Rebinding nvidia driver for $bdf..."
            echo "$bdf" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
        fi
    fi
done

echo ""
echo "Done. Check lspci -v to verify Memory at ... [size=...]."
