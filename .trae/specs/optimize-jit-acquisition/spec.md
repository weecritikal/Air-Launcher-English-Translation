# Spec: Optimizing JIT acquisition (aligning with catsruledogs)

## Why

Users reported that after enabling JIT with a JIT tool such as NB Assistant, the launcher failed to detect that JIT was enabled, or the game froze at `dlopen(libjli)` on launch. A detailed comparison with catsruledogs/Amethyst-iOS-25 revealed two fatal flaws in this repository's JIT acquisition logic:

1. **The exact-bitmask switch dispatch flaw in `init_bypassDyldLibValidation`**: on an iOS 26 + TXM device (such as an iPhone 17), enabling JIT with a debugger-style JIT tool leaves `FORCE_MIRRORED` unset, so the switch falls through to `default` and picks `redirectFunctionDirect`, whose `vm_protect(RX)` is rejected by iOS 26 → the SIGBUS is swallowed → it freezes at `dlopen(libjli)`.
2. **The extra `getppid()!=1` condition in `isJITEnabled`**: when a tool such as NB Assistant detaches the debugger after enabling JIT, `getppid()` goes back to 1 and `isJITEnabled` keeps returning NO → the "waiting for JIT" dialog never goes away.

catsruledogs has fixed both problems: `isJITEnabled` now relies solely on `CS_DEBUGGED`, and `init_bypassDyldLibValidation` uses separate if/else bit checks. It also fixed the assert crash in `DeviceCanCreateRXMap`, the NULL dereference risk in `DeviceHasTXMReal`, and the modern Preboot path on iOS 26.6+/27.

## What Changes

### 1. Simplify `isJITEnabled` (utils.m) - taken from catsruledogs

- **Remove** the extra `JIT26IsLikelyDebuggerKeepAttached()` check performed once `CS_DEBUGGED` is set
- Simplify it to just `return (flags & CS_DEBUGGED) != 0;`
- **Remove** the `JIT26IsLikelyDebuggerKeepAttached` function (it does not exist in catsruledogs)
- **Remove** the `DeviceRequiresTXMWorkaround` function (deprecated; catsruledogs deleted it, and this repository only references it in a comment)

### 2. Fix the `DeviceCanCreateRXMap` assert crash (utils.m) - taken from catsruledogs

- **Replace** `assert(map != MAP_FAILED)` with graceful error handling: return NO and NSLog

### 3. Rework TXM detection (utils.m) - taken from catsruledogs

- **Remove** the `DeviceHasTXMReal` function
- **Remove** the `__exported` thin wrapper around `DeviceHasTXM` (it was defined but never called externally)
- **Add** a static `DeviceLikelyHasTXMFromChipID` function that determines the chip generation precisely from the MobileGestalt ChipID, including a `MGGetSInt64Answer` NULL check
- **Rewrite** `DeviceHasTXM`: try the modern Preboot path `/System/Volumes/Preboot/boot/...` first, then fall back to enumerating `/private/preboot`, and finally fall back to `DeviceLikelyHasTXMFromChipID`

### 4. Rewrite `DeviceGetJITFlags` (utils.m) - taken from catsruledogs

- **Replace** `dispatch_once` with `os_unfair_lock` (so a genuine re-entrant refresh is possible)
- Call `DeviceHasTXM()` instead of `DeviceHasTXMReal()`

### 5. Add `DeviceNeedsDebugJITMapping` (utils.m + utils.h) - taken from catsruledogs

- Returns `DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED)`

### 6. Update the declarations in utils.h - taken from catsruledogs

- **Remove** the `JIT26IsLikelyDebuggerKeepAttached` declaration
- **Remove** the `DeviceRequiresTXMWorkaround` declaration
- **Add** the `DeviceNeedsDebugJITMapping` declaration

### 7. Fix the dispatch flaw in `init_bypassDyldLibValidation` (dyld_bypass_validation.m) - taken from catsruledogs

- **Replace** the exact-bitmask switch with separate if/else bit checks:
  - `HAS_TXM && (IS_IOS_26 || FORCE_MIRRORED)` → `redirectFunctionMirrored`
  - `FORCE_MIRRORED` → `redirectFunctionHWBreakpoint`
  - else → `redirectFunctionDirect`

### 8. Update the script-sending condition in `invokeAfterJITEnabled` (LauncherNavigationController.m)

- **Replace** `DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)` with `DeviceNeedsDebugJITMapping()`
- **Keep** the optimization that does not clear the local version list (this is not JIT logic, it is a UI improvement)

## Impact

- Affected specs: `fix-jit-detection-and-sideload` (the preceding spec, already completed)
- Affected code:
  - `Natives/utils.m` (isJITEnabled, JIT26IsLikelyDebuggerKeepAttached, DeviceRequiresTXMWorkaround, DeviceCanCreateRXMap, DeviceHasTXMReal, DeviceHasTXM, DeviceGetJITFlags, plus the new DeviceNeedsDebugJITMapping and DeviceLikelyHasTXMFromChipID)
  - `Natives/utils.h` (declarations added and removed)
  - `Natives/dyld_bypass_validation.m` (the dispatch logic in init_bypassDyldLibValidation)
  - `Natives/LauncherNavigationController.m` (the invokeAfterJITEnabled script condition)
  - `Natives/LauncherPreferencesViewController.m` (only a comment references DeviceRequiresTXMWorkaround, so the comment needs updating)

## ADDED Requirements

### Requirement: compatibility with debugger-style JIT tools

The system SHALL correctly handle JIT enabled by a debugger-style JIT tool such as NB Assistant / StikDebug on an iOS 26 + TXM device, without freezing at `dlopen(libjli)`.

#### Scenario: launching the game after NB Assistant enables JIT

- **WHEN** the user enables JIT through NB Assistant (which sets CS_DEBUGGED but not FORCE_MIRRORED) and then launches the game
- **THEN** `init_bypassDyldLibValidation` selects `redirectFunctionMirrored` (because HAS_TXM && IS_IOS_26), `vm_protect(RX)` is never rejected, and `dlopen(libjli)` completes normally

#### Scenario: the JIT tool detaches the debugger after enabling JIT

- **WHEN** the JIT tool detaches after enabling JIT (getppid goes back to 1) but CS_DEBUGGED is still set
- **THEN** `isJITEnabled` returns YES (it only checks CS_DEBUGGED) and the "waiting for JIT" dialog does not get stuck

### Requirement: robust TXM firmware detection

The system SHALL detect TXM correctly on iOS 26.6+/27 (where `/private/preboot` is unreadable), either through the modern Preboot path or through the ChipID heuristic.

#### Scenario: detecting TXM on an iOS 26.6+ device

- **WHEN** the device runs iOS 26.6+ and `/private/preboot` is unreadable
- **THEN** `DeviceHasTXM` first tries `/System/Volumes/Preboot/boot/.../Ap,TrustedExecutionMonitor.img4`, and on failure falls back to `DeviceLikelyHasTXMFromChipID` (which includes the MGGetSInt64Answer NULL check), without crashing

### Requirement: safe RX mapping probing

The system SHALL return NO gracefully when the mmap in `DeviceCanCreateRXMap` fails, without crashing.

#### Scenario: mmap fails

- **WHEN** `mmap` returns MAP_FAILED (for example under memory pressure)
- **THEN** the function returns NO and logs the error with NSLog, without triggering an assert crash

## MODIFIED Requirements

### Requirement: isJITEnabled detection

`isJITEnabled(BOOL checkCSFlags)` only checks the `CS_DEBUGGED` flag (plus the dynamic-codesigning entitlement / jailbreak fast paths when `checkCSFlags==NO`), and no longer additionally requires `getppid()!=1`.

## REMOVED Requirements

### Requirement: JIT26IsLikelyDebuggerKeepAttached

**Reason**: this function used `getppid()!=1` to decide whether a debugger was still attached, but tools such as NB Assistant detach the debugger after enabling JIT, which made the check wrong. catsruledogs removed it, since CS_DEBUGGED alone covers every legitimate JIT scenario.

**Migration**: `isJITEnabled` no longer calls this function. There are no other callers.

### Requirement: DeviceRequiresTXMWorkaround

**Reason**: this function was already marked deprecated and was only referenced by a comment in LauncherPreferencesViewController.m (with no actual calls). catsruledogs deleted it.

**Migration**: the comment now references `DeviceHasJITFlags(JIT_FLAG_HAS_TXM)`.

### Requirement: DeviceHasTXMReal

**Reason**: catsruledogs merged TXM detection into a single `DeviceHasTXM` (with the modern Preboot path plus the ChipID fallback), rather than splitting it into a Real function and a wrapper.

**Migration**: `DeviceGetJITFlags` now calls `DeviceHasTXM()`.
