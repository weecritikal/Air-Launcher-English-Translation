/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS-adapted version: compatible with both the LWJGL 3.3.x (legacy iOS) and 3.4.1 (standard, newer) Callback APIs.
 *
 * Background:
 *   The LWJGL modules of iOS PojavLauncher (GLFW/OpenGL/STB and so on) use the older 3.3.x API,
 *   The CallbackI interface requires implementing getCallInterface() to return an FFICIF.
 *   But the SDL module of MC 26.3+ (lwjgl-sdl.jar) uses the standard 3.4.1 API, and
 *   The CallbackI interface requires implementing getDescriptor() to return a Callback.Descriptor.
 *   The two coexist on the runtime classpath, so an SDL callback triggers an AbstractMethodError.
 *
 * The crash chain (before the fix):
 *   SdlDebug.<clinit> → SDL_LogOutputFunction.create(I) → i.address()
 *   → CallbackI.address() default → this.getCallInterface()  // the old API
 *   → SDL_LogOutputFunctionI does not implement that method → AbstractMethodError
 *
 * Compatibility strategy:
 *   1. getCallInterface() becomes a default method that takes the FFICIF from getDescriptor().cif
 *      - legacy callbacks override getCallInterface() to return a static CIF (preserving the original behavior)
 *      - newer callbacks override getDescriptor() to return a static DESCRIPTOR, and
 *        the default getCallInterface() implementation takes cif from it automatically
 *   2. getDescriptor() becomes a default method that wraps getCallInterface() into a Descriptor
 *      - newer callbacks override this method
 *      - legacy callbacks use the default implementation (which is never actually called, because address() goes through getCallInterface())
 *   3. The address() default still calls getCallInterface() (matching the legacy iOS version)
 *
 * Compile-time requirement:
 *   The Callback.Descriptor type must be recognizable. The Callback.java source already declares the Descriptor
 *   inner class (public static final), so javac generates Callback$Descriptor.class,
 *   overriding the version in lwjgl-callback-descriptor.jar.
 */
package org.lwjgl.system;

import org.lwjgl.system.libffi.FFICIF;

import java.lang.invoke.MethodHandles;

public interface CallbackI extends Pointer {

    /**
     * The old API (LWJGL 3.3.x): returns an FFICIF.
     * The iOS GLFW/OpenGL/STB modules and friends override this method to return a static CIF.
     * Newer modules such as SDL do not override it, and the default implementation takes the value from getDescriptor().cif.
     */
    default FFICIF getCallInterface() {
        return getDescriptor().cif;
    }

    /**
     * The new API (LWJGL 3.4.1): returns a Callback.Descriptor.
     * Standard 3.4.1 modules such as SDL override this method to return a static DESCRIPTOR.
     * Default implementation: wraps the FFICIF from the old getCallInterface() into a Descriptor.
     * Note: a legacy callback reaching this point would call getCallInterface() recursively,
     * but legacy callbacks do override getCallInterface() and never reach the default implementation,
     * so there is no recursion. Infinite recursion only happens when a callback overrides neither getCallInterface()
     * nor getDescriptor() (which is an incorrect implementation).
     */
    default Callback.Descriptor getDescriptor() {
        return new Callback.Descriptor(MethodHandles.lookup(), getCallInterface());
    }

    /**
     * Create the native closure and return its address.
     * getCallInterface() is used directly to obtain the FFICIF (compatible with both CallbackI implementations).
     */
    default long address() {
        return Callback.create(getCallInterface(), this);
    }

    /** The native call entry point implemented by the concrete callback. */
    void callback(long ret, long args);
}
