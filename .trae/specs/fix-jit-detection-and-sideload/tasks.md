# Tasks

## Phase 1: 核心检测逻辑修复（无依赖，可并行）

- [x] Task 1: 修复 isJITEnabled 函数，移除 P_TRACED sysctl 路径
  - [x] SubTask 1.1: 编辑 `Natives/utils.m` 中的 `isJITEnabled` 函数，移除 "Path 2"（sysctl KERN_PROC 检查 P_TRACED），完全对齐上游实现
  - [x] SubTask 1.2: 移除不再需要的 `#import <sys/sysctl.h>`（如果 isJITEnabled 是唯一使用者）
  - [x] SubTask 1.3: 验证修改后的函数逻辑与上游 `/tmp/amethyst-upstream/Natives/utils.m` 第 26-42 行完全一致

- [x] Task 2: 修复 entitlements.sideload.xml，恢复上游 TrollStore 检测 entitlement
  - [x] SubTask 2.1: 移除 `com.apple.private.local.sandboxed-jit` entitlement
  - [x] SubTask 2.2: 恢复 `jb.pmap_cs.custom_trust` entitlement（值为 `PMAP_CS_APP_STORE`）
  - [x] SubTask 2.3: 验证文件内容与上游 `/tmp/amethyst-upstream/entitlements.sideload.xml` 一致（除了 bundle ID）

- [x] Task 3: 修复 TrollStore 检测逻辑，恢复 jb.pmap_cs.custom_trust
  - [x] SubTask 3.1: 编辑 `Natives/LauncherNavigationController.m`，将 `getEntitlementValue(@"com.apple.private.local.sandboxed-jit")` 改为 `getEntitlementValue(@"jb.pmap_cs.custom_trust")`
  - [x] SubTask 3.2: 编辑 `Natives/LauncherRightPanelViewController.m`，同样修改
  - [x] SubTask 3.3: 编辑 `Natives/DownloadViewController.m`，同样修改

## Phase 2: LiveContainer 崩溃修复（依赖 Phase 1 完成）

- [x] Task 4: 恢复 main.m 中的 LiveContainer 兼容性
  - [x] SubTask 4.1: 在 `uncaughtExceptionHandler` 中恢复 `handle_fatal_exit(SIGABRT)` 调用（在 `usleep(10000)` 之后）
  - [x] SubTask 4.2: 在 `init_checkForJailbreak` 的 posix_spawn hook 检测循环中恢复 `/systemhook.dylib` 检测（`strstr(_dyld_get_image_name(i),"/systemhook.dylib") != NULL`）

- [x] Task 5: 恢复 main_hook.m 中的崩溃处理与尾调用优化
  - [x] SubTask 5.1: 恢复 `handle_fatal_exit` 中对 `[PLLogOutputView handleExitCode:code]` 返回值的检查：`if (![PLLogOutputView handleExitCode:code]) { return; }`
  - [x] SubTask 5.2: 在 `hooked_dlopen` 中，对不需要 Zink stride fix rebind 的分支恢复 `__attribute__((musttail))` 尾调用优化
    - 注意：`shouldUseDyldBypass26PPL` 和 `else`（orig_dlopen）分支可以恢复 musttail
    - `shouldUseDyldBypass`（LiveContainer sys_dlopen）分支也可以恢复 musttail
    - 仅当后续需要 `rebindZinkStrideFixForNewImage` 时才不能用 musttail

## Phase 3: SideStore JIT 启用路径修复（依赖 Phase 1 Task 3 完成）

- [x] Task 6: 恢复 invokeAfterJITEnabled 中的 SideStore/stikjit URL scheme fallback
  - [x] SubTask 6.1: 编辑 `Natives/LauncherNavigationController.m` 的 `invokeAfterJITEnabled`，在 `debug_skip_wait_jit` 检查之后恢复 stikjit 和 sidestore URL scheme 分支：
    ```objc
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if(DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }
    ```
  - [x] SubTask 6.2: 检查 `Natives/LauncherRightPanelViewController.m` 的 `invokeAfterJITEnabled`，确保也有相同的 fallback 分支（如果没有则添加）
  - [x] SubTask 6.3: 检查 `Natives/DownloadViewController.m` 的 `invokeAfterJITEnabled`，确保也有相同的 fallback 分支（如果没有则添加）

## Phase 4: 验证

- [x] Task 7: 全面对比验证
  - [x] SubTask 7.1: 对比 `Natives/utils.m` 的 `isJITEnabled` 函数与上游一致
  - [x] SubTask 7.2: 对比 `entitlements.sideload.xml` 与上游一致（除 bundle ID）
  - [x] SubTask 7.3: 对比 `Natives/main.m` 的 `uncaughtExceptionHandler` 和 `init_checkForJailbreak` 与上游一致
  - [x] SubTask 7.4: 对比 `Natives/main_hook.m` 的 `handle_fatal_exit` 和 `hooked_dlopen` 与上游一致
  - [x] SubTask 7.5: 对比三个 VC 文件的 `invokeAfterJITEnabled` 与上游一致
  - [x] SubTask 7.6: 确认所有 `com.apple.private.local.sandboxed-jit` 引用已改为 `jb.pmap_cs.custom_trust`

# Task Dependencies

- Task 1, 2, 3 可并行（无依赖）
- Task 4, 5 依赖 Phase 1 完成（确保 isJITEnabled 已修复）
- Task 6 依赖 Task 3 完成（确保 hasTrollStoreJIT 检测已修复）
- Task 7 依赖所有前置任务完成
