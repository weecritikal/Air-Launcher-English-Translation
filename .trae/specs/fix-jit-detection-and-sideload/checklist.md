# Checklist

## isJITEnabled 修复验证
- [x] `Natives/utils.m` 的 `isJITEnabled` 函数不再包含 sysctl KERN_PROC / P_TRACED 检查路径
- [x] `isJITEnabled` 函数逻辑与上游 `/tmp/amethyst-upstream/Natives/utils.m` 第 26-42 行完全一致
- [x] `isJITEnabled` 在 LiveContainer 环境（P_TRACED 被置位但 JIT 未启用）返回 NO
- [x] `isJITEnabled` 在 CS_DEBUGGED 置位且非 iOS 26+ TXM 设备时返回 YES
- [x] `isJITEnabled` 在 CS_DEBUGGED 置位且 iOS 26+ TXM 设备时调用 JIT26IsLikelyDebuggerKeepAttached

## Entitlements 修复验证
- [x] `entitlements.sideload.xml` 不包含 `com.apple.private.local.sandboxed-jit`
- [x] `entitlements.sideload.xml` 包含 `jb.pmap_cs.custom_trust`（值为 `PMAP_CS_APP_STORE`）
- [x] `entitlements.sideload.xml` 内容与上游一致（除 application-identifier 的 bundle ID）
- [x] `entitlements.trollstore.xml` 保持不变（仍包含 `com.apple.private.security.no-sandbox`）

## TrollStore 检测修复验证
- [x] `Natives/LauncherNavigationController.m` 中 `hasTrollStoreJIT` 使用 `getEntitlementValue(@"jb.pmap_cs.custom_trust")`
- [x] `Natives/LauncherRightPanelViewController.m` 中 `hasTrollStoreJIT` 使用 `getEntitlementValue(@"jb.pmap_cs.custom_trust")`
- [x] `Natives/DownloadViewController.m` 中 `hasTrollStoreJIT` 使用 `getEntitlementValue(@"jb.pmap_cs.custom_trust")`
- [x] 全仓库不再有 `com.apple.private.local.sandboxed-jit` 的引用（除注释外）

## LiveContainer 崩溃修复验证
- [x] `Natives/main.m` 的 `uncaughtExceptionHandler` 在 `usleep(10000)` 之后调用 `handle_fatal_exit(SIGABRT)`
- [x] `Natives/main.m` 的 `init_checkForJailbreak` 检测 `/systemhook.dylib`（通过 `strstr`）
- [x] `Natives/main_hook.m` 的 `handle_fatal_exit` 检查 `[PLLogOutputView handleExitCode:code]` 返回值
- [x] `Natives/main_hook.m` 的 `hooked_dlopen` 在不需要 Zink rebind 的分支使用 `__attribute__((musttail))`
- [x] `Natives/main_hook.m` 的 `hooked_dlopen` 在分支前统一调用 `PLPatchMachOPlatformForFile(path)`（包含 26PPL 路径，对齐上游）

## SideStore JIT 启用修复验证
- [x] `Natives/LauncherNavigationController.m` 的 `invokeAfterJITEnabled` 包含 stikjit URL scheme 分支（iOS 17.4+）
- [x] `Natives/LauncherNavigationController.m` 的 `invokeAfterJITEnabled` 包含 sidestore URL scheme fallback 分支
- [x] `Natives/LauncherRightPanelViewController.m` 的 `invokeAfterJITEnabled` 包含相同 fallback 分支
- [x] `Natives/DownloadViewController.m` 的 `invokeAfterJITEnabled` 包含相同 fallback 分支

## 特殊安装方式适配验证
- [x] TrollStore 安装：`entitlements.trollstore.xml` 包含 `com.apple.private.security.no-sandbox`，应用可自行启用 JIT
- [x] SideStore 安装：`entitlements.sideload.xml` 不包含私有 entitlement，安装不失败
- [x] SideStore JIT：通过 `sidestore://sidejit-enable` 或 `stikjit://enable-jit` URL scheme 启用
- [x] 越狱安装：`init_checkForJailbreak` 检测 substrated、pspawn_payload、systemhook、CS_PLATFORM_BINARY、/Applications
- [x] LiveContainer：检测 `/systemhook.dylib` 后 isJailbroken=YES，isJITEnabled 不因 P_TRACED 误报
