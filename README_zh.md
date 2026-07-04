# Blackwell Xid 154 / WPR2 / GSP 崩溃抢救脚本

[English](README.md) | [中文](README_zh.md)

这是一个强大且自动化的恢复脚本，专为 NVIDIA Blackwell 架构 GPU (如 RTX 5090, 5080, 5070, 5060 Ti, PRO 6000 等) 设计。当遭遇 GSP 心跳超时和看门狗锁死等致命故障时，本脚本可以**无需重启系统**，瞬间让 GPU 满血复活。

## 问题背景
在持续的高负载计算（如使用 vLLM/llama.cpp 进行大规模大模型推理，或 Vulkan 光追游戏）下，**或者在开机/加载驱动初始化时**，Blackwell GPU 可能会遭遇致命的内部 GSP (GPU System Processor) 固件停机。

### 场景 A：开机 / 初始化崩溃
在加载驱动时（开机或手动 modprobe），如果 PCIe BAR 扩容失败（例如报错 `NVRM: BAR resizing failed with error '-2'`），或者 GPU 硬件处于一个非清理状态，GSP 固件会因为读到垃圾内存（`0xbadf4100`）而无法初始化，直接暴毙：

```text
NVRM: GPU6 kgspFmcReportErrorCode_GH100: Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
NVRM: GPU6 kfspProcessCommandResponse_GH100: FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x33
NVRM: GPU6 gpuHandleSanityCheckRegReadError_GH100: Possible bad register read: addr: 0x110044,  regvalue: 0xbadf4100
NVRM: GPU7 nvCheckOkFailedNoLog: Check failed: Failure: Generic Error [NV_ERR_GENERIC]
```

### 场景 B：高负载引发的崩溃
在繁重的计算任务中，显卡内部的 TLB 队列或 FECS 上下文可能发生死锁，从而导致 GSP 心跳超时：

```text
NVRM: _kgspRpcRecvPoll: GSP RM heartbeat timed out
NVRM: Xid (PCI:0000:xx:00): 109, ... errorString CTX SWITCH TIMEOUT
NVRM: Xid (PCI:0000:xx:00): 154, ... GPU recovery action changed to GPU Reset Required
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!
```

### 驱动本身的缺陷
虽然 GSP 停机本身是一种保护机制，用来防止处于损坏状态的硬件引发更大问题，但 Linux 内核驱动程序 (580.x, 590.x, 595.x, 610.x) 本应该能够对显卡执行硬重置并恢复。不幸的是，对于 Blackwell 架构来说，官方驱动的恢复路径存在根本性的缺陷。

驱动程序未能成功清空 **WPR2** 安全区，因为它没能真正触发一次底层的 Secondary Bus Reset (SBR)。如果驱动在 WPR2 依然处于上一轮崩溃后的死锁状态下强行初始化 GPU，就会报出如下错误：

```text
NVRM: GPU7 _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
NVRM: GPU7 _kgspBootGspRm: (the GPU is likely in a bad state and may need to be reset)
NVRM: GPU7 RmInitAdapter: Cannot initialize GSP firmware RM
NVRM: GPU 0000:a2:00.0: RmInitAdapter failed! (0x62:0x40:2168)
```

进一步地，这种无法恢复的状态往往会引发级联错误，导致固件加载失败（`error -4`），并最终令驱动初始化强制中止：

```text
nvidia 0000:82:00.0: loading /lib/firmware/nvidia/595.71.05/gsp_ga10x.bin failed with error -4
NVRM: RmFetchGspRmImages: No firmware image found
NVRM: GPU 0000:82:00.0: RmInitAdapter failed! (0x61:0x56:2074)
[drm:nv_drm_dev_load [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00008200] Failed to allocate NvKmsKapiDevice
```

最终，驱动程序并没有正常重置 GPU，而是陷入了无限死循环，疯狂打印 `RC watchdog: GPU is probably locked!`，直接把显卡“变成砖头”，除非你硬拔电源或者重启服务器。

## 解决方案
本仓库提供了一个 Bash 脚本 (`sbr_recover.sh`)，它完美补全了官方驱动缺失的抢救路径。它能从用户空间触发一次真正的底层 Secondary Bus Reset (SBR)，强行清空 WPR2，从而让 GSP 满血复活。

### 脚本工作原理：
1. **发现拓扑**：收集系统上所有 NVIDIA GPU 的上游 PCIe 桥接器。
2. **清理进程与移除设备**：强制停止所有正在使用 GPU 的进程，并将显卡对应的 PCIe 设备从内核中强行拔除（`echo 1 > remove`）。
3. **卸载内核模块**：卸载庞大的 `nvidia` 内核模块家族。
4. **SBR & FLR 双重重置**：利用 `setpci` 向这些上游桥接器发送 **Secondary Bus Reset (SBR)** 信号，紧接着对所有 NVIDIA 设备执行 **Function Level Reset (FLR)**，确保完美清空所有型号 GPU 锁死的 WPR2 安全区。
5. **通用 ReBAR 恢复**：重新扫描 PCIe 总线并调用 `native_resize_bar.sh`。该脚本能够动态探测硬件支持矩阵，并通过 Linux 内核原生的 `resourceX_resize` sysfs 接口，为您的显卡分配绝对最大的 BAR 空间（例如为 5060 Ti 分配 16GB，为 PRO 6000 分配 128GB）。
6. **通用校验**：通过解析 `lspci -v` 获取底层总线结构，确保 CPU 端的 PCI 物理内存分配已精确兑现每张显卡的 Gigabyte 级容量请求。
7. **重载与绑定驱动**：重新加载驱动程序，并通过强制将重启后的设备硬绑定回 `nvidia` 驱动，修复了 Linux udev 热插拔扫描的盲区。

## 使用方法
当您的 GPU 从总线上掉线，或者 `nvidia-smi` 一直卡死无响应时，直接以 root 权限运行本脚本：

```bash
# 赋予所有脚本可执行权限
chmod +x *.sh

# 执行抢救脚本
sudo ./sbr_recover.sh
```
大约 15 秒后，所有掉线的 GPU 都将原地复活，恢复到完美的工作状态！

> **关于 ReBAR / 大显存支持的特别说明**: 
> 本项目完全依托于 **Linux Kernel 6.8+ (如 Ubuntu 24.04)** 自带的原生动态 PCIe 扩容能力。
> 脚本不再使用 `rebar_mod` 这种不稳定的第三方破解方案，而是会通过提取您显卡硬件上的十六进制功能矩阵，算出它支持的极限 BAR 容量索引（如 16GB 对应 `14`，128GB 对应 `17`），再直接写给 `sysfs`。这一机制保证了对所有 NVIDIA 显卡型号 100% 稳定且普适的支持。

## 致谢
极其感谢 [open-gpu-kernel-modules #1080](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1080) 的各位贡献者，尤其是 @Loong0x00 和 @ndizazzo。他们对 GSP 固件和 TLB 失效队列的硬核逆向工程，让我们找到了问题的根本原因，并构思出了在用户空间手动执行 SBR 抢救的伟大方案。
