<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Air Icon" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Air</h1>
<p align="center"><sub>Amethyst iOS Remastered</sub></p>

<div align="center">
  <img alt="Build Status" src="https://github.com/weecritikal/Air-Launcher-English-Translation/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/weecritikal/Air-Launcher-English-Translation/total?label=Downloads&style=flat">
  <img alt="Release" src="https://img.shields.io/github/v/release/weecritikal/Air-Launcher-English-Translation?style=flat">
  <img alt="License" src="https://img.shields.io/github/license/weecritikal/Air-Launcher-English-Translation?style=flat">
  <img alt="Last Commit" src="https://img.shields.io/github/last-commit/weecritikal/Air-Launcher-English-Translation?color=c78aff&label=last%20commit&style=flat">
</div>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README_CN.md">Chinese</a>
</p>

---

Air — a Minecraft: Java Edition launcher for iOS and iPadOS. A complete English translation of Amethyst iOS Remastered (a fork of 
AngelAuraMC's Amethyst iOS by herbrine8403) 

Thanks to both AngelAuraMC and herbrine8403 for their work in their original repositories, I truly admire your work, all credit to you two. I only intend to build on top of it.

-weecritikal
---

## Table of Contents

- [Changes in This Fork](#changes-in-this-fork)
- [Core Features](#core-features)
- [Credits](#credits)
- [Quick Start](#quick-start)
  - [Device Requirements](#device-requirements)
  - [Sideload Preparation](#sideload-preparation)
  - [Installation](#installation)
  - [Enabling JIT](#enabling-jit)
- [Contributors](#contributors)
- [Third-Party Components](#third-party-components)
- [Sponsor](#sponsor)

## Changes in This Fork

This is a fork of [herbrine8403/Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered), based on the 5.0.0 Preview and synced with upstream through `6514be6`. It adds a complete English translation and fixes several issues that kept the launcher from working. Only substantive changes are listed here -- routine build and tooling fixes are left out.

### Translation

- **Complete English localization.** Upstream ships Mandarin-only. Every user-facing string is now English: 1,313 hardcoded string literals across the Objective-C sources, 19 localization keys that were absent from `en.lproj`, and the in-source comments. The Chinese localization is untouched and still selectable.

### Fixes

- **The game no longer closes the instant you press Play.** The launcher probes for JIT support by calling a function that executes a `brk` debugger breakpoint. With no debugger attached that raises `SIGTRAP` and the kernel kills the process -- so the app died at exactly the point it meant to report "JIT unavailable". The probe now installs a `SIGTRAP` handler and returns a negative result instead of terminating. Upstream builds are affected by this too.
- **Heap allocation degrades instead of failing.** If the configured memory allocation cannot be mapped, the launcher now retries at successively smaller sizes down to 512 MB rather than giving up, so a too-ambitious setting no longer blocks startup outright.
- **Modloader direct install works again.** Forge and NeoForge builds are listed from one download source but the installer jar was fetched from another, so choosing a build the second source does not publish failed with a bare `not found (404)` that named no URL. The jar is now tried across every mirror in turn, with the same request headers the version list uses, and a failure reports which sources were tried.
- **CurseForge browsing matches the website.** The Modpacks, Mods, Shaders, Resource Packs, Data Packs and Worlds tabs returned effectively arbitrary results with no download counts. They now request CurseForge's own sort order and surface author, download count, categories and last-updated date.
- **The CurseForge API key reaches the build.** The key was silently dropped during configuration, leaving CurseForge unavailable at runtime. It is now supplied through a repository secret and compiled in.
- **`.zip` and `.mcpack` files can be imported.** Both were unselectable in the iOS document picker; the picker now declares the archive types these files actually resolve to.
- **Microsoft sign-in no longer stacks dialogs.** Each authentication step raised its own alert, producing a queue of roughly ten prompts to dismiss. Progress steps now update in place.

### Build

- **Apple code signing.** Builds can be signed in CI with your own Apple developer identity and provisioning profile. This is what preserves the `increased-memory-limit` and `extended-virtual-addressing` entitlements, which re-signing with an unprivileged profile strips -- and without them large modpacks cannot map a heap.
- **Configurable bundle identifier.** Set the `BUNDLE_ID` repository variable to an App ID registered to your own team, rather than editing tracked sources.

## Core Features

- **Modern UI Redesign** -- The interface has been deeply refined for a contemporary, polished visual style.
- **Resource Management & Downloads** -- Browse, enable, disable, and delete mods, shader packs, resource packs, and other assets, with integrated Modrinth and CurseForge download support.
- **Modpack Import** -- Import ZIP-format modpacks directly from the launcher interface.
- **Smart Download Sources** -- Switch between Mojang Official, BMCLAPI mirror, and other sources on the fly for optimal download speeds.
- **Complete Chinese Localization** -- Fully translated interface with native-quality Chinese language support.
- **Unrestricted Accounts** -- Local accounts, demo mode, and third-party authentication all supported; no Microsoft account required to download and play.
- **Multi-Account** -- Seamlessly switch between Microsoft, local, and third-party authentication accounts.
- **Auto Renderer Selection** -- Automatically chooses the optimal rendering backend (including MobileGlues, MoltenVK, and more) when set to Auto.
- **Auto JVM Selection** -- Automatically selects the correct JVM version (Java 8, 17, 21, or 25) based on the game version.
- **Minecraft 26.X Support** -- Experimental support for Minecraft 26.x.
- **Custom Mouse Pointer** -- Customize the virtual mouse pointer skin in settings.
- **Custom News URL** -- Configure a custom news feed URL for the launcher home screen.
- **TouchController Support** -- Communicates with the TouchController mod via both UDP local proxy and XCFramework, delivering full touchscreen control on iOS.
- **AI Integration** -- (In development) The goal is to enable AI to fully manage the launcher, including resource downloads and instance management.
- **Custom App Icons** -- (In development)

... and much more to explore!

> [!NOTE]
> There are no plans to port this remastered version to Android. The Android ecosystem already has excellent launchers such as [Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher), [Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher), and ShardLauncher. For the official Android version, visit [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android).

## Quick Start

For complete documentation, refer to the [Amethyst Official Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) or the [Bilibili tutorial](https://b23.tv/KyxZr12). Below is a condensed guide.

### Device Requirements

| Tier | iOS Version | Supported Devices |
|------|-------------|-------------------|
| **Minimum** | iOS 14.0+ | iPhone 6s+, iPad 5th gen+, iPad Air 2+, iPad mini 4+, all iPad Pro, iPod touch 7th gen |
| **Recommended** | iOS 14.5+ | iPhone XS+ (excl. XR/SE 2nd gen), iPad 10th gen+, iPad Air 4th gen+, iPad mini 6th gen+, iPad Pro (excl. 9.7-inch) |

> [!CAUTION]
> iOS 14.0--14.4.2 has known critical compatibility issues. **Upgrading to iOS 14.5 or later is strongly recommended.** iOS 17.x and 18.x are supported but require a companion computer for initial JIT configuration (see the [Official JIT Guide](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)). iOS 26.x is installable but has not undergone dedicated adaptation; expect unpredictable behavior.

### Sideload Preparation

Prioritize tools that support permanent signing and automatic JIT enablement:

1. **TrollStore** *(Recommended)* -- Permanent signing, automatic JIT, increased memory limits. Compatible with select iOS versions. [Download from official repo](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(Alternative)* -- Requires periodic re-signing; initial setup needs a computer and Wi-Fi. Only compatible with **development certificates** (must include `com.apple.security.get-task-allow` entitlement for JIT). Distribution certificate signing services are not supported.

> [!WARNING]
> Only download sideloading tools and IPA files from official or trusted sources. The author is not responsible for device issues caused by unofficial software. Jailbroken devices support permanent signing, but daily-driver jailbreaking is not recommended.

### Installation

<details>
<summary><b>Official Release (TrollStore)</b></summary>

1. Download the `.tipa` package from [Releases](https://github.com/weecritikal/Air-Launcher-English-Translation/releases).
2. Open the file with TrollStore via the system share menu to complete installation.
</details>

<details>
<summary><b>Official Release (AltStore / SideStore)</b></summary>

1. Download the `.ipa` package from [Releases](https://github.com/weecritikal/Air-Launcher-English-Translation/releases).
2. Import the IPA into your sideloading tool following its standard installation procedure.
</details>

<details>
<summary><b>Nightly Builds (Development Testing)</b></summary>

> [!CAUTION]
> Nightly builds may contain critical bugs including crashes and startup failures. Use only for development and testing purposes.

1. Navigate to the [GitHub Actions](https://github.com/weecritikal/Air-Launcher-English-Translation/actions) page and download the latest IPA artifact.
2. Import the IPA into your sideloading tool (AltStore, SideStore, etc.) to install.
</details>

### Enabling JIT

JIT (Just-In-Time compilation) is essential for smooth gameplay. Choose the approach that matches your environment:

| Tool | External Device | Wi-Fi Required | Auto-Enable | Notes |
|------|:---:|:---:|:---:|-------|
| TrollStore | No | No | Yes | Preferred; no additional action needed |
| AltStore | Yes | Yes | Yes | Requires AltServer running on local network |
| SideStore | First time only | First time only | No | Device/network-free after initial setup |
| StikDebug | First time only | First time only | Yes | Device/network-free after initial setup |
| Jitterbug | Yes (without VPN) | Yes | No | Manual trigger required |
| Jailbroken | No | No | Yes | System-level automatic support |

## Credits

This launcher stands on three projects. [PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher) by Tran Hoang Khanh Duy is the foundation every Minecraft: Java launcher on iOS is built from. [AngelAuraMC](https://github.com/AngelAuraMC) rebuilt it as Amethyst iOS, and [herbrine8403](https://github.com/herbrine8403) remastered that as [Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered), which this repository forks.

> Thanks to both AngelAuraMC and herbrine8403 for their work in their original repositories, I truly admire your work, all credit to you two. I only intend to build on top of it.
>
> -- weecritikal

This fork is distributed under the GPL-3.0, the same licence it inherits.

## Contributors

- [@yitenchen123](https://github.com/yitenchen123) -- Project Maintainer
- [@EternityQwQ](https://github.com/EternityQwQ) -- Add Metal Universal Mod support, allowing the launcher to use Metal for rendering Minecraft
- [@LanRhyme](https://github.com/LanRhyme) -- ShardLauncher author; iOS 26 compatibility and logging improvements
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod download integration, TouchController optimizations, and two-finger long-press keyboard trigger
- [@Li2548](https://github.com/Li2548) -- Upstream synchronization

## Third-Party Components

| Component | Purpose | License | Source |
|-----------|---------|---------|--------|
| Caciocavallo | AWT runtime framework | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | Code annotation support | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | Core functionality adaptation | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL-to-GLES translation | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D graphics library | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal-to-OpenGL ES translation | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan-to-Metal translation | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | Cross-platform 3D audio | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java runtime (8/17/21/25) | GPL-2.0 | [Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java game development library | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 compatibility layer | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI slider control | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | Dynamic library rebinding | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan shader compilation | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | File management utilities | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore integration | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP archive handling | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | Library verification bypass | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | Third-party renderer | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core-to-ES wrapper | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | Third-party authentication | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

Additional thanks to [MCHeads](https://mc-heads.net) for Minecraft avatar services, [Modrinth](https://modrinth.com) for mod distribution, and [BMCLAPI](https://bmclapidoc.bangbang93.com) for Minecraft download mirroring.

## Sponsor

If you find this project valuable, consider supporting development through [Ko-Fi](https://ko-fi.com/herbrine8403), [Afdian](https://afdian.com/a/herbrine8403), or [WeChat Reward Code](donate.png).

## Star History

<a href="https://www.star-history.com/?type=date&repos=herbrine8403%2FAmethyst-iOS-MyRemastered">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&theme=dark&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
 </picture>
</a>
