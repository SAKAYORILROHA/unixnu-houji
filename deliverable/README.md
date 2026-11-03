# 小米 14（houji / SM8650）UniXNU 移植 — 阶段交付与工程记录

> 最后更新：2026-11-02。本文档记录「在本机把 UniXNU 移植到小米 14」到目前为止的
> 全部可验证成果、踩过的坑、以及后续路线。

---

## 0. 一句话状态

| 阶段 | 状态 |
| --- | --- |
| 构建工具链（Linux/WSL 无 Xcode） | ✅ 完成 |
| UEFI 固件（Mu-Silicium + houjiPkg）本机构建 | ✅ 3 MiB 固件卷，字节数严格 `0x300000` |
| 实机 `fastboot boot` 进 UniXNU 菜单 | ✅ 真机确认 |
| FAT 载荷嵌入 Image、菜单出现 `xnu` 启动项 | ✅ 真机确认（绕过 houji 不可靠的 ramdisk 传递） |
| XNU 内核本机构建 + 与 iOS 16 kernelcache 预链接 | ✅ `kernel.macho` 56 MB |
| 内核真机启动、打开 MMU、跑到内核早期初始化 | ✅ 真机确认 |
| 越过内核早期的一处 `Data abort (Synchronous external abort)` | ⚠️ 已定位到可疑区域，尚未修复 |
| iOS UNIX userland 启动 | ⏳ 未开始（社区移植本身也未达到） |

---

## 1. 硬件与目标系统（实测值）

| 项 | 值 |
| --- | --- |
| 设备 | `fastboot getvar product` = **houji**，SM8650（pineapple），`unlocked: yes` |
| 分区 | `boot_a` 96 MB、`vendor_boot_a` 96 MB、`init_boot_a` 8 MB、`max-download-size` 768 MB |
| 系统 | ColorOS 17（移植测试期间数据可随意修改） |
| 目标 IPSW | iPhone X / iOS **16.7.16 / 20H392**（`d22ap`，chip `0x8015`，board 6） |
| kernelcache | 解压后 sha256 `2ec297bac95bcba01046fd0148e97e7e5885c05a6c18827f39f534ba375c1221`（已钉进 `board.toml`） |
| 引导方式 | **只用 `fastboot boot`**，全程未写任何分区 |

---

## 2. 产物清单

| 文件 | 说明 |
| --- | --- |
| `artifacts/boot-houji-uefi.img` | 仅 BootShim + 固件卷 + DTB，实机到 UniXNU 菜单 |
| `artifacts/boot-houji-embed.img` | 追加嵌入 96 MiB FAT 载荷（占位 kernel），菜单出现 `xnu` 项 |
| `artifacts/boot-houji-xnu.img` | **真内核** + 嵌入载荷（第一次真正启动 XNU） |
| `artifacts/boot-houji-hold-N.img` | 阶段闸门版（`unixnu-hold=N`），用于定位内核启动故障 |
| `device/houji-device.tar.gz` | 完整设备仓库快照（board.toml / configs / patches / scripts / inputs） |
| `device/feeds.toml` | 源钉（xnu / libplatform 版本与 commit） |
| `patches/bootimg-patched.py` | 修好 v4 头校验 + 新增 `--embed` 的 `bootimg.py` |
| `patches/xnu-work-tree.diff` | 对 XNU 工作树的全部改动 |
| `patches/iig-darwin22.py` | Darwin 22 IORPC 兼容的 IIG 包装器 |
| `patches/setup-toolchain.py` | Linux 工具链安装脚本 |
| `patches/Menu.c.patched` | 菜单输入检测补丁（无输入设备时走 fallback 超时） |
| `tools/stage-test.ps1` | 阶段测试脚本（自动判别） |
| `tools/push2.ps1` / `dispatch.ps1` / `fetch2.ps1` | GitHub API 建仓/推送/触发 CI/下载产物（绕开被墙的 git push） |
| `tools/.gh_token` | CI 用的 GitHub token（**用完请吊销**） |

### 2.1 现在该用哪些镜像

当前内核 sha256 `2a64d62620835b8fa091682f00b3639730a11df4338d62072014f4cddd8f4d80`
（含阶段闸门、物理地址直写帧缓冲/IMEM、panic 大字横幅、panic 记录也已改为物理写）。

| 镜像 | 用途 | 判定 |
| --- | --- | --- |
| `boot-houji-hold-none.img`（07:35） | **首选测试**：正常启动到 panic | 屏幕上部应出现 `PANIC (unixnu banner):` + 原因原文 |
| `boot-houji-hold-7.img`（07:35） | 停在 `machine_startup` 入口 | 应出现 `UNIXNU STAGE 7` |

镜像校验值：`hold-none.img` = `25bfc71134c3fecc57fd96216045d163028e0408e3c4d7a0c1c215e7e2befaa7`，
`hold-7.img` = `c0061acdd45a5b7807e63d5aab261d2cc5c0926bc4e2b5fac7bdd0175705a526`。
| `boot-houji-hold-<1..22>.img` | 各阶段闸门（早期版本，闸门逻辑相同） | 各阶段可达性 |
| `boot-houji-xnu.img` 及 `*-quiet/wdt/inset/panic*` | 历史实验镜像：第一次真机启动 XNU、看门狗对照、静默启动对比等 | 已用于得出 §5 的结论 |

**已用反汇编静态核对过出货内核**：`_unixnu_stage_hold` 确实调用
`PE_parse_boot_argn("unixnu-hold")` + `ml_phys_write_word_64`（写 IMEM 标记）；
`_unixnu_panic_draw` 确实调用 `unixnu_panic_fb_init/fill/text`；
`_unixnu_panic_record` 已无 `ml_io_map` 调用。

其余 `boot-houji-*.img` 都是早期探索阶段的产物，保留仅供对比。

---

## 3. 复现步骤

### 3.1 环境

WSL2 Ubuntu 26.04，6 核 / 7.9 GB；WSL VHDX 在 D 盘。github.com 直连不通，用 `gh-proxy.com` 镜像；
Apple CDN（`updates.cdn-apple.com`）直连约 7 MB/s。

```bash
git config --global --add url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
git config --global --add url."https://gh-proxy.com/https://github.com/".insteadOf "git@github.com:"
```

### 3.2 工具链（首次约 1.5 小时）

```bash
cd UniXNU && scripts/linux/setup-toolchain.py -j 4 /opt/unixnu-linux
```
产出 clang 24（含 `__builtin_xnu_type_*`）、cctools `ld64`、`mig`、`iig`、`lzfse`，
以及 `xcrun`/`plutil`/`codesign` 垫片。

### 3.3 设备仓库与源码树

```bash
./unixnu defconfig houji_defconfig -D ../houji-device
./unixnu fetch -D ../houji-device
./unixnu tree  -D ../houji-device
bash ../houji-device/scripts/apply-tree-xnu-fixes.sh ../houji-device   # 关键：见 §4
```

### 3.4 内核 → 载荷 → 固件 → 启动镜像

```bash
./unixnu build kernel  -D ../houji-device -j 4     # 产出 kernel.macho（含 prelink）
./unixnu build payload -D ../houji-device --kernel out/houji/kernel/kernel.macho
# 更新 PayloadIdentity.h（payload 的 size + crc32），然后：
./unixnu build firmware -D ../houji-device --uefi ~/unixnu/Mu-Silicium --edk2 ~/unixnu/Mu-Silicium/Mu_Basecore
./unixnu bootimg -D ../houji-device --uefi ~/unixnu/Mu-Silicium \
  --fd ~/unixnu/Mu-Silicium/Build/houjiPkg/DEBUG_CLANGPDB/FV/SILICIUM_UEFI.fd \
  --dtb ../inputs/houji-vb-dtb0.dtb --ramdisk none \
  --embed out/houji/payload/payload.img -o out/boot.img
```

`kernel` 步骤有个已知坑：**首次构建必须让 bootstrap pass 真正跑一遍**（否则静态库阶段报
`No XNU symbol names: run a kernel pass first`）；若最终 pass 报
`compile_commands.json` 相关的 `sed: can't read startup.o.json`，`touch` 一下该文件再跑一遍即可。

---

## 4. 让 XNU 在非 Apple 主机上编出来的全部改动

> 一键脚本：`device/scripts/apply-tree-xnu-fixes.sh`（幂等，可重复执行）

1. **option 只能从机器级配置打开**：`config/MASTER.arm64.bcm2837` 追加
   `options NOS_ARM_ASM` / `options NOS_ARM_PMAP`。改 `config/MASTER` 无效（会被机器配置覆盖）。
2. **补 Apple 闭源的 PPL/TXM 部分**（Qualcomm 无对应硬件）：
   - `osfmk/arm64/amcc_rorgn_{common,ppl,ppl_amcc,ppl_ctrr3}.c`（KTRR/CTRR 文本锁）
   - `osfmk/arm64/ppl/{sart.h,uat.h}`（含 `sart_bootstrap`/`uat_bootstrap` 的 inline no-op）
   - `osfmk/arm64/tunables/tunables.s`（`APPLY_TUNABLES` 空宏）
   - `osfmk/arm/pmap/pmap_ppl_apple_stub.c`：`pmap_ppl_lockdown_pages`、`pmap_ppl_unlockdown_pages`、
     `ptep_get_iommu`、`pmap_pending_preemption`、`_pmap_pending_preemption_real`、
     `ml_enable_monitor`、`CleanPoC_DcacheRegion_Force_nopreempt_nohid`
3. **prelink**：`kits/NativePrelink` → 实际是 `kits/XnuPrelink`；并给 `MATH_LITERAL_POOLS`
   补上 20H392 的 Libm 常量池（`0xfffffff005b8c1cc` 处的 instruction-inventory 失败）。
4. `patches/xnu-iorpc-message-from-mach.patch`：给预链接的 iOS 16 存储组件提供 `IORPCMessageFromMach`。
5. clang 24 兼容：去掉 Apple 专有编译选项、`KALLOC_TYPE_IS_COMPATIBLE_PTR` 恒真、
   36 处 `uio_stackbuf_t` 过对齐数组改写、`libkern/c++/OSKext.cpp` 等小修。

已确认的构建事实：BCM2837 机器配置下 `XNU_MONITOR = 0`，内核走非 monitor 的 pmap 路径。

---

## 5. 真机 bring-up 结论

### 5.1 已经验证的启动链

```
fastboot boot boot-houji-xnu.img
  → USB/ABL → BootShim → 3 MiB UEFI 固件卷 → UniXNU 菜单（倒计时自动选 xnu）
  → DarwinBoot 加载 56 MB 预链接内核
  → XNU 启动、打开 MMU、打印早期自检
  → 访问 0x17C10xxx 触发 Data abort（Synchronous external abort）→ panic
```

### 5.2 panic 帧（从实机屏幕照片 OCR）

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `SPSR` | `0x62000205` | 低 4 位 `0101` = EL1h，异常发生在内核态 |
| `FAR` | `0x0000000017C108xx` | 落在 **Qualcomm APSS 看门狗**（`qcom,wdt@17c10000`） |
| `ESR` | 同步外部中止 | 该地址对 AP 侧不可访问 / 受 TZ 保护 |

### 5.3 已排除的假设

- **不是 arm-io 范围映射导致的**：把 ADT 的 `arm-io` ranges 从 `0x17000000+0x08000000`
  缩到 `+0x00400000`，panic 现象完全不变。
- **不是我们的看门狗写入引起的**：撤掉 UEFI 侧的看门狗写入后 panic 依旧。
- **不是内核源码打印的 panic 屏**：`video_console.c` 光标下移、`kern/debug.c` panic 前后插换行、
  帧缓冲直绘横幅，三种都试过，屏幕无任何变化 → 这段文本来自预链接进来的 Apple 组件。
- **不是 monitor 模式问题**：`XNU_MONITOR = 0`，PPL stub 只覆盖少数分支。

### 5.4 关键困难：内核的 `kprintf` 不上屏

- XNU 的 `boot_args.Video` 由 DarwinBoot 正确填充（`CopyMem (Args->Video, Video, ...)`）。
- 但 `PE_init_printf()` 在 `arm_init()` 中排在 `arm_vm_init()` **之后**，
  而内核早期阶段（`arm_init` 前段）控制台尚未初始化 → 早期 `kprintf` 无输出。
- 屏幕上看到的 `CurrentEL 1 SCTLR_EL1 ...` 来自 Apple 预链接代码的另一条输出路径。

**这是当前推进的最大障碍**：没有可用的早期日志通道，故障定位只能靠拍照 + OCR。

### 5.5 已建立的调试基础设施与「早期日志」的三个尝试

| 尝试 | 结果 |
| --- | --- |
| 阶段闸门 `unixnu-hold=N`（已埋 1–22 号点） | ✅ 能精确把 CPU 停在指定阶段 |
| 直写帧缓冲（`boot_args.Video` + `ml_io_map_wcomb`） | ⚠️ 屏幕无横幅 |
| 物理地址直写（`ml_phys_write_word`，不需要映射） | ⚠️ 屏幕无变化 → 说明内核那边拿到的帧缓冲信息很可能为 0 |
| 早期打开控制台（`PE_init_platform()` 后即 `PE_create_console()` + `PE_init_printf()`，`unixnu-earlycon=1`） | ❌ 屏幕无任何新输出（启动参数已用 `mtype` 校验过确实传入） |
| panic 时先打 40 个换行 / 控制台下移 14 行 | ❌ 屏幕无变化（可见的 panic 文本来自预链接的 Apple 组件） |

**当前采用的两条通道（均已改为不依赖任何映射，待实机验证）**：

1. **帧缓冲直写**
   - DarwinBoot 把 `{magic "OEDIVXNU", base, stride, width, height, depth}` 写到固定物理地址
     `0xA7F00000`（FD 之后、载荷之前的空闲窗口）；
   - 内核用 `ml_phys_read_double_64` 读回，再用 `ml_phys_write_word` 按物理地址写像素
     （`ml_phys_write_data` 内部会走 `phystokv` 或内核 copy window，不需要自己建映射）。
   - 用途：阶段横幅（`UNIXNU STAGE n`）与 panic 原因大字（`PANIC (unixnu banner):`）。
2. **IMEM 阶段标记**
   - 内核在阶段闸门处把 `{magic "NKRM", stage}` 物理写入 `0x14680F00`；
   - 下次启动由 UEFI 驱动 `HoujiRamDiskDxe` 读回并把菜单标题改写成 `STAGE xxxx reached`。
   - 注意：IMEM 在**热复位**（看门狗）后保留，在**整机断电**后会被清空。

若两条通道都失败，则本平台的早期日志只能靠外接 UART，或移植社区移植作者的
`houji_debug_append` 内存环形缓冲 + DarwinBoot 回读设施。

### 5.7 关于「物理写帧缓冲」为何在早期可能无效

`ml_phys_write_data()` 的实现在内核里有两条路径：

```c
#if defined(__ARM_COHERENT_IO__) || __ARM_PTE_PHYSMAP__
	if (pmap_valid_address(paddr)) { addr = phystokv(paddr); use_copy_window = false; }
#endif
	if (use_copy_window) { ... 走内核 copy window ... }
```

两条路径都依赖 pmap / VirtualMemory 已经建立起来。因此：

* **在 `arm_init()` 早期阶段（闸门 1–16）**：copy window 还不存在，物理写很可能静默失败；
* **在 panic 时刻、`machine_startup` 之后（闸门 6/7 及正常启动）**：pmap 已就绪，物理写应当有效。

据此，判断通道是否成立的**首选测试是 `boot-houji-hold-none.img`（panic 屏）与 `hold-7`**，
而不是 `hold-16`。这也解释了之前 `hold-16` 上「没有任何变化」的观察。

### 5.8 可用的闸门点

| 编号 | 位置 |
| --- | --- |
| 1 | `arm_init()` 入口 |
| 2 / 3 | `PE_init_platform()` 前 / 后 |
| 4 / 5 | `ml_parse_cpu_topology()` 前 / 后 |
| 6 / 7 | `machine_conf()` 后 / `machine_startup()` 入口 |
| 8–14 | `thread_bootstrap` / `cpu_bootstrap` / `rtclock_early_init` / `kernel_startup_bootstrap` / `timer_call_init` / `cpu_init` / `processor_bootstrap` 之前 |
| 15 / 16 | `nanoseconds_to_absolutetime` 前 / `arm_vm_init()` 前 |
| 20 / 21 / 22 | `arm_vm_init()` 内（boot_args 处理完 / tte 页初始化后 / 返回前） |

---

## 6. 后续路线（按价值排序）

1. **验证两条输出通道**（下一步唯一要做的事）
   - `artifacts/boot-houji-hold-16.img`：停在 `arm_vm_init()` 之前，屏幕上应出现 `UNIXNU STAGE 16`；
   - `artifacts/boot-houji-hold-none.img`：正常启动，panic 时屏幕上部应出现
     `PANIC (unixnu banner):` 与 panic 原因原文。
   两条通道的代码都已改为**物理地址直写**，不再依赖 `boot_args` 布局、`ml_io_map` 或控制台初始化。
2. **定位 `0x17C10xxx` 的访问者**：通道确认后，把闸门点埋到 `arm_vm_init` 与 IOKit 初始化内部
   逐点夹逼；已排除串口路径（`PI3_UART` 需要 ADT 里的 `gpio`/`aux` 节点，我们都没有）。
3. **补齐 ADT**：按 Apple 的 device tree 约定补 `arm-io` 的 `device_type`、`intc` 的
   `interrupt-controller`/`master`、以及 `timer` 节点，让 GIC/时钟初始化走正规路径。
4. **并入 houji 移植的内核 overlay**：`sweet_early.c`、`HoujiSmpGic.{h,inc}`、`SWEET.h` 等，
   移植作者用这套代码在真机上做到过 CPU0 注册与 SGI1 自检。
5. **iOS userland**：需要存储/显示/HID 驱动、`kits/sheng` 的 payload 流程、
   以及 `seed-data-grow`/`--skip-setup` 等 macOS-only 步骤。

### 6.1 恢复工作（resume kit）

```bash
# 1) 环境
wsl -d Ubuntu            # Apple 工具链装在 /opt/unixnu-linux
cd ~/unixnu/UniXNU

# 2) 改内核后重建（约 12 分钟：bootstrap pass + 正式 pass）
bash /mnt/d/13u/tmp/hold-park.sh          # 例：改完 debug.c / arm_init.c 后这样重建

# 3) 打镜像（约 3 分钟，含 payload + PayloadIdentity.h + 固件 + bootimg）
bash /mnt/d/13u/tmp/hold-image.sh 16      # 带 unixnu-hold=16
bash /mnt/d/13u/tmp/hold-image.sh none    # 不带闸门

# 4) 实机
fastboot boot D:\13u\port\artifacts\boot-houji-hold-16.img
```

关键脚本都在 `D:\13u\tmp\`（构建/打包）与 `D:\13u\port\tools\`（部署/CI/测试）。

---

## 7. 安全说明

* 所有实机操作都是 `fastboot boot`（临时启动），**没有执行过** `flash` / `erase` / `format`；
  分区与数据未改动。
* 若启动后卡死，长按电源键 10 秒即可回 Android。
* 本包不含 Apple 二进制（IPSW、kernelcache、trust cache）与厂商固件，需自行准备/按需取回。
* `tools/.gh_token` 是本次 CI 用的 GitHub token，**请尽快吊销**。
