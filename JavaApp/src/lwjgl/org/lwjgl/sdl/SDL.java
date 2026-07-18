/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS SDL3 库加载（真实动态库版）。
 *
 * 背景：
 *   MC 26.3-snapshot-4 首次从 GLFW 切换到 SDL3（Mojang 官方公告）。
 *   MC 声明 lwjgl-sdl 依赖，LWJGL 的 SDL.java 静态初始化器调用
 *   Library.loadNative() 加载 libSDL3.dylib。
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
 *
 * 全版本适配：
 *   - 26.3-snapshot-4 及以上 → SDL3（此类加载）
 *   - 26.3-snapshot-3 及以下 → GLFW（org.lwjgl.glfw.GLFW 加载）
 *   MC 自己根据版本 JSON 的 libraries 字段决定加载哪个，启动器无法强制切换。
 *   此类仅在 MC 26.3-snapshot-4+ 被触发加载。
 */
package org.lwjgl.sdl;

import org.lwjgl.system.Library;
import org.lwjgl.system.Platform;
import org.lwjgl.system.SharedLibrary;

public final class SDL {

    private static final SharedLibrary SDL_LIBRARY;

    static {
        System.out.println("[SDL] Loading libSDL3.dylib for MC 26.3-snapshot-4+ (SDL3 windowing backend)");
        System.out.println("[SDL] java.library.path=" + System.getProperty("java.library.path"));
        String libName = Platform.mapLibraryNameBundled("SDL3");
        System.out.println("[SDL] Resolved library name: " + libName);
        try {
            SDL_LIBRARY = Library.loadNative(
                SDL.class,
                "org.lwjgl.sdl",
                libName
            );
            System.out.println("[SDL] libSDL3.dylib loaded successfully: " + SDL_LIBRARY);
            // 验证关键函数是否存在（帮助诊断 SDL3 库完整性）
            try {
                long sdlInit = SDL_LIBRARY.getFunctionAddress("SDL_Init");
                long sdlQuit = SDL_LIBRARY.getFunctionAddress("SDL_Quit");
                long sdlCreateWindow = SDL_LIBRARY.getFunctionAddress("SDL_CreateWindow");
                System.out.println("[SDL] Function check: SDL_Init=0x" + Long.toHexString(sdlInit)
                    + " SDL_Quit=0x" + Long.toHexString(sdlQuit)
                    + " SDL_CreateWindow=0x" + Long.toHexString(sdlCreateWindow));
                if (sdlInit == 0 || sdlQuit == 0 || sdlCreateWindow == 0) {
                    System.out.println("[SDL] WARNING: One or more critical SDL functions are missing!");
                }
            } catch (Throwable t) {
                System.out.println("[SDL] Function check failed: " + t);
            }
        } catch (Throwable t) {
            System.out.println("[SDL] FATAL: Failed to load libSDL3.dylib: " + t);
            t.printStackTrace();
            throw t;
        }
    }

    public static SharedLibrary getLibrary() {
        return SDL_LIBRARY;
    }

    private SDL() {
        throw new UnsupportedOperationException();
    }
}
