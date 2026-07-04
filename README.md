# Blackwell Xid 154 / WPR2 / GSP Crash Recovery

A robust, automated recovery script designed to revive NVIDIA Blackwell architecture GPUs (RTX 5090, 5080, 5070, 5060 Ti, PRO 6000, etc.) from GSP heartbeat timeouts and watchdog lockups **without requiring a system reboot**.

## The Problem
Under sustained heavy workloads (such as massive LLM inference with vLLM/llama.cpp or Vulkan RT gaming), **OR during driver initialization at boot/module load**, Blackwell GPUs may experience fatal internal GSP (GPU System Processor) firmware halts.

### Scenario A: Boot-time / Initialization Crash
During driver load (at boot or after reloading the module), if the PCIe BAR resizing fails (e.g., `NVRM: BAR resizing failed with error '-2'`) or if the GPU is in an unclean state, the GSP firmware fails to initialize because it reads garbage memory (`0xbadf4100`), resulting in instant death:

```text
NVRM: GPU6 kgspFmcReportErrorCode_GH100: Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
NVRM: GPU6 kfspProcessCommandResponse_GH100: FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x33
NVRM: GPU6 gpuHandleSanityCheckRegReadError_GH100: Possible bad register read: addr: 0x110044,  regvalue: 0xbadf4100
NVRM: GPU7 nvCheckOkFailedNoLog: Check failed: Failure: Generic Error [NV_ERR_GENERIC]
```

### Scenario B: Workload-induced Crash
Under heavy compute loads, internal TLB queues or FECS contexts may deadlock, causing a GSP heartbeat timeout:

```text
NVRM: _kgspRpcRecvPoll: GSP RM heartbeat timed out
NVRM: Xid (PCI:0000:xx:00): 109, ... errorString CTX SWITCH TIMEOUT
NVRM: Xid (PCI:0000:xx:00): 154, ... GPU recovery action changed to GPU Reset Required
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!
```

### The Driver Bug
While the GSP halting is a legitimate hardware/firmware safeguard against corrupt states, the Linux kernel driver (580.x, 590.x, 595.x, 610.x) is supposed to perform a hardware reset and recover the GPU. However, for Blackwell architectures, the recovery path in the driver is fundamentally broken. 

The driver fails to clear the **WPR2** secure region because it fails to invoke a true hardware Secondary Bus Reset (SBR). If the driver attempts to initialize the GPU while WPR2 is still locked from a previous crash or unclean boot state, it throws this exact error:

```text
NVRM: GPU7 _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
NVRM: GPU7 _kgspBootGspRm: (the GPU is likely in a bad state and may need to be reset)
NVRM: GPU7 RmInitAdapter: Cannot initialize GSP firmware RM
NVRM: GPU 0000:a2:00.0: RmInitAdapter failed! (0x62:0x40:2168)
```

Furthermore, this unrecoverable state often cascades into firmware loading failures, manifesting as `error -4` (failed firmware load) followed by an immediate driver initialization abort:

```text
nvidia 0000:82:00.0: loading /lib/firmware/nvidia/595.71.05/gsp_ga10x.bin failed with error -4
NVRM: RmFetchGspRmImages: No firmware image found
NVRM: GPU 0000:82:00.0: RmInitAdapter failed! (0x61:0x56:2074)
[drm:nv_drm_dev_load [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00008200] Failed to allocate NvKmsKapiDevice
```

Instead of properly resetting the GPU, the driver loops infinitely, printing `RC watchdog: GPU is probably locked!`, effectively bricking the GPU until a hard reboot or power cycle is performed.

## The Solution
This repository provides a bash script (`sbr_recover.sh`) that serves as the missing driver recovery path. It performs a true Secondary Bus Reset (SBR) from userspace to clear WPR2 and revive the GSP.

### What the script does:
1. **Discovers Topology**: Gathers the upstream PCIe bridges of all NVIDIA GPUs on the system.
2. **Kills Processes & Removes Devices**: Stops all processes using the GPU and forcefully removes the PCIe devices from the kernel (`echo 1 > remove`).
3. **Unloads Modules**: Unloads the monolithic `nvidia` kernel modules.
4. **SBR Reset**: Performs a **Secondary Bus Reset (SBR)** via `setpci` on the upstream bridges, successfully clearing the locked WPR2 region.
5. **Universal ReBAR Recovery**: Rescans the PCIe bus and invokes `native_resize_bar.sh`, which dynamically probes hardware capabilities and applies the absolute maximum BAR size (e.g., 16GB for 5060 Ti, 128GB for PRO 6000) via the kernel `resourceX_resize` sysfs interface.
6. **Universal Verification**: Parses kernel bus structures via `lspci -v` to ensure CPU-side PCI physical memory allocations match the Gigabyte demands of every card. 
7. **Reloads & Binds Drivers**: Reloads the drivers and manually patches udev blindspots by hard-binding the reset devices back to the `nvidia` driver.

## Usage
When your GPU drops from the bus or `nvidia-smi` hangs indefinitely, simply run the script as root:

```bash
# Ensure the scripts have executable permissions
chmod +x *.sh

# Execute the recovery script
sudo ./sbr_recover.sh
```
In about 15 seconds, all dropped GPUs will be recovered and fully functional again.

> **Note on ReBAR / Large BAR Support**: 
> This project relies entirely on **Linux Kernel 6.8+ (Ubuntu 24.04)** native dynamic PCIe resizing.
> Instead of using legacy tools like `rebar_mod`, this script parses the hex offsets of your GPU's actual hardware capability matrix to calculate its maximum supported BAR size index (e.g. `14` for 16GB, `17` for 128GB) and natively writes it into the `sysfs` tree. It guarantees 100% stable, universal adaptation to any NVIDIA model.

## Credits
Immense thanks to the contributors of [open-gpu-kernel-modules #1080](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1080), specifically @Loong0x00 and @ndizazzo, whose reverse engineering of the GSP firmware and TLB invalidation queues uncovered the root cause and conceptualized the manual userspace SBR workaround.
