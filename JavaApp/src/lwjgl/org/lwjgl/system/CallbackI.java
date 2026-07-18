/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS 适配版：兼容 LWJGL 3.3.x（iOS 旧版）和 3.4.1（标准新版）两种 Callback API。
 *
 * 背景：
 *   iOS PojavLauncher 的 LWJGL 模块（GLFW/OpenGL/STB 等）使用旧版 3.3.x API，
 *   CallbackI 接口要求实现 getCallInterface() 返回 FFICIF。
 *   但 MC 26.3+ 的 SDL 模块（lwjgl-sdl.jar）使用标准 3.4.1 API，
 *   CallbackI 接口要求实现 getDescriptor() 返回 Callback.Descriptor。
 *   两者在运行时类路径上共存，导致 SDL callback 触发 AbstractMethodError。
 *
 * 崩溃链（修复前）：
 *   SdlDebug.<clinit> → SDL_LogOutputFunction.create(I) → i.address()
 *   → CallbackI.address() default → this.getCallInterface()  // 旧版 API
 *   → SDL_LogOutputFunctionI 没实现此方法 → AbstractMethodError
 *
 * 兼容策略：
 *   1. 保留 getCallInterface() abstract（iOS GLFW/OpenGL/STB 等旧版实现提供）
 *   2. 添加 getDescriptor() default 方法（新版 SDL 等可覆盖返回静态 DESCRIPTOR）
 *      默认实现：把旧版 getCallInterface() 返回的 FFICIF 包装为 Descriptor
 *   3. address() default 改用 getDescriptor().cif 获取 FFICIF（兼容两种 API）
 *      - 旧版 callback：getDescriptor() 默认实现 → 包装 getCallInterface() → .cif
 *      - 新版 callback：getDescriptor() 被覆盖 → 返回静态 DESCRIPTOR → .cif
 *   两种路径最终都调用 Callback.create(FFICIF, Object) 创建 native closure。
 */
package org.lwjgl.system;

import org.lwjgl.system.libffi.FFICIF;

import java.lang.invoke.MethodHandles;

public interface CallbackI extends Pointer {

    /** 旧版 API（LWJGL 3.3.x）：返回 FFICIF。iOS GLFW/OpenGL/STB 等模块实现此方法。 */
    FFICIF getCallInterface();

    /**
     * 新版 API（LWJGL 3.4.1）：返回 Callback.Descriptor。
     * 标准 3.4.1 的 SDL 等模块会覆盖此方法返回静态 DESCRIPTOR。
     * 默认实现：把旧版 getCallInterface() 的 FFICIF 包装为 Descriptor，
     * 使旧版 callback 实现自动兼容新版 API 调用路径。
     */
    default Callback.Descriptor getDescriptor() {
        return new Callback.Descriptor(MethodHandles.lookup(), getCallInterface());
    }

    /**
     * 创建并返回 native closure 的地址。
     * 通过 getDescriptor().cif 获取 FFICIF，兼容新旧两种 CallbackI 实现。
     */
    default long address() {
        return Callback.create(getDescriptor().cif, this);
    }

    /** 由具体 callback 实现的 native 调用入口。 */
    void callback(long ret, long args);
}
