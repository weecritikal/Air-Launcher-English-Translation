# Tasks

- [x] Task 1: simplify isJITEnabled and remove JIT26IsLikelyDebuggerKeepAttached (utils.m + utils.h)
  - [ ] SubTask 1.1: simplify the body of isJITEnabled to only check CS_DEBUGGED (taken from catsruledogs lines 27-35)
  - [ ] SubTask 1.2: remove the JIT26IsLikelyDebuggerKeepAttached implementation (utils.m lines 196-199)
  - [ ] SubTask 1.3: remove the JIT26IsLikelyDebuggerKeepAttached declaration from utils.h (line 78)
  - [ ] SubTask 1.4: remove the DeviceRequiresTXMWorkaround implementation (utils.m lines 201-219)
  - [ ] SubTask 1.5: remove the DeviceRequiresTXMWorkaround declaration from utils.h (line 82)
  - [ ] SubTask 1.6: update the comment on line 1033 of LauncherPreferencesViewController.m, changing the DeviceRequiresTXMWorkaround reference to DeviceHasJITFlags

- [x] Task 2: fix the DeviceCanCreateRXMap assert crash (utils.m)
  - [ ] SubTask 2.1: replace assert(map != MAP_FAILED) with if (map == MAP_FAILED) { NSLog(...); return NO; } (taken from catsruledogs lines 190-201)

- [x] Task 3: rework TXM detection into the catsruledogs structure (utils.m)
  - [ ] SubTask 3.1: remove the DeviceHasTXMReal function (utils.m lines 239-268)
  - [ ] SubTask 3.2: remove the __exported thin wrapper around DeviceHasTXM (utils.m lines 271-273)
  - [ ] SubTask 3.3: add the static DeviceLikelyHasTXMFromChipID function (taken from catsruledogs lines 203-226, including the MGGetSInt64Answer NULL check)
  - [ ] SubTask 3.4: rewrite DeviceHasTXM: the modern Preboot path + enumerating /private/preboot + the ChipID fallback (taken from catsruledogs lines 228-260)

- [x] Task 4: rewrite DeviceGetJITFlags and add DeviceNeedsDebugJITMapping (utils.m + utils.h)
  - [ ] SubTask 4.1: replace dispatch_once with os_unfair_lock and call DeviceHasTXM() (taken from catsruledogs lines 262-296)
  - [ ] SubTask 4.2: add the DeviceNeedsDebugJITMapping function (taken from catsruledogs lines 302-307)
  - [ ] SubTask 4.3: add the DeviceNeedsDebugJITMapping declaration to utils.h

- [x] Task 5: fix the dispatch flaw in init_bypassDyldLibValidation (dyld_bypass_validation.m)
  - [ ] SubTask 5.1: replace the exact-bitmask switch with separate if/else bit checks (taken from catsruledogs lines 231-252)

- [x] Task 6: update the invokeAfterJITEnabled script-sending condition (LauncherNavigationController.m)
  - [ ] SubTask 6.1: replace DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) with DeviceNeedsDebugJITMapping() (line 681)
  - [ ] SubTask 6.2: keep the version list from being cleared (this is not JIT logic)

- [x] Task 7: verification and build
  - [ ] SubTask 7.1: confirm every change matches the corresponding catsruledogs code (with only the "do not clear the version list" difference kept)
  - [ ] SubTask 7.2: check that no references to JIT26IsLikelyDebuggerKeepAttached / DeviceRequiresTXMWorkaround / DeviceHasTXMReal remain

# Task Dependencies
- Tasks 2 and 3 can run in parallel with Task 1 (different functions, no dependency)
- Task 4 depends on Task 3 (DeviceGetJITFlags calls DeviceHasTXM)
- Tasks 5 and 6 are independent and can run in parallel
- Task 7 depends on every preceding task being complete
