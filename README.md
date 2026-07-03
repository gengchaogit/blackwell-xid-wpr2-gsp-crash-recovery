# Blackwell Xid 154 / WPR2 / GSP Crash Recovery

A robust, automated recovery script designed to revive NVIDIA Blackwell architecture GPUs (RTX 5090, 5080, 5070, 5060 Ti, PRO 6000, etc.) from GSP heartbeat timeouts and watchdog lockups **without requiring a system reboot**.

## The Problem
Under sustained heavy workloads (such as Vulkan RT gaming via Proton, or massive LLM inference with vLLM/llama.cpp), Blackwell GPUs may experience internal GSP firmware halts (e.g., TLB queue deadlocks). This typically manifests in `dmesg` as:

```text
NVRM: _kgspRpcRecvPoll: GSP RM heartbeat timed out
NVRM: Xid (PCI:0000:xx:00): 109, ... errorString CTX SWITCH TIMEOUT
NVRM: Xid (PCI:0000:xx:00): 154, ... GPU recovery action changed to GPU Reset Required
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!
```

### The Driver Bug
While the GSP halting is a legitimate hardware/firmware safeguard against corrupt states, the Linux kernel driver (580.x, 590.x, 595.x, 610.x) is supposed to perform a hardware reset and recover the GPU. However, for Blackwell architectures, the recovery path in the driver is fundamentally broken. 

The driver fails to clear the **WPR2** secure region because it fails to invoke a true hardware Secondary Bus Reset (SBR). Instead of resetting the GPU, the driver loops infinitely, printing `RC watchdog: GPU is probably locked!`, effectively bricking the GPU until a hard reboot or power cycle is performed.

## The Solution
This repository provides a bash script (`sbr_recover.sh`) that serves as the missing driver recovery path. It performs a true Secondary Bus Reset (SBR) from userspace to clear WPR2 and revive the GSP.

### What the script does:
1. **Discovers Topology**: Gathers the upstream PCIe bridges of all NVIDIA GPUs on the system.
2. **Kills Processes & Removes Devices**: Stops all processes using the GPU and forcefully removes the PCIe devices from the kernel (`echo 1 > remove`).
3. **Unloads Modules**: Unloads the monolithic `nvidia` kernel modules.
4. **SBR Reset**: Performs a **Secondary Bus Reset (SBR)** via `setpci` on the upstream bridges, successfully clearing the locked WPR2 region.
5. **Rescans & Reloads**: Rescans the PCIe bus and reloads the drivers.

## Usage
When your GPU drops from the bus or `nvidia-smi` hangs indefinitely, simply run the script as root:
```bash
sudo ./sbr_recover.sh
```
In about 10 seconds, all dropped GPUs will be recovered and fully functional again.

> **Note for Custom ReBAR Setups**: If you are using a motherboard that does NOT support native ReBAR (like some Gigabyte or older Xeon boards) and rely on a kernel patch (e.g. `rebar_mod`) to spoof 16GB BARs, you **must** insert your `rebar_mod` invocation right after the PCI rescan step in this script. The hardware SBR will revert the BAR size to its VBIOS default (usually 256MB), and the driver will crash upon loading if the BAR isn't stretched back out first. 
> For native ReBAR motherboards (like AMD EPYC), the script works perfectly out of the box.

## Credits
Immense thanks to the contributors of [open-gpu-kernel-modules #1080](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1080), specifically @Loong0x00 and @ndizazzo, whose reverse engineering of the GSP firmware and TLB invalidation queues uncovered the root cause and conceptualized the manual userspace SBR workaround.
