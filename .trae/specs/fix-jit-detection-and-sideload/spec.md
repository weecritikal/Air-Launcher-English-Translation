# JIT 权限检测与多安装方式适配修复 Spec

## Why

启动器的 JIT 权限检测在多次"修复"后越修越糟，从最初的检测反转（有 JIT 显示未开启、无 JIT 显示已开启），恶化到 LiveContainer 进入启动器直接崩溃、SideStore 无法安装启动器。根因是之前的修复都是"症状修复"而非"根因修复"，每轮修复都引入了新的偏差。

通过深度对比上游仓库（AngelAuraMC/Amethyst-iOS）与我们的仓库，发现我们的仓库在以下方面偏离了上游设计，这些偏离直接导致了上述所有问题。

## What Changes

### 1. 移除 isJITEnabled 中的 P_TRACED sysctl 路径（utils.m）

- **移除** `utils.m` 中 `isJITEnabled` 函数的 "Path 2"（sysctl KERN_PROC 检查 P_TRACED 标志位）
- 该路径上游不存在，且会导致：
  - LiveContainer 环境下 P_TRACED 被置位 → 误返回 YES → 使用 JIT 指令（brk）时因无调试器附加而 SIGTRAP 崩溃
  - 绕过 iOS 26+ TXM 设备的调试器持续附加检查
- 对齐上游实现：仅依赖 CS_DEBUGGED + JIT26IsLikelyDebuggerKeepAttached

### 2. 修复 LiveContainer 崩溃链（main.m + main_hook.m）

- **恢复** `main.m` 中 `uncaughtExceptionHandler` 的 `handle_fatal_exit(SIGABRT)` 调用
- **恢复** `main.m` 中 `init_checkForJailbreak` 对 `/systemhook.dylib` 的检测（LiveContainer 使用此库）
- **恢复** `main_hook.m` 中 `handle_fatal_exit` 对 `[PLLogOutputView handleExitCode:code]` 返回值的检查
- **恢复** `main_hook.m` 中 `hooked_dlopen` 的 `__attribute__((musttail))` 尾调用优化（在不需要 Zink stride fix rebind 的分支中）

### 3. 修复 SideStore 安装失败与 JIT 启用失败（entitlements + URL scheme）

- **修复** `entitlements.sideload.xml`：移除 `com.apple.private.local.sandboxed-jit`（私有 entitlement，SideStore 无法授予），恢复上游的 `jb.pmap_cs.custom_trust`
- **恢复** `LauncherNavigationController.m`、`LauncherRightPanelViewController.m`、`DownloadViewController.m` 中 TrollStore 检测从 `com.apple.private.local.sandboxed-jit` 改回 `jb.pmap_cs.custom_trust`
- **恢复** `invokeAfterJITEnabled` 中被移除的 stikjit（`stikjit://enable-jit`）和 SideStore（`sidestore://sidejit-enable`）URL scheme fallback 分支

## Impact

- Affected specs: JIT 权限检测、TrollStore 适配、SideStore 适配、LiveContainer 兼容性、越狱设备适配
- Affected code:
  - `Natives/utils.m` - isJITEnabled 函数
  - `Natives/main.m` - uncaughtExceptionHandler、init_checkForJailbreak
  - `Natives/main_hook.m` - handle_fatal_exit、hooked_dlopen
  - `Natives/LauncherNavigationController.m` - invokeAfterJITEnabled
  - `Natives/LauncherRightPanelViewController.m` - invokeAfterJITEnabled
  - `Natives/DownloadViewController.m` - invokeAfterJITEnabled
  - `entitlements.sideload.xml` - SideStore 专用 entitlements

## ADDED Requirements

### Requirement: JIT 检测必须与上游完全对齐

系统 SHALL 使用与上游 AngelAuraMC/Amethyst-iOS 完全一致的 JIT 检测逻辑，不添加任何额外的检测路径。

#### Scenario: LiveContainer 环境下不误报 JIT
- **WHEN** 应用在 LiveContainer 中运行（P_TRACED 可能被置位但 JIT 未实际启用）
- **THEN** isJITEnabled 返回 NO，不尝试使用 JIT 指令（brk），避免 SIGTRAP 崩溃

#### Scenario: TrollStore 环境正确检测 JIT
- **WHEN** 应用通过 TrollStore 安装且 JIT 已通过 apple-magnifier 启用
- **THEN** CS_DEBUGGED 标志位置位，isJITEnabled 返回 YES

#### Scenario: SideStore 环境正确检测 JIT
- **WHEN** 应用通过 SideStore 安装且 JIT 已通过 sidestore://sidejit-enable 或 stikjit://enable-jit 启用
- **THEN** CS_DEBUGGED 标志位置位，isJITEnabled 返回 YES

#### Scenario: iOS 26+ TXM 设备检测
- **WHEN** 设备为 iOS 26+ 且有 TXM 固件
- **AND** CS_DEBUGGED 已置位
- **THEN** 额外检查 JIT26IsLikelyDebuggerKeepAttached（getppid != 1）确认调试器持续附加

### Requirement: LiveContainer 兼容性

系统 SHALL 正确识别 LiveContainer 环境并避免崩溃。

#### Scenario: LiveContainer 环境检测
- **WHEN** LiveContainer 加载 `/systemhook.dylib`
- **THEN** init_checkForJailbreak 返回 true，isJailbroken 标记为 YES

#### Scenario: 异常处理不丢失
- **WHEN** 发生未捕获异常（NSException）
- **THEN** uncaughtExceptionHandler 调用 handle_fatal_exit(SIGABRT) 进行崩溃处理

### Requirement: SideStore 安装与 JIT 启用

系统 SHALL 支持通过 SideStore 安装并启用 JIT。

#### Scenario: SideStore 正常安装
- **WHEN** 用户通过 SideStore 安装 IPA（使用 entitlements.sideload.xml）
- **THEN** entitlements 中不包含 `com.apple.private.local.sandboxed-jit`（私有 entitlement）
- **AND** entitlements 中包含 `jb.pmap_cs.custom_trust`（对齐上游）
- **AND** 安装成功完成

#### Scenario: SideStore JIT 启用
- **WHEN** 应用通过 SideStore 安装，JIT 未启用
- **THEN** hasTrollStoreJIT 检测 `jb.pmap_cs.custom_trust`（而非 `com.apple.private.local.sandboxed-jit`）
- **AND** 走 stikjit 或 sidestore URL scheme fallback 分支启用 JIT

#### Scenario: TrollStore JIT 启用
- **WHEN** 应用通过 TrollStore 安装，JIT 未启用
- **THEN** hasTrollStoreJIT 检测 `jb.pmap_cs.custom_trust` 返回 YES
- **AND** 走 apple-magnifier://enable-jit URL scheme 启用 JIT

## MODIFIED Requirements

### Requirement: isJITEnabled 检测逻辑

isJITEnabled 函数 SHALL 完全对齐上游 AngelAuraMC/Amethyst-iOS 的实现：

```objc
BOOL isJITEnabled(BOOL checkCSFlags) {
    if (!checkCSFlags && (getEntitlementValue(@"dynamic-codesigning") || isJailbroken)) {
        return YES;
    }
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    if ((flags & CS_DEBUGGED) == 0) {
        return NO;
    }
    if (!DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
        return YES;
    }
    return JIT26IsLikelyDebuggerKeepAttached();
}
```

不包含任何 P_TRACED sysctl 路径。

### Requirement: hooked_dlopen 尾调用优化

hooked_dlopen 在不需要后续处理（Zink stride fix rebind）的分支中 SHALL 使用 `__attribute__((musttail))` 尾调用，确保 LiveContainer 的 dlopen hook 不会因栈帧变化而失败。

### Requirement: handle_fatal_exit 崩溃处理

handle_fatal_exit SHALL 检查 `[PLLogOutputView handleExitCode:code]` 的返回值，仅在返回 YES 时继续崩溃处理流程。

## REMOVED Requirements

### Requirement: P_TRACED sysctl JIT 检测路径

**Reason**: 该路径上游不存在，且会导致 LiveContainer 崩溃（P_TRACED 误报 → brk 指令无调试器处理 → SIGTRAP）。上游通过 CS_DEBUGGED + JIT26IsLikelyDebuggerKeepAttached 已足够覆盖所有合法 JIT 场景。

**Migration**: 无需迁移，移除后所有合法 JIT 场景（TrollStore、SideStore、越狱、PT_TRACE_ME）均由 CS_DEBUGGED 覆盖。

### Requirement: com.apple.private.local.sandboxed-jit 用于 TrollStore 检测

**Reason**: 该 entitlement 是 Apple 私有 entitlement，SideStore 无法授予。将其放入 sideload entitlements 会导致 SideStore 安装失败；将其用于 TrollStore 检测会导致 SideStore 安装的应用误认为有 TrollStore JIT 能力，走错误的 URL scheme。

**Migration**: 恢复使用 `jb.pmap_cs.custom_trust` 检测 TrollStore，对齐上游。
