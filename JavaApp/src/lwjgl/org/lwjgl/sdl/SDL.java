/*
 * iOS SDL 自定义实现（参照 iOS 自定义 GLFW 的模式）。
 *
 * 背景：MC 26.3+ （1.21.9+ 快照）声明了 lwjgl-sdl 依赖。LWJGL 原始的 SDL.java
 * 静态初始化器会调用 Library.loadNative() 加载 libSDL3.dylib，iOS 上没有该库
 * 会导致 UnsatisfiedLinkError → NoClassDefFoundError → MC 崩溃。
 *
 * 参照 Android feat/lwjgl3ify-sdl-support 分支：
 * - Android 预打包 libSDL3.so 并用 bytehook 拦截 SDL_InitSubSystem 触发 SDL 输入转发
 * - GLFW 和 SDL 并行运行，输入事件双发
 *
 * iOS 适配方案：
 * - 不加载真正的 SDL3 原生库（iOS 上编译 SDL3 + 输入桥接成本较高）
 * - 提供 SDLDummyLibrary 作为 SharedLibrary stub，所有函数地址返回 0
 * - SDLInit 中的 native 方法被自定义 SDLInit.java 覆盖为 Java stub
 * - MC 继续使用现有的 GLFW 路径进行渲染和输入（已有完整的 iOS GLFW 实现）
 * - 若 MC 调用 SDL 的高级功能（gamepad/events），LWJGL 会抛出有意义的错误
 *   而非原生崩溃，让 MC 能优雅降级
 *
 * 此类覆盖 LWJGL jar 中的 org.lwjgl.sdl.SDL（Makefile 中 JavaApp/src/lwjgl/
 * 编译后的 .class 在 jar 解压后复制，覆盖 jar 中的同名类）。
 */
package org.lwjgl.sdl;

import org.lwjgl.system.SharedLibrary;

public final class SDL {

    private static final SharedLibrary SDL_LIBRARY = new SDLDummyLibrary();

    /**
     * 返回 SDL SharedLibrary 实例。
     * iOS 上返回 SDLDummyLibrary（空实现），避免加载 libSDL3.dylib。
     */
    public static SharedLibrary getLibrary() {
        return SDL_LIBRARY;
    }

    private SDL() {
        throw new UnsupportedOperationException();
    }
}
