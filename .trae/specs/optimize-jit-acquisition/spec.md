# JIT 获取逻辑优化（对齐 catsruledogs）Spec

## Why

用户反映使用 NB助手 等 JIT 工具启用 JIT 后，启动器无法正确检测到 JIT 已启用，或启动游戏时卡死在 `dlopen(libjli)`。深度对比 catsruledogs/Amethyst-iOS-25 后发现，本地仓库的 JIT 获取逻辑存在两处致命缺陷：

1. **`init_bypassDyldLibValidation` 的 switch 精确位掩码选路缺陷**：iOS 26 + TXM 设备（如 iPhone 17）通过调试器型 JIT 工具启用 JIT 后，`FORCE_MIRRORED` 不置位，switch 落入 `default` 选择 `redirectFunctionDirect`，其 `vm_protect(RX)` 被 iOS 26 拒绝 → SIGBUS 被吞 → 卡死在 `dlopen(libjli)`。
2. **`isJITEnabled` 的 `getppid()!=1` 额外门槛**：NB助手 等工具启用 JIT 后若分离调试器，`getppid()` 变回 1，`isJITEnabled` 持续返回 NO → 永久卡在"等待 JIT"弹窗。

catsruledogs 已修复这两个问题：`isJITEnabled` 仅依赖 `CS_DEBUGGED`；`init_bypassDyldLibValidation` 改用 if/else 分离位检查。同时还修复了 `DeviceCanCreateRXMap` 的 assert 崩溃、`DeviceHasTXMReal` 的 NULL 解引用风险、以及 iOS 26.6+/27 的现代 Preboot 路径。

## What Changes

### 1. 简化 `isJITEnabled`（utils.m）— 照搬 catsruledogs

- **移除** `CS_DEBUGGED` 置位后对 `JIT26IsLikelyDebuggerKeepAttached()` 的额外检查
- 简化为仅 `return (flags & CS_DEBUGGED) != 0;`
- **移除** `JIT26IsLikelyDebuggerKeepAttached` 函数（catsruledogs 中不存在）
- **移除** `DeviceRequiresTXMWorkaround` 函数（deprecated，catsruledogs 已删除，本地仅注释引用）

### 2. 修复 `DeviceCanCreateRXMap` assert 崩溃（utils.m）— 照搬 catsruledogs

- **替换** `assert(map != MAP_FAILED)` 为优雅的错误处理：返回 NO 并 NSLog

### 3. 重构 TXM 检测（utils.m）— 照搬 catsruledogs

- **移除** `DeviceHasTXMReal` 函数
- **移除** `DeviceHasTXM` 的 `__exported` 薄包装（仅定义未被外部调用）
- **新增** `DeviceLikelyHasTXMFromChipID` static 函数：基于 MobileGestalt ChipID 精确判断芯片代际，含 `MGGetSInt64Answer` NULL 检查
- **重写** `DeviceHasTXM`：先尝试现代 Preboot 路径 `/System/Volumes/Preboot/boot/...`，再回退 `/private/preboot` 枚举，最后回退 `DeviceLikelyHasTXMFromChipID`

### 4. 重写 `DeviceGetJITFlags`（utils.m）— 照搬 catsruledogs

- **替换** `dispatch_once` 为 `os_unfair_lock`（支持真正的可重入刷新）
- 调用 `DeviceHasTXM()` 代替 `DeviceHasTXMReal()`

### 5. 新增 `DeviceNeedsDebugJITMapping`（utils.m + utils.h）— 照搬 catsruledogs

- 返回 `DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED)`

### 6. 更新 utils.h 声明 — 照搬 catsruledogs

- **移除** `JIT26IsLikelyDebuggerKeepAttached` 声明
- **移除** `DeviceRequiresTXMWorkaround` 声明
- **新增** `DeviceNeedsDebugJITMapping` 声明

### 7. 修复 `init_bypassDyldLibValidation` 选路缺陷（dyld_bypass_validation.m）— 照搬 catsruledogs

- **替换** switch 精确位掩码为 if/else 分离位检查：
  - `HAS_TXM && (IS_IOS_26 || FORCE_MIRRORED)` → `redirectFunctionMirrored`
  - `FORCE_MIRRORED` → `redirectFunctionHWBreakpoint`
  - else → `redirectFunctionDirect`

### 8. 更新 `invokeAfterJITEnabled` 脚本发送条件（LauncherNavigationController.m）

- **替换** `DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)` 为 `DeviceNeedsDebugJITMapping()`
- **保留** 本地版本列表不清空的优化（非 JIT 逻辑，属 UI 改进）

## Impact

- Affected specs: `fix-jit-detection-and-sideload`（前序 spec，已完成）
- Affected code:
  - `Natives/utils.m`（isJITEnabled、JIT26IsLikelyDebuggerKeepAttached、DeviceRequiresTXMWorkaround、DeviceCanCreateRXMap、DeviceHasTXMReal、DeviceHasTXM、DeviceGetJITFlags、新增 DeviceNeedsDebugJITMapping + DeviceLikelyHasTXMFromChipID）
  - `Natives/utils.h`（声明增删）
  - `Natives/dyld_bypass_validation.m`（init_bypassDyldLibValidation 选路逻辑）
  - `Natives/LauncherNavigationController.m`（invokeAfterJITEnabled 脚本条件）
  - `Natives/LauncherPreferencesViewController.m`（仅注释引用 DeviceRequiresTXMWorkaround，需更新注释）

## ADDED Requirements

### Requirement: 调试器型 JIT 工具兼容

系统 SHALL 在 iOS 26 + TXM 设备上正确处理通过 NB助手 / StikDebug 等调试器型 JIT 工具启用的 JIT，不出现 `dlopen(libjli)` 卡死。

#### Scenario: NB助手 启用 JIT 后启动游戏

- **WHEN** 用户通过 NB助手 启用 JIT（设置 CS_DEBUGGED，不设置 FORCE_MIRRORED），随后启动游戏
- **THEN** `init_bypassDyldLibValidation` 选择 `redirectFunctionMirrored`（因 HAS_TXM && IS_IOS_26），不触发 `vm_protect(RX)` 被拒，`dlopen(libjli)` 正常完成

#### Scenario: JIT 工具启用后分离调试器

- **WHEN** JIT 工具启用 JIT 后分离（getppid 变回 1），但 CS_DEBUGGED 仍置位
- **THEN** `isJITEnabled` 返回 YES（仅检查 CS_DEBUGGED），不卡在"等待 JIT"弹窗

### Requirement: TXM 固件检测健壮性

系统 SHALL 在 iOS 26.6+/27（`/private/preboot` 不可读）时通过现代 Preboot 路径或 ChipID 启发式正确检测 TXM。

#### Scenario: iOS 26.6+ 设备检测 TXM

- **WHEN** 设备运行 iOS 26.6+，`/private/preboot` 不可读
- **THEN** `DeviceHasTXM` 先尝试 `/System/Volumes/Preboot/boot/.../Ap,TrustedExecutionMonitor.img4`，失败再回退 `DeviceLikelyHasTXMFromChipID`（含 MGGetSInt64Answer NULL 检查），不崩溃

### Requirement: RX 映射探测安全性

系统 SHALL 在 `DeviceCanCreateRXMap` 的 mmap 失败时优雅返回 NO，不崩溃。

#### Scenario: mmap 失败

- **WHEN** `mmap` 返回 MAP_FAILED（内存紧张等）
- **THEN** 函数返回 NO 并 NSLog 错误，不触发 assert 崩溃

## MODIFIED Requirements

### Requirement: isJITEnabled 检测

`isJITEnabled(BOOL checkCSFlags)` 仅检查 `CS_DEBUGGED` 标志位（以及 `checkCSFlags==NO` 时的 dynamic-codesigning entitlement / jailbreak 快速路径），不再额外要求 `getppid()!=1`。

## REMOVED Requirements

### Requirement: JIT26IsLikelyDebuggerKeepAttached

**Reason**: 该函数基于 `getppid()!=1` 判断调试器是否持续附加，但 NB助手 等工具启用 JIT 后会分离调试器，导致误判。catsruledogs 已移除此检查，仅依赖 CS_DEBUGGED 即可覆盖所有合法 JIT 场景。

**Migration**: `isJITEnabled` 不再调用此函数。无其他调用方。

### Requirement: DeviceRequiresTXMWorkaround

**Reason**: 该函数已标记 deprecated，仅被 LauncherPreferencesViewController.m 的注释引用（无实际调用）。catsruledogs 已删除。

**Migration**: 注释更新为引用 `DeviceHasJITFlags(JIT_FLAG_HAS_TXM)`。

### Requirement: DeviceHasTXMReal

**Reason**: catsruledogs 将 TXM 检测合并为单一 `DeviceHasTXM`（含现代 Preboot 路径 + ChipID 回退），不再拆分 Real/wrapper。

**Migration**: `DeviceGetJITFlags` 改为调用 `DeviceHasTXM()`。
