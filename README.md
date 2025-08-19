# 我的Angel Aura Amethyst (iOS)重制版
[![开发构建](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main)](.github/workflows/development.yml)

## 简介
我做的Angel Aura Amethyst重制版。
- 支持根据网络情况自动选择游戏下载源（Mojang和BMCLAPI）。
- 完整的中文本地化支持，更加易懂。（即将实现）
- 内置我自己制作的控件布局（仅适用于iPad）。（即将实现）
- 去除了原版Angel Aura Amethyst的账户限制，可在本地账户或演示账户（Demo Mode）下正常下载游戏。
- 支持通过 Microsoft 账号、本地账户和第三方验证服务器账户登录游戏。（即将实现）
- ……还有更多功能等你来探索！

本代码仓库包含 Amethyst 在 iOS 和 iPadOS 平台的移植代码。
我暂时不准备对Android版本进行重置（毕竟Android被官方优化的很好～）。如需 Android 官方版本的代码，请前往 [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)。

## Amethyst 快速上手
[Amethyst 官方维基](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) 提供了关于安装、设置和游戏体验的详细文档。或者参考[我的教程视频](https://b23.tv/KyxZr12)。若你希望快速完成安装，可参考以下基础步骤：

### 设备要求
最低配置要求：需使用搭载 **iOS 14.0 及以上系统**的以下任一设备：
- iPhone 6s 及后续机型
- iPad（第 5 代）及后续机型
- iPad Air（第 2 代）及后续机型
- iPad mini（第 4 代）及后续机型
- 所有型号的 iPad Pro
- iPod touch（第 7 代）

**注意：此改版在iOS 14.0～iOS 14.4.2系统有极为严重的兼容性问题，最好使用iOS 14.5及以上系统。**

推荐配置：建议使用搭载 **iOS 14.5 及以上系统**的以下任一设备：
- iPhone XS 及后续机型（不包含 iPhone XR 和 iPhone SE（第 2 代））
- iPad（第 10 代）及后续机型
- iPad Air（第 4 代）及后续机型
- iPad mini（第 6 代）及后续机型
- 所有型号的 iPad Pro（不包含 9.7 英寸版本）

推荐机型相比其他支持机型，能提供更流畅、更优质的游戏体验。
- 支持 iOS 17.x 和 iOS 18.x 系统，但需借助电脑操作。更多详情请查阅 [官方维基](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)。

### 侧载（sideload）准备工作（注：以下为官方教程）
Amethyst 支持多种侧载方式，推荐方案为：若你的 iOS 版本支持，优先安装 [TrollStore](https://github.com/opa334/TrollStore)。通过 TrollStore 安装可实现应用永久签名、自动启用 JIT（即时编译），并提升内存限制。

若你的设备不支持 TrollStore，可选择 [AltStore](https://altstore.io) 或 [SideStore](https://sidestore.io) 作为替代方案：
- 不支持不使用 UDID（设备唯一标识符）且采用分发证书（distribution certificate）的签名服务，因为这类服务无法提供 Amethyst 所需的权限。但如果你能获取到开发证书（Development certificate），由于其包含必要的权限（即 `com.apple.security.get-task-allow`，用于将调试器附加到运行中的进程以启用 JIT），则可使用开发证书进行签名。
  
- 请仅从可信来源安装侧载工具和 Amethyst。对于使用非官方软件可能造成的任何损失，我们不承担责任。
- 越狱（jailbreak）设备同样支持永久签名、自动启用 JIT 和提升内存限制，但不建议在日常使用的设备上进行越狱操作。

### 安装 Amethyst
#### 正式版（TrollStore 渠道）
1. 在 [Releases（发布页）](https://github.com/AngelAuraMC/Amethyst-iOS/releases) 中下载 Amethyst 的 IPA 安装包。
2. 通过分享菜单，在 TrollStore 中打开该安装包即可完成安装。

#### 正式版（AltStore/SideStore 可信来源渠道）
该渠道的正式版安装包即将上线，敬请期待。

####  nightly 测试版（每日构建版）
*此版本可能包含导致游戏无法运行的严重漏洞，请谨慎使用。*
1. 在 [Actions 标签页](https://github.com/AngelAuraMC/Amethyst-iOS/actions) 中下载 Amethyst 的 IPA 测试版安装包。
2. 在你的侧载工具中打开下载好的 IPA 文件，即可完成安装。

#### nightly 测试版（AltStore/SideStore 可信来源渠道）
该渠道的测试版安装包即将上线，敬请期待。

### 启用 JIT（即时编译）
Amethyst 需借助 **即时编译（just-in-time compilation，简称 JIT）** 技术，才能为用户提供流畅的游戏运行速度。在未对应用进行调试的情况下，iOS 系统不支持 JIT，因此需通过以下 workaround（临时解决方案）启用该功能。你可通过下方表格，根据自身设备和环境选择最优方案：

| 应用工具         | AltStore | SideStore | StikDebug | TrollStore | Jitterbug          | 已越狱设备 |
|------------------|----------|-----------|-----------|------------|--------------------|------------|
| 需外部设备支持   | 是       | 是（#）   | 是（#）   | 否         | 若 VPN 不可用则需  | 否         |
| 需 Wi-Fi 网络    | 是       | 是（#）   | 是（#）   | 否         | 是                | 否         |
| 自动启用         | 是（*）  | 否        | 是        | 是         | 否                | 是         |

（*）需在本地网络中运行 AltServer。
（#）仅首次设置时需要。

## 贡献者（官方）
Amethyst 功能强大且稳定性出色，这离不开社区成员的支持与贡献！以下是部分主要贡献者：

@crystall1nedev - 项目负责人、iOS 移植开发者  
@khanhduytran0 - iOS 移植开发者  
@artdeell  
@Mathius-Boulay  
@zhuowei  
@jkcoxson   
@Diatrus 

（致敬传奇artDev）

## 特别感谢
[@LanRhyme](https://github.com/LanRhyme) - 没有他的GitHub Actions 工作流配置文件提供的思路，就没有这个重制版Amethyst！

[他的B站主页](https://b23.tv/3rmAFc2)  [MC移动端日志分析器（主要项目）](https://github.com/LanRhyme/Web-MinecraftLogAnalyzer)

## 第三方组件及其许可证（官方）
- [Caciocavallo](https://github.com/PojavLauncherTeam/caciocavallo)：[GNU GPLv2 许可证](https://github.com/PojavLauncherTeam/caciocavallo/blob/master/LICENSE)。
- [jsr305](https://code.google.com/p/jsr-305)：[BSD 3-Clause 许可证](http://opensource.org/licenses/BSD-3-Clause)。
- [Boardwalk](https://github.com/zhuowei/Boardwalk)：[Apache 2.0 许可证](https://github.com/zhuowei/Boardwalk/blob/master/LICENSE) 
- [GL4ES](https://github.com/ptitSeb/gl4es)（作者：@lunixbochs @ptitSeb）：[MIT 许可证](https://github.com/ptitSeb/gl4es/blob/master/LICENSE)。
- [Mesa 3D 图形库](https://gitlab.freedesktop.org/mesa/mesa)：[MIT 许可证](https://docs.mesa3d.org/license.html)。
- [MetalANGLE](https://github.com/khanhduytran0/metalangle)（作者：@kakashidinho 及 ANGLE 开发团队）：[BSD 2.0 许可证](https://github.com/kakashidinho/metalangle/blob/master/LICENSE)。
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK)：[Apache 2.0 许可证](https://github.com/KhronosGroup/MoltenVK/blob/master/LICENSE)。
- [openal-soft](https://github.com/kcat/openal-soft)：[LGPLv2 许可证](https://github.com/kcat/openal-soft/blob/master/COPYING)。
- [Azul Zulu JDK](https://www.azul.com/downloads/?package=jdk)：[GNU GPLv2 许可证](https://openjdk.java.net/legal/gplv2+ce.html)。
- [LWJGL3](https://github.com/PojavLauncherTeam/lwjgl3)：[BSD-3 许可证](https://github.com/LWJGL/lwjgl3/blob/master/LICENSE.md)。
- [LWJGLX](https://github.com/PojavLauncherTeam/lwjglx)（用于 LWJGL3 的 LWJGL2 API 兼容层）：许可证未知。
- [DBNumberedSlider](https://github.com/khanhduytran0/DBNumberedSlider)：[Apache 2.0 许可证](https://github.com/immago/DBNumberedSlider/blob/master/LICENSE)
- [fishhook](https://github.com/khanhduytran0/fishhook)：[BSD-3 许可证](https://github.com/facebook/fishhook/blob/main/LICENSE)。
- [shaderc](https://github.com/khanhduytran0/shaderc)（供 Vulkan 渲染模组使用）：[Apache 2.0 许可证](https://github.com/google/shaderc/blob/main/LICENSE)。
- [NRFileManager](https://github.com/mozilla-mobile/firefox-ios/tree/b2f89ac40835c5988a1a3eb642982544e00f0f90/ThirdParty/NRFileManager)：[MPL-2.0 许可证](https://www.mozilla.org/en-US/MPL/2.0)
- [AltKit](https://github.com/rileytestut/AltKit)
- [UnzipKit](https://github.com/abbeycode/UnzipKit)：[BSD-2 许可证](https://github.com/abbeycode/UnzipKit/blob/master/LICENSE)。
- [DyldDeNeuralyzer](https://github.com/xpn/DyldDeNeuralyzer)：用于绕过库验证（Library Validation）以加载外部运行时
- 感谢 [MCHeads](https://mc-heads.net) 提供 Minecraft 头像服务。
