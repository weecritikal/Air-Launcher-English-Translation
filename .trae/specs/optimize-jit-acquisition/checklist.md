# Checklist

## isJITEnabled 简化
- [x] `isJITEnabled` 仅检查 CS_DEBUGGED（return (flags & CS_DEBUGGED) != 0），不再调用 JIT26IsLikelyDebuggerKeepAttached
- [x] `JIT26IsLikelyDebuggerKeepAttached` 函数已从 utils.m 移除
- [x] `JIT26IsLikelyDebuggerKeepAttached` 声明已从 utils.h 移除
- [x] `DeviceRequiresTXMWorkaround` 函数已从 utils.m 移除
- [x] `DeviceRequiresTXMWorkaround` 声明已从 utils.h 移除
- [x] LauncherPreferencesViewController.m 第 1033 行注释已更新（不再引用 DeviceRequiresTXMWorkaround）

## DeviceCanCreateRXMap 安全性
- [x] mmap 失败时返回 NO 并 NSLog，不再 assert 崩溃

## TXM 检测重构
- [x] `DeviceHasTXMReal` 函数已移除
- [x] `DeviceHasTXM` 的 __exported 薄包装已移除
- [x] 新增 `DeviceLikelyHasTXMFromChipID` static 函数，含 MGGetSInt64Answer NULL 检查
- [x] `DeviceHasTXM` 先尝试现代 Preboot 路径，再回退 /private/preboot 枚举，最后回退 ChipID
- [x] 上述实现与 catsruledogs 第 203-260 行 diff 一致

## DeviceGetJITFlags + DeviceNeedsDebugJITMapping
- [x] `DeviceGetJITFlags` 使用 os_unfair_lock 替代 dispatch_once
- [x] `DeviceGetJITFlags` 调用 `DeviceHasTXM()` 而非 `DeviceHasTXMReal()`
- [x] 新增 `DeviceNeedsDebugJITMapping` 返回 `DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED)`
- [x] utils.h 新增 `DeviceNeedsDebugJITMapping` 声明
- [x] 上述实现与 catsruledogs 第 262-307 行 diff 一致

## init_bypassDyldLibValidation 选路修复
- [x] switch 精确位掩码已替换为 if/else 分离位检查
- [x] `HAS_TXM && (IS_IOS_26 || FORCE_MIRRORED)` → redirectFunctionMirrored
- [x] `FORCE_MIRRORED` → redirectFunctionHWBreakpoint
- [x] else → redirectFunctionDirect
- [x] 上述实现与 catsruledogs 第 231-252 行 diff 一致

## invokeAfterJITEnabled 脚本条件
- [x] 脚本发送条件从 `DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)` 改为 `DeviceNeedsDebugJITMapping()`
- [x] 版本列表不清空行为保留（非 JIT 逻辑）

## 无遗留引用
- [x] 全仓库 grep `JIT26IsLikelyDebuggerKeepAttached` 无结果（spec 文档除外）
- [x] 全仓库 grep `DeviceRequiresTXMWorkaround` 无结果（spec 文档除外）
- [x] 全仓库 grep `DeviceHasTXMReal` 无结果（spec 文档除外）
- [x] TrollStore / SideStore / JailBroken / LiveContainer 适配代码未被修改
