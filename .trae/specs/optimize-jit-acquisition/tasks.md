# Tasks

- [x] Task 1: 简化 isJITEnabled 并移除 JIT26IsLikelyDebuggerKeepAttached（utils.m + utils.h）
  - [ ] SubTask 1.1: 简化 isJITEnabled 函数体为仅检查 CS_DEBUGGED（照搬 catsruledogs 第 27-35 行）
  - [ ] SubTask 1.2: 移除 JIT26IsLikelyDebuggerKeepAttached 函数实现（utils.m 第 196-199 行）
  - [ ] SubTask 1.3: 移除 utils.h 中 JIT26IsLikelyDebuggerKeepAttached 声明（第 78 行）
  - [ ] SubTask 1.4: 移除 DeviceRequiresTXMWorkaround 函数实现（utils.m 第 201-219 行）
  - [ ] SubTask 1.5: 移除 utils.h 中 DeviceRequiresTXMWorkaround 声明（第 82 行）
  - [ ] SubTask 1.6: 更新 LauncherPreferencesViewController.m 第 1033 行注释，将 DeviceRequiresTXMWorkaround 引用改为 DeviceHasJITFlags

- [x] Task 2: 修复 DeviceCanCreateRXMap assert 崩溃（utils.m）
  - [ ] SubTask 2.1: 替换 assert(map != MAP_FAILED) 为 if (map == MAP_FAILED) { NSLog(...); return NO; }（照搬 catsruledogs 第 190-201 行）

- [x] Task 3: 重构 TXM 检测为 catsruledogs 结构（utils.m）
  - [ ] SubTask 3.1: 移除 DeviceHasTXMReal 函数（utils.m 第 239-268 行）
  - [ ] SubTask 3.2: 移除 DeviceHasTXM 的 __exported 薄包装（utils.m 第 271-273 行）
  - [ ] SubTask 3.3: 新增 DeviceLikelyHasTXMFromChipID static 函数（照搬 catsruledogs 第 203-226 行，含 MGGetSInt64Answer NULL 检查）
  - [ ] SubTask 3.4: 重写 DeviceHasTXM：现代 Preboot 路径 + /private/preboot 枚举 + ChipID 回退（照搬 catsruledogs 第 228-260 行）

- [x] Task 4: 重写 DeviceGetJITFlags 并新增 DeviceNeedsDebugJITMapping（utils.m + utils.h）
  - [ ] SubTask 4.1: 替换 dispatch_once 为 os_unfair_lock，调用 DeviceHasTXM()（照搬 catsruledogs 第 262-296 行）
  - [ ] SubTask 4.2: 新增 DeviceNeedsDebugJITMapping 函数（照搬 catsruledogs 第 302-307 行）
  - [ ] SubTask 4.3: 在 utils.h 新增 DeviceNeedsDebugJITMapping 声明

- [x] Task 5: 修复 init_bypassDyldLibValidation 选路缺陷（dyld_bypass_validation.m）
  - [ ] SubTask 5.1: 替换 switch 精确位掩码为 if/else 分离位检查（照搬 catsruledogs 第 231-252 行）

- [x] Task 6: 更新 invokeAfterJITEnabled 脚本发送条件（LauncherNavigationController.m）
  - [ ] SubTask 6.1: 将 DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) 替换为 DeviceNeedsDebugJITMapping()（第 681 行）
  - [ ] SubTask 6.2: 保留版本列表不清空（非 JIT 逻辑）

- [x] Task 7: 验证与构建
  - [ ] SubTask 7.1: 确认所有修改与 catsruledogs 对应代码 diff 一致（仅保留版本列表不清空差异）
  - [ ] SubTask 7.2: 检查无遗留的 JIT26IsLikelyDebuggerKeepAttached / DeviceRequiresTXMWorkaround / DeviceHasTXMReal 引用

# Task Dependencies
- Task 2、3 可与 Task 1 并行（不同函数，无依赖）
- Task 4 依赖 Task 3（DeviceGetJITFlags 调用 DeviceHasTXM）
- Task 5、6 独立，可并行
- Task 7 依赖全部前序任务完成
