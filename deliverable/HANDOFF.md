# 交接说明（HANDOFF）— houji UniXNU 移植

> 给下一个接手的人（或下一个会话）看的：现状、证据、下一步。

## 1. 现在能确认的事实（都有实机证据）

1. **UEFI 固件在本机构建成功**：Mu-Silicium + `houjiPkg`，产物 `SILICIUM_UEFI.fd` = 3,145,728 字节，
   `fastboot boot` 后在小米 14 上进入 UniXNU 菜单。
2. **载荷投递链路打通**：96 MiB FAT 镜像嵌入 `boot.img`，UEFI 侧 `HoujiRamDiskDxe` 用
   `label=HOUJIESP` + `totalsect32*512==filesize` + CRC32 校验后挂载；菜单出现 `xnu` 启动项。
   （houji 的 ABL 在通过 ramdisk 分区投递时不稳定，嵌入 FAT 是绕开它的关键手段。）
3. **XNU 内核在本机构建成功**：无 Xcode 的 Linux/WSL 环境，`kernel.macho` 56,086,528 字节，
   与 iOS 16.7.16/20H392 的 kernelcache 完成静态预链接。
4. **内核在真机上真正跑起来了**：打开 MMU、走完 `arm_init()` 的全部阶段
   （`PE_init_platform`、`ml_parse_cpu_topology`、`cpu_bootstrap`、`rtclock_early_init`、
   `kernel_startup_bootstrap`、`cpu_init`、`processor_bootstrap` 均已被闸门验证可达）。
5. **一个明确的硬件故障点**：内核在某个时刻访问 `0x0000000017C10xxx`
   （Qualcomm APSS 看门狗 `qcom,wdt@17c10000` 所在页），触发
   **Data abort: Synchronous external abort**，`SPSR = 0x62000205`（EL1h，内核态）。

## 2. 卡在哪里

**没有任何可用的早期日志通道。** 依次试过并全部失败：

| 尝试 | 结果 |
| --- | --- |
| 内核 `kprintf` | `PE_init_printf()` 排在 `arm_vm_init()` 之后，早期调用无输出 |
| 提前 `PE_create_console()+PE_init_printf()`（`unixnu-earlycon=1`） | 屏幕无新输出 |
| `ml_io_map_wcomb(boot_args.Video)` 直绘帧缓冲 | 无变化 |
| `ml_phys_write_word` 物理直写帧缓冲 | 早期无变化（copy window 未建立，见 README §5.7） |
| panic 时打换行 / 控制台下移 | 无变化（可见 panic 文本来自预链接 Apple 组件） |

屏幕上的日志与 panic 帧由预链接进来的 Apple 代码渲染，**我们改内核源码影响不到它**。

## 3. 下一步（按顺序做，每步都有明确判据）

### 步骤 1（决定性）：验证 pmap 就绪后的物理直写

* 推 `artifacts/boot-houji-hold-none.img`（正常启动到 panic）。
* 判据：屏幕**上部**是否出现 `PANIC (unix banner):` 和随后几行 panic 原因原文。
* 若出现 → 通道成立，进入步骤 2。
* 若未出现 → 见步骤 4。

### 步骤 2：用闸门定位 `0x17C1xxxx` 的访问者

* 已埋闸门：1–16（`arm_init` 全部关键调用前后）、20–22（`arm_vm_init` 内部）、6/7（`machine_startup`）。
* 用 `unixnu-hold=N` 逐个试探，出现 `UNIXNU STAGE N` 即代表该阶段可达。
* 已知可达：1、3、4、5、8–16（早期用不可靠的 adb 判据得到，需用屏显复核）。

### 步骤 3：补 ADT

按 Apple device tree 约定补齐节点属性，让 pexpert 的正规路径能工作：

* `arm-io`：`device_type = "soc"`；
* `intc`：`interrupt-controller`、`master` 属性（`pe_arm_map_interrupt_controller()` 依赖它们）；
* `timer`：`device_type = "timer"` + `reg`。

生成器在设备仓库里（`scripts/make-houji-adt.py` 一族），改完重打 payload 即可，不必重编内核。

### 步骤 4（兜底）：换用可靠的日志硬件或设施

* 外接 UART（最可靠）；
* 或移植社区移植作者的 `houji_debug_append`（内核内存环形缓冲）+ DarwinBoot/UEFI 侧回读显示；
* 或 `docs/uefi-log-qr.md` 的二维码方案。

## 4. 常用命令

```powershell
# 只打镜像（内核没改）
powershell -ExecutionPolicy Bypass -File D:\13u\port\tools\rebuild-and-boot.ps1 -Mode image -Stage none

# 改过内核后重建（约 12 分钟）
powershell -ExecutionPolicy Bypass -File D:\13u\port\tools\rebuild-and-boot.ps1 -Mode kernel -Stage 7

# 只推已有镜像
powershell -ExecutionPolicy Bypass -File D:\13u\port\tools\rebuild-and-boot.ps1 -Mode boot -Stage none
```

WSL 侧脚本：`/mnt/d/13u/tmp/hold-image.sh <stage|none>`（打镜像）、
`hold-park.sh`（重建内核）、`earlycon-image.sh`（带早期控制台的镜像）。

## 5. 安全

* 全程只用了 `fastboot boot`，**没有任何 flash/erase/format**。
* 卡死时：长按电源键 10 秒重启。
* `tools/.gh_token` 是临时 CI token，请吊销。
