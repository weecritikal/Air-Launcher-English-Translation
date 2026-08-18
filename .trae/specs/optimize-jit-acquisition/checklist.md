# Checklist

## Simplifying isJITEnabled
- [x] `isJITEnabled` only checks CS_DEBUGGED (return (flags & CS_DEBUGGED) != 0) and no longer calls JIT26IsLikelyDebuggerKeepAttached
- [x] The `JIT26IsLikelyDebuggerKeepAttached` function has been removed from utils.m
- [x] The `JIT26IsLikelyDebuggerKeepAttached` declaration has been removed from utils.h
- [x] The `DeviceRequiresTXMWorkaround` function has been removed from utils.m
- [x] The `DeviceRequiresTXMWorkaround` declaration has been removed from utils.h
- [x] The comment on line 1033 of LauncherPreferencesViewController.m has been updated (it no longer references DeviceRequiresTXMWorkaround)

## DeviceCanCreateRXMap safety
- [x] On mmap failure it returns NO and logs with NSLog, instead of crashing on an assert

## TXM detection rework
- [x] The `DeviceHasTXMReal` function has been removed
- [x] The `__exported` thin wrapper around `DeviceHasTXM` has been removed
- [x] The static `DeviceLikelyHasTXMFromChipID` function has been added, including the MGGetSInt64Answer NULL check
- [x] `DeviceHasTXM` tries the modern Preboot path first, then falls back to enumerating /private/preboot, and finally falls back to the ChipID heuristic
- [x] The implementation above matches the catsruledogs diff on lines 203-260

## DeviceGetJITFlags + DeviceNeedsDebugJITMapping
- [x] `DeviceGetJITFlags` uses os_unfair_lock instead of dispatch_once
- [x] `DeviceGetJITFlags` calls `DeviceHasTXM()` rather than `DeviceHasTXMReal()`
- [x] The new `DeviceNeedsDebugJITMapping` returns `DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED)`
- [x] The `DeviceNeedsDebugJITMapping` declaration has been added to utils.h
- [x] The implementation above matches the catsruledogs diff on lines 262-307

## init_bypassDyldLibValidation dispatch fix
- [x] The exact-bitmask switch has been replaced with separate if/else bit checks
- [x] `HAS_TXM && (IS_IOS_26 || FORCE_MIRRORED)` → redirectFunctionMirrored
- [x] `FORCE_MIRRORED` → redirectFunctionHWBreakpoint
- [x] else → redirectFunctionDirect
- [x] The implementation above matches the catsruledogs diff on lines 231-252

## invokeAfterJITEnabled script condition
- [x] The script-sending condition was changed from `DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)` to `DeviceNeedsDebugJITMapping()`
- [x] The behavior of not clearing the version list is preserved (it is not JIT logic)

## No leftover references
- [x] Grepping the whole repository for `JIT26IsLikelyDebuggerKeepAttached` returns nothing (outside the spec documents)
- [x] Grepping the whole repository for `DeviceRequiresTXMWorkaround` returns nothing (outside the spec documents)
- [x] Grepping the whole repository for `DeviceHasTXMReal` returns nothing (outside the spec documents)
- [x] The TrollStore / SideStore / JailBroken / LiveContainer support code was not modified
