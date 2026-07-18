/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS SDL3 库加载（真实动态库版）。
 *
 * 背景：
 *   MC 26.3+ （1.21.9+ 快照）声明了 lwjgl-sdl 依赖。LWJGL 的 SDL.java
 *   静态初始化器调用 Library.loadNative() 加载 libSDL3.dylib。
 *
 *   早期适配方案曾用 SDLDummyLibrary stub 避免加载原生库，但导致
 *   SDLLog$Functions.<clinit> 查找 SDL_SetLogPriorities 等函数时返回 0，
 *   抛出 NullPointerException: A required function is missing。
 *
 *   现在已在 yitenchen123/SDL fork 仓库构建了 iOS arm64 版 libSDL3.dylib
 *   （含 UIKit 视频后端、Metal 渲染器、Core Audio 等完整 iOS 适配），
 *   放在 Natives/resources/Frameworks/libSDL3.dylib，由 Makefile 复制到
 *   AngelAuraAmethyst.app/Frameworks/，java.library.path 包含该路径。
 *
 * 此类恢复为标准 LWJGL 3.4.1 的加载逻辑，覆盖 jar 中的 org.lwjgl.sdl.SDL
 * （Makefile 中 JavaApp/src/lwjgl/ 编译后的 .class 在 jar 解压后复制，
 * 覆盖 jar 中的同名类）。
 *
 * 注意：SDL_MAIN_HANDLED=ON 在构建 libSDL3.dylib 时已设置，禁用了 SDL 的
 * main hook，MC 自己管理 main 函数入口。
 */
package org.lwjgl.sdl;

import org.lwjgl.system.Library;
import org.lwjgl.system.Platform;
import org.lwjgl.system.SharedLibrary;

public final class SDL {

    // iOS 适配：iOS 版 Configuration 无 SDL_LIBRARY_NAME 字段（标准 3.4.1 有），
    // 直接用 Platform.mapLibraryNameBundled("SDL3") 得到 "libSDL3.dylib"。
    // 库文件位于 AngelAuraAmethyst.app/Frameworks/libSDL3.dylib，
    // java.library.path 已包含 Frameworks 路径。
    private static final SharedLibrary SDL_LIBRARY = Library.loadNative(
        SDL.class,
        "org.lwjgl.sdl",
        Platform.mapLibraryNameBundled("SDL3")
    );

    public static SharedLibrary getLibrary() {
        return SDL_LIBRARY;
    }

    private SDL() {
        throw new UnsupportedOperationException();
    }
}
