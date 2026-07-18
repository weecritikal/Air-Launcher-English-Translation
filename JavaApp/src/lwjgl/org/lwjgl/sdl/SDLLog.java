/*
 * iOS SDLLog 空实现（no-op stub）。
 *
 * 背景：
 *   MC 26.3+ 通过 lwjgl-sdl 3.4.1 调用 SDL3 的日志 API。标准 SDLLog 类的
 *   SDLLog$Functions.<clinit> 会在类初始化时查找所有 18 个 SDL 日志函数地址
 *   （SDL_SetLogPriorities 等），iOS 上无 SDL3 库，SDLDummyLibrary 返回 0，
 *   apiGetFunctionAddress 抛出
 *   "NullPointerException: A required function is missing: SDL_SetLogPriorities"。
 *
 *   崩溃链：
 *     SdlDebug.<clinit> → SDLLog.SDL_SetLogPriorities(...) → 触发 SDLLog 类初始化
 *     → SDLLog$Functions.<clinit> → apiGetFunctionAddress(SDL, "SDL_SetLogPriorities")
 *     → 返回 0 → 抛 NPE
 *
 * iOS 适配方案：
 *   - 覆盖 jar 中的 SDLLog，所有方法改为 no-op（空实现）
 *   - 不再引用 SDLLog$Functions，避免其 <clinit> 执行函数查找
 *   - 保留所有常量值（与 SDL3 一致，MC 代码可能引用这些常量做比较）
 *   - SDL_GetLogPriority 返回 SDL_LOG_PRIORITY_INVALID (0)
 *   - nSDL_GetDefaultLogOutputFunction 返回 0 (NULL)
 *   - 所有 boolean 返回 false
 *
 *   iOS 上 MC 使用 GLFW 路径渲染和输入，SDL 仅作为可选依赖存在，
 *   日志输出由 Java 端 System.err 处理，SDL 日志系统无需真正工作。
 *
 * 此类覆盖 LWJGL jar 中的 org.lwjgl.sdl.SDLLog（Makefile 中 JavaApp/src/lwjgl/
 * 编译后的 .class 在 jar 解压后复制，覆盖 jar 中的同名类）。
 */
package org.lwjgl.sdl;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;

public class SDLLog {

    // SDL_LogCategory
    public static final int SDL_LOG_CATEGORY_APPLICATION = 0;
    public static final int SDL_LOG_CATEGORY_ERROR = 1;
    public static final int SDL_LOG_CATEGORY_ASSERT = 2;
    public static final int SDL_LOG_CATEGORY_SYSTEM = 3;
    public static final int SDL_LOG_CATEGORY_AUDIO = 4;
    public static final int SDL_LOG_CATEGORY_VIDEO = 5;
    public static final int SDL_LOG_CATEGORY_RENDER = 6;
    public static final int SDL_LOG_CATEGORY_INPUT = 7;
    public static final int SDL_LOG_CATEGORY_TEST = 8;
    public static final int SDL_LOG_CATEGORY_GPU = 9;
    public static final int SDL_LOG_CATEGORY_RESERVED2 = 10;
    public static final int SDL_LOG_CATEGORY_RESERVED3 = 11;
    public static final int SDL_LOG_CATEGORY_RESERVED4 = 12;
    public static final int SDL_LOG_CATEGORY_RESERVED5 = 13;
    public static final int SDL_LOG_CATEGORY_RESERVED6 = 14;
    public static final int SDL_LOG_CATEGORY_RESERVED7 = 15;
    public static final int SDL_LOG_CATEGORY_RESERVED8 = 16;
    public static final int SDL_LOG_CATEGORY_RESERVED9 = 17;
    public static final int SDL_LOG_CATEGORY_RESERVED10 = 18;
    public static final int SDL_LOG_CATEGORY_CUSTOM = 19;

    // SDL_LogPriority
    public static final int SDL_LOG_PRIORITY_INVALID = 0;
    public static final int SDL_LOG_PRIORITY_TRACE = 1;
    public static final int SDL_LOG_PRIORITY_VERBOSE = 2;
    public static final int SDL_LOG_PRIORITY_DEBUG = 3;
    public static final int SDL_LOG_PRIORITY_INFO = 4;
    public static final int SDL_LOG_PRIORITY_WARN = 5;
    public static final int SDL_LOG_PRIORITY_ERROR = 6;
    public static final int SDL_LOG_PRIORITY_CRITICAL = 7;
    public static final int SDL_LOG_PRIORITY_COUNT = 8;

    protected SDLLog() {
    }

    // === 日志优先级设置（no-op） ===
    public static void SDL_SetLogPriorities(int priority) {
        // iOS stub: 无 SDL3 库，日志优先级由 Java 端控制
    }

    public static void SDL_SetLogPriority(int category, int priority) {
        // iOS stub
    }

    public static int SDL_GetLogPriority(int category) {
        // iOS stub: 返回 INVALID 表示未设置
        return SDL_LOG_PRIORITY_INVALID;
    }

    public static void SDL_ResetLogPriorities() {
        // iOS stub
    }

    // === 日志前缀设置（no-op） ===
    public static boolean nSDL_SetLogPriorityPrefix(int priority, long prefix) {
        // iOS stub: 不支持自定义前缀
        return false;
    }

    public static boolean SDL_SetLogPriorityPrefix(int priority, ByteBuffer prefix) {
        return false;
    }

    public static boolean SDL_SetLogPriorityPrefix(int priority, CharSequence prefix) {
        return false;
    }

    // === 日志输出函数（no-op，直接丢弃日志） ===
    public static void nSDL_Log(long message) {
        // iOS stub: 日志由 Java 端处理，SDL 日志通道丢弃
    }

    public static void SDL_Log(ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_Log(CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogTrace(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogTrace(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogTrace(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogVerbose(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogVerbose(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogVerbose(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogDebug(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogDebug(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogDebug(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogInfo(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogInfo(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogInfo(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogWarn(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogWarn(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogWarn(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogError(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogError(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogError(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogCritical(int category, long message) {
        // iOS stub
    }

    public static void SDL_LogCritical(int category, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogCritical(int category, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogMessage(int category, int priority, long message) {
        // iOS stub
    }

    public static void SDL_LogMessage(int category, int priority, ByteBuffer message) {
        // iOS stub
    }

    public static void SDL_LogMessage(int category, int priority, CharSequence message) {
        // iOS stub
    }

    public static void nSDL_LogMessageV(int category, int priority, long fmt, long ap) {
        // iOS stub
    }

    public static void SDL_LogMessageV(int category, int priority, ByteBuffer fmt, long ap) {
        // iOS stub
    }

    public static void SDL_LogMessageV(int category, int priority, CharSequence fmt, long ap) {
        // iOS stub
    }

    // === 日志输出函数查询/设置（no-op） ===
    public static long nSDL_GetDefaultLogOutputFunction() {
        // iOS stub: 返回 NULL，表示无默认输出函数
        return MemoryUtil.NULL;
    }

    public static SDL_LogOutputFunction SDL_GetDefaultLogOutputFunction() {
        // iOS stub: 返回 null
        return null;
    }

    public static void nSDL_GetLogOutputFunction(long function, long userdata) {
        // iOS stub: 不写入任何值
    }

    public static void SDL_GetLogOutputFunction(PointerBuffer function, PointerBuffer userdata) {
        // iOS stub: 不写入任何值
    }

    public static void nSDL_SetLogOutputFunction(long function, long userdata) {
        // iOS stub: 不设置输出函数
    }

    public static void SDL_SetLogOutputFunction(SDL_LogOutputFunctionI callback, long userdata) {
        // iOS stub: 不设置输出函数
    }
}
