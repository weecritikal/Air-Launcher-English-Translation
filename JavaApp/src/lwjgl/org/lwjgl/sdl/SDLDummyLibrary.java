/*
 * iOS SDL 空实现 SharedLibrary。
 *
 * 参照 Android feat/lwjgl3ify-sdl-support 分支和 iOS 自定义 GLFW 的模式：
 * Android 预打包 libSDL3.so 并用 bytehook 拦截 SDL_InitSubSystem 触发输入转发。
 * iOS 端不提供真正的 SDL3 原生库，而是将 SDL 调用 stub 掉，
 * 让 MC 继续使用现有的 GLFW 路径进行渲染和输入。
 *
 * 此类实现 SharedLibrary 接口，所有函数地址返回 0，
 * 防止其他 SDL 绑定类调用 getFunctionAddress 时 NPE 或崩溃。
 * LWJGL 绑定类在 getFunctionAddress 返回 0 时会抛出有意义的错误信息
 * 而非原生崩溃，让 MC 能优雅降级。
 */
package org.lwjgl.sdl;

import org.lwjgl.system.SharedLibrary;

import java.nio.ByteBuffer;

class SDLDummyLibrary implements SharedLibrary {

    @Override
    public String getName() {
        return "SDL3 (iOS stub)";
    }

    @Override
    public String getPath() {
        return "stub";
    }

    @Override
    public long getFunctionAddress(ByteBuffer name) {
        // 返回 0 表示函数不存在。LWJGL 绑定类检查 0 并抛出 NoSuchFunctionException。
        return 0L;
    }

    @Override
    public long address() {
        return 0L;
    }

    @Override
    public void free() {
        // 空实现
    }
}
