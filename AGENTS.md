# Angel Aura Amethyst (iOS) Remastered - Project Overview

## Introduction

This is a Minecraft launcher optimized for iOS/iPadOS, developed on top of the official Amethyst project. It aims to provide a smoother gameplay experience, better localization support and enhanced features such as mod management, shader management, modpack importing and smart download source switching.

## Technology Stack and Architecture

*   **Primary languages**: Objective-C (the native iOS components), Java (the game core logic), C/C++ (some low-level libraries and the graphics adaptation layer)
*   **Build system**: the project is built with `Makefile` and `CMake`.
*   **Build environment**: GitHub Actions (macOS 14), Xcode 15.4/16, the iPhoneOS 17.5 SDK
*   **Minimum supported OS**: iOS 14.0
*   **Core dependencies**:
    *   **Java runtime**: includes iOS ports of OpenJDK 8, 17 and 21.
    *   **Graphics adaptation**: MetalANGLE (Metal to OpenGL ES), GL4ES (OpenGL ES to OpenGL), Mesa 3D, MobileGlues.
    *   **AWT support**: Caciocavallo (a pure Java implementation of Java AWT).
    *   **Others**: LWJGL (the Java game development library), OpenAL (audio), TouchController (touchscreen control support).

## Directory Structure

*   `Natives/`: all native iOS code (Objective-C, C, C++), including the UI controllers, the app entry point and the Java virtual machine launcher.
    *   `authenticator/`: the account authentication module, supporting Microsoft, local and third-party accounts.
    *   `customcontrols/`: the custom control layout module.
    *   `external/`: third-party dependencies (AFNetworking, AltKit, fishhook, MobileGlues and so on).
    *   `input/`: the input handling module (gamepad, gyroscope, keyboard).
    *   `installer/`: the installer module (Fabric, Forge, modpacks).
*   `JavaApp/`: the Java-side application logic and library files.
*   `TouchController/`: the TouchController static library, providing touchscreen control communication support.
*   `depends/`: build-time dependencies, such as the Java runtime environment.
*   `artifacts/`: the build output directory, containing the final `.ipa` package and intermediate files.

## Building and Running

### Build environment requirements

*   The build must run on macOS (macOS 14 is recommended).
*   Xcode 15.4 or newer.
*   The Xcode command line tools.
*   CMake, ldid, wget, JDK 8.
*   On iOS 14.5 and above, installing with TrollStore is recommended for the best experience.

### Build commands

1.  **Set up the environment**: make sure every dependency is installed.
2.  **Run the build**:
    ```bash
    make all
    ```
    This runs the following steps in order:
    *   `make dep_mg`: build the MobileGlues dependency.
    *   `make native`: build the native libraries.
    *   `make java`: build the Java application.
    *   `make jre`: download and extract the iOS JRE.
    *   `make assets`: compile the app resources (icons and so on).
    *   `make payload`: assemble the app bundle (AngelAuraAmethyst.app).
    *   `make package`: produce the final `.ipa` or `.tipa` package.

3.  **Optional build parameters**:
    *   `RELEASE=1`: build the Release configuration.
    *   `SLIMMED=1`: build the slim variant (without the Java runtime).
    *   `TROLLSTORE_JIT_ENT=1`: produce a TrollStore-specific TIPA package.
    *   `PLATFORM=<value>`: choose the target platform (2=iOS, 3=tvOS, 7=iOS Simulator, 11=visionOS and so on).

4.  **Deployment**:
    *   On a jailbroken device: `make deploy` (must be run on the device).
    *   Through TrollStore: install the generated `.tipa` file directly.
    *   Through AltStore/SideStore: install the generated `.ipa` file.

Note that the build runs on the macOS 14 machines provided by GitHub Actions, not on this device.

### Launch flow

1.  App launch (`main.m`): environment checks, log redirection, directory setup and other initialization work.
2.  UI initialization (`AppDelegate.m`, `SceneDelegate.m`): sets up the main window and the initial view controller.
3.  JVM startup (`JavaLauncher.m`): configures the Java environment variables and JVM arguments, then loads and starts the Java virtual machine.
4.  Java application run: the JVM loads the `PojavLauncher` class, which runs Minecraft's launch logic.

## Development Conventions

*   **Code style**: Objective-C follows Apple's coding conventions, and the C/C++ code style is kept consistent throughout the project.
*   **Branch management**: Git is used for version control, and feature work happens on `feature/` branches.
*   **Localization**: text must be localized properly in ongoing development.
*   **Git commit convention**:

    ```
    <type>(<scope>): <subject>
    ```

    **type (required)**
    Describes the category of the commit. Only the following identifiers are allowed:
    - feat: a new feature
    - fix/to: a bug fix, whether the bug was found by QA or by the developers themselves
      - fix: produces a diff and fixes the problem outright. Suitable when a single commit fixes the problem
      - to: produces a diff without fixing the problem outright. Suitable across several commits; use fix for the commit that finally fixes it
    - docs: documentation
    - style: formatting (changes that do not affect how the code runs)
    - refactor: refactoring (code changes that neither add a feature nor fix a bug)
    - perf: optimization work, such as improving performance or the user experience
    - test: adding tests
    - chore: changes to the build process or the supporting tooling
    - revert: rolling back to a previous version
    - merge: merging code
    - sync: syncing a bug fix from the mainline or a branch

    **scope (optional)**
    scope describes the area a commit affects, such as the data layer, the control layer or the view layer; it varies from project to project.
    If your change affects more than one scope, you can use * instead.

    **subject (required)**
    subject is a short description of the purpose of the commit, no longer than 50 characters.
    It should not end with a period or other punctuation.

    **Examples**:
    - fix(DAO): user query is missing the username attribute
    - feat(Controller): implement the user query interface

    **Why**:
    - It makes the commit history easy to trace, so it is clear what happened
    - Constraining the commit message means each commit is made deliberately, rather than dumping every kind of change into one git commit
    - Only a formatted commit message can be used to generate a changelog automatically

## Key Feature Modules

*   **Mod management** (`ModsManagerViewController`, `ModService`): view, enable/disable and delete mods, with a search box for finding a mod quickly.
*   **Mod downloading** (`ModVersionViewController`): download mods through the Modrinth API, with a choice of versions.
*   **Shader management** (`ShadersManagerViewController`, `ShaderService`): view, enable/disable and delete shader packs.
*   **Shader downloading** (`ShaderVersionViewController`): download shader packs through the Modrinth API, with a choice of versions.
*   **Modpack importing** (`ModpackImportViewController`, `ModpackImportService`): import modpacks in ZIP format.
*   **Account system** (`authenticator/`): supports Microsoft accounts, local accounts, demo accounts and third-party authenticated accounts.
*   **Custom controls** (`customcontrols/`): lets the user customize the in-game control layout.
*   **Preferences** (`PLPreferences`, `PLProfiles`): manages user settings and game profiles, with a card-style settings layout.
*   **Custom icons** (`CustomIconManager`): supports custom app icons (work in progress).
*   **Background wallpaper** (`BackgroundManager`): supports a custom launcher background wallpaper.
*   **TouchController support** (`TouchControllerBridge`): communicates with the TouchController mod through a local UDP proxy, bringing touchscreen controls to iOS users.

## GitHub Actions Workflows

The project uses GitHub Actions for automated builds:

*   **development.yml**: the main build workflow, triggered by pushes to branches other than l10n_main and by pull requests.
*   **development_speedup.yml**: the fast build workflow.

Build artifacts:
*   `org.angelauramc.amethyst-ios.ipa`: the standard IPA package
*   `org.angelauramc.amethyst-ios-trollstore.tipa`: the TrollStore-specific package
*   `AngelAuraAmethyst.dSYM`: the debug symbol file

## Additional Notes

1.  After every source change, push the change to the GitHub remote branch so the project is built for testing.
2.  If network problems occur while pushing to GitHub, remind the user to turn off their network proxy.
3.  This project is built with Xcode 15.4/16 and the iPhoneOS 17.5 SDK, and the minimum supported OS is iOS 14.0.
4.  Use the `herbrine8403` username and the `weishixvn@outlook.com` email address for git commits.
5.  The project supports building for several platforms - iOS, tvOS, the iOS Simulator and visionOS - selected with the `PLATFORM` parameter.
6.  When the renderer is set to Auto, a suitable renderer is chosen automatically, including MobileGlues.
