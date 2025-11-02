# Angel Aura Amethyst (iOS) 重制版 - 项目概览

## 项目简介

这是一个针对 iOS/iPadOS 平台优化的 Minecraft 启动器，基于官方 Amethyst 项目进行二次开发。它旨在提供更流畅的游戏体验、更好的本地化支持以及增强的功能，例如 Mod 管理和智能下载源切换。

## 技术栈与架构

*   **主要语言**: Objective-C (原生 iOS 组件), Java (游戏核心逻辑), C/C++ (部分底层库和图形适配)
*   **构建系统**: 使用 `Makefile` 和 `CMake` 进行项目构建。
*   **核心依赖**:
    *   **Java 运行时**: 包含 OpenJDK 8, 17, 21 的 iOS 移植版本。
    *   **图形适配**: MetalANGLE (Metal to OpenGL ES), GL4ES (OpenGL ES to OpenGL), Mesa 3D。
    *   **AWT 支持**: Caciocavallo (用于 Java AWT 的纯 Java 实现)。
    *   **其他**: LWJGL (Java 游戏开发库), OpenAL (音频处理)。

## 目录结构

*   `Natives/`: 包含所有 iOS 原生代码 (Objective-C, C, C++)，包括 UI 控制器、应用入口点、Java 虚拟机启动器等。
*   `JavaApp/`: 包含 Java 端的应用逻辑和库文件。
*   `depends/`: 存放构建时依赖项，如 Java 运行时环境。
*   `artifacts/`: 构建输出目录，包含最终的 `.ipa` 安装包和中间文件。

## 构建与运行

### 构建环境要求

*   macOS 或 Linux 系统 (用于交叉编译)。
*   Xcode command line tools。
*   CMake, ldid, wget, JDK 8。
*   对于 iOS 14.5 及以上版本，推荐使用 TrollStore 进行安装以获得最佳体验。

### 构建命令

1.  **初始化环境**: 确保所有依赖项已安装。
2.  **执行构建**:
    ```bash
    make all
    ```
    这将依次执行以下步骤：
    *   `make native`: 构建原生库。
    *   `make java`: 构建 Java 应用。
    *   `make jre`: 下载并解压 iOS JRE。
    *   `make assets`: 编译应用资源 (如图标)。
    *   `make payload`: 组装应用包 (AngelAuraAmethyst.app)。
    *   `make package`: 生成最终的 `.ipa` 或 `.tipa` 安装包。

3.  **部署 (可选)**:
    *   在越狱设备上: `make deploy` (需要在设备上运行)。
    *   通过 TrollStore: 使用生成的 `.tipa` 文件直接安装。
    *   通过 AltStore/SideStore: 使用生成的 `.ipa` 文件安装。

注意，构建使用的设备是GitHub Actions提供的macOS 14，而不是这个设备。
### 启动流程

1.  应用启动 (`main.m`): 进行环境检查、日志重定向、目录设置等初始化工作。
2.  UI 初始化 (`AppDelegate.m`, `SceneDelegate.m`): 设置主窗口和初始视图控制器。
3.  JVM 启动 (`JavaLauncher.m`): 配置 Java 环境变量、JVM 参数，加载并启动 Java 虚拟机。
4.  Java 应用运行: JVM 加载 `PojavLauncher` 类，执行 Minecraft 的启动逻辑。

## 开发规范

*   **代码风格**: Objective-C 遵循 Apple 的编码规范，C/C++ 代码风格在项目中保持一致。
*   **分支管理**: 使用 Git 进行版本控制，功能开发在 `feature/` 分支进行。
*   **本地化**: 项目已完整汉化，后续开发需注意文本的本地化处理。

## 关键功能模块

*   **Mod 管理**: 位于 `Natives/Mod*` 文件中，提供 Mod 的查看、启用/禁用、删除功能。最新版本还支持通过搜索框快速查找Mod。
*   **账户系统**: 支持 Microsoft 账户、本地账户和演示账户，相关代码在 `Natives/authenticator/`。
*   **自定义控制**: 位于 `Natives/customcontrols/`，允许用户自定义游戏控制布局。
*   **偏好设置**: 由 `PLPreferences` 和 `PLProfiles` 管理用户设置和游戏配置文件。

## 其他信息

1.此设备的系统版本是Android 14，无Root权限，通过Termux进入终端并运行iFlow CLI。
2.在每次更改完源代码后，需要将更改提交到GitHub远程分支以构建项目进行测试。
3.如果在提交到GitHub过程中出现网络问题，请提醒用户关闭网络代理。
4.此项目使用Xcode 15.4，iPhoneOS 17.5 SDK构建，且最低系统支持为iOS14.0。
5.可以通过以下脚本在终端中获取GitHub Actions的构建日志：
  ```bash
  # 设置GitHub Token环境变量（请替换YOUR_GITHUB_TOKEN为实际的token）
  export GITHUB_TOKEN="YOUR_GITHUB_TOKEN"
  
  # 获取特定运行的作业列表
  curl -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.v3+json" \
       https://api.github.com/repos/herbrine8403/Amethyst-iOS-MyRemastered/actions/runs/RUN_ID/jobs
  
  # 获取特定作业的日志
  curl -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.v3+json" \
       https://api.github.com/repos/herbrine8403/Amethyst-iOS-MyRemastered/actions/jobs/JOB_ID/logs
  ```
  其中RUN_ID和JOB_ID需要替换为实际的运行ID和作业ID，可以在GitHub Actions页面找到。
  注意：YOUR_GITHUB_TOKEN需要替换为实际的GitHub Personal Access Token，该token需要有访问仓库的权限。