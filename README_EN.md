# My Angel Aura Amethyst (iOS) Remastered
[![Development Build Status](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main)](.github/workflows/development.yml)

**Note: This ReadMe document is translated by AI, and I don't plan to translate it manually because I don't think this project will be popular abroad.**

## 🌟 Remastered Core Highlights
Optimized and adapted based on the official Amethyst, focusing on iOS/iPadOS experience enhancement, core features include:
- **Mod Management**: Recreated Mod management functionality from other launchers, supporting viewing basic Mod information, one-click disabling/deleting Mods
- **Smart Download Source Switching**: Automatically identifies network environment and optimally selects between Mojang official source and BMCLAPI for more stable downloads
- **Complete Chinese Localization**: Fully translated interface, more suitable for Chinese users awa
- **Account Restrictions Removed**: Supports local accounts and demo accounts (Demo Mode) to directly download games without logging into Microsoft account or Test account
- **Multi-Account Login**: Compatible with Microsoft accounts, local accounts, and third-party verification servers (under development, coming soon)

**Note: Some features (such as Mod management) do not have an English translation.**

> ⚠️ Note: There are no plans to reset the Android version (there are too many excellent Android modifications), if you need the official Android code, please go to [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android).


## 🚀 Quick Start Guide
For complete installation and setup documentation, please refer to [Amethyst Official Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios), or check my [Bilibili tutorial video](https://b23.tv/KyxZr12). The following are simplified steps:


### 📱 Device Requirements
| Type | System Version Requirements | Supported Device List |
|------------|-----------------------------|------------------------------------------------------------------------------|
| **Minimum** | iOS 14.0 and above | iPhone 6s+/iPad 5th gen+/iPad Air 2+/iPad mini 4+/All iPad Pro/iPod touch 7th gen |
| **Recommended** | iOS 14.5 and above (better experience) | iPhone XS+ (excluding XR/SE 2nd gen), iPad 10th gen+/Air 4th gen+/mini 6th gen+/iPad Pro (excluding 9.7 inch) |

> ⚠️ Key Reminder: Serious compatibility issues exist with iOS 14.0~14.4.2, **strongly recommended to upgrade to iOS 14.5+**; Supports iOS 17.x/iOS 18.x, but requires computer assistance for configuration, see [Official JIT Guide](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit) for details.


### 🔧 Sideload Preparation
Prioritize tools that support "permanent signing + automatic JIT", recommended by priority:
1. **TrollStore** (Preferred): Supports permanent signing, automatic JIT enablement, and memory limit increase, compatible with some iOS versions, download from [Official Repository](https://github.com/opa334/TrollStore)
2. **AltStore/SideStore** (Alternative): Requires periodic re-signing, initial setup requires computer/Wi-Fi; does not support "distribution certificate signing service", only compatible with "development certificate" (must include `com.apple.security.get-task-allow` permission to enable JIT)

> ⚠️ Security Tip: Only download sideloading tools and IPA from official/trusted sources; I am not responsible for device issues caused by unofficial software; Jailbroken devices support permanent signing, but daily jailbreaking is not recommended.


### 📥 Installation Steps
#### 1. Official Release (TrollStore Channel)
1. Go to [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) to download the TIPA installation package
2. Through the system "share menu", choose to open with TrollStore to automatically complete installation

#### 2. Official Release (AltStore/SideStore Channel)
The installation package for this channel is under development and will be updated immediately upon release.

#### 3. Nightly Test Version (Daily Build)
> 🔴 Risk Warning: Test versions may contain serious bugs such as crashes and failure to start, only for development testing!
1. Go to [GitHub Actions page](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) to download the latest IPA test package
2. Import IPA in sideloading tools (AltStore/SideStore, etc.) to complete installation


### ⚡ Enable JIT (Required!)
JIT (Just-In-Time) is crucial for smooth game operation. iOS needs to enable it through the following tools, choose according to your environment:

| Tool | Requires External Device | Requires Wi-Fi | Auto Enable | Notes |
|--------------|------------|----------|----------|--------------------------|
| TrollStore | ❌ | ❌ | ✅ | Preferred, no additional action needed |
| AltStore | ✅ | ✅ | ✅ | Requires local network to run AltServer |
| SideStore | ✅ (First time) | ✅ (First time) | ❌ | Subsequent use requires no device/network |
| StikDebug | ✅ (First time) | ✅ (First time) | ✅ | Subsequent use requires no device/network |
| Jitterbug | ✅ (When VPN unavailable) | ✅ | ❌ | Requires manual trigger |
| Jailbroken Device | ❌ | ❌ | ✅ | System-level automatic support |


## 👥 Core Contributors (Official)
Amethyst's stability is inseparable from the community team's contributions,致敬 to the following main developers:
- @crystall1nedev - [Project Lead & iOS Port Core]
- @khanhduytran0 - [iOS Port Core Developer]
- @artdeell, @Mathius-Boulay, @zhuowei, @jkcoxson, @Diatrus
> Tribute to legendary artDev


## 🙏 Special Thanks
- @LanRhyme - [ShardLauncher iOS author, providing ideas and code]

  👉 More works: [Bilibili Homepage](https://b23.tv/3rmAFc2) | [MC Mobile Log Analyzer](https://github.com/LanRhyme/Web-MinecraftLogAnalyzer) | [ShardLauncher](https://github.com/LanRhyme/ShardLauncher-iOS)


## 📦 Third-Party Components and Licenses
| Component Name | Purpose | License Type | Project Link |
|------------------------|--------------------------|--------------------------|--------------------------------------------------------------------------|
| Caciocavallo | Basic runtime framework | GNU GPLv2 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | Code annotation support | BSD 3-Clause | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | Core functionality adaptation | Apache 2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | Graphics rendering adaptation | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D Graphics Library | 3D graphics rendering core | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal graphics interface adaptation | BSD 2.0 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan interface translation | Apache 2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | Audio processing | LGPLv2 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java runtime environment | GNU GPLv2 | [Official Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java game interface | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 compatibility layer | License Unknown | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI sliding control | Apache 2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | Dynamic library adaptation | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan shader compilation | Apache 2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | File management utility class | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore adaptation support | - | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | Unzipping tool | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | Library verification bypass tool | - | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
> Additional thanks: [MCHeads](https://mc-heads.net) for providing Minecraft avatar services
