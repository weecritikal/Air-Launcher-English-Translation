/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS-adapted version: rewritten from the decompiled Callback.class of iOS PojavLauncher (the older LWJGL 3.3.x version),
 * with the Descriptor inner class and the Callback(Descriptor) constructor added in LWJGL 3.4.1.
 *
 * Background:
 *   The LWJGL modules of iOS PojavLauncher (GLFW/OpenGL/STB and so on) use the older 3.3.x API,
 *   where the Callback constructor takes an FFICIF.
 *   But the SDL module of MC 26.3+ (lwjgl-sdl.jar) uses the standard 3.4.1 API, and
 *   the constructor of SDL_LogOutputFunction calls super(DESCRIPTOR), i.e.
 *   Callback.<init>(Callback$Descriptor). The older iOS Callback has no such constructor,
 *   which produces a NoSuchMethodError.
 *
 *   At the same time, the standard 3.4.1 SDL_LogOutputFunctionI overrides getDescriptor() to return
 *   the Callback$Descriptor type. If the return type of the CallbackI interface's getDescriptor()
 *   does not match, the JVM throws an AbstractMethodError. The Callback.Descriptor type
 *   must therefore be recognizable at compile time, so it is declared in this source file.
 *
 * Legacy iOS logic that was kept:
 *   - the native method getCallbackHandler(Method), provided by liblwjgl.dylib
 *   - create(FFICIF, Object), which uses ffi_closure_alloc + ffi_prep_closure_loc
 *   - the two ClosureRegistry implementations (Simple / ConcurrentHashMap)
 *   - the static {} block that detects the closure address layout and initializes CALLBACK_HANDLER
 *
 * 3.4.1 compatibility that was added:
 *   - the Descriptor inner class (public static final, with lookup + cif fields)
 *   - the Callback(Descriptor) constructor (which takes cif from the descriptor and delegates to Callback(FFICIF))
 */
package org.lwjgl.system;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.libffi.FFICIF;
import org.lwjgl.system.libffi.FFIClosure;
import org.lwjgl.system.libffi.LibFFI;
import org.lwjgl.system.jni.JNINativeInterface;

import java.lang.invoke.MethodHandles;
import java.lang.reflect.Method;
import java.util.concurrent.ConcurrentHashMap;

public abstract class Callback implements Pointer, NativeResource {

    private static final boolean DEBUG_ALLOCATOR;
    private static final ClosureRegistry CLOSURE_REGISTRY;
    private static final long CALLBACK_HANDLER;

    private long address;

    // === Added in LWJGL 3.4.1: the Descriptor inner class ===
    public static final class Descriptor {
        final MethodHandles.Lookup lookup;
        final FFICIF cif;

        public Descriptor(MethodHandles.Lookup lookup, FFICIF cif) {
            this.lookup = lookup;
            this.cif = cif;
        }
    }

    // === Added in LWJGL 3.4.1: the Callback(Descriptor) constructor ===
    protected Callback(Descriptor descriptor) {
        this(descriptor.cif);
    }

    // === Legacy iOS: the Callback(FFICIF) constructor ===
    protected Callback(FFICIF cif) {
        this.address = create(cif, this);
    }

    protected Callback(long address) {
        if (Checks.CHECKS) {
            Checks.check(address);
        }
        this.address = address;
    }

    @Override
    public long address() {
        return address;
    }

    @Override
    public void free() {
        free(address());
    }

    private static native long getCallbackHandler(Method method);

    static long create(FFICIF cif, Object target) {
        MemoryStack stack = MemoryStack.stackPush();
        try {
            PointerBuffer codes = stack.mallocPointer(1);
            FFIClosure closure = LibFFI.ffi_closure_alloc(FFIClosure.SIZEOF, codes);
            if (closure == null) {
                throw new OutOfMemoryError();
            }
            long nativeAddress = codes.get(0);
            if (DEBUG_ALLOCATOR) {
                MemoryManage.DebugAllocator.track(nativeAddress, FFIClosure.SIZEOF);
            }
            long globalRef = JNINativeInterface.NewGlobalRef(target);
            int errcode = LibFFI.ffi_prep_closure_loc(closure, cif, CALLBACK_HANDLER, globalRef, nativeAddress);
            if (errcode != 0) {
                JNINativeInterface.DeleteGlobalRef(globalRef);
                LibFFI.ffi_closure_free(closure);
                throw new RuntimeException("Failed to prepare the libffi closure");
            }
            CLOSURE_REGISTRY.put(nativeAddress, closure);
            return nativeAddress;
        } finally {
            stack.close();
        }
    }

    @SuppressWarnings("unchecked")
    public static <T extends CallbackI> T get(long address) {
        FFIClosure closure = CLOSURE_REGISTRY.get(address);
        return (T) MemoryUtil.memGlobalRefToObject(closure.user_data());
    }

    public static <T extends CallbackI> T getSafe(long address) {
        return address == 0L ? null : get(address);
    }

    public static void free(long address) {
        if (DEBUG_ALLOCATOR) {
            MemoryManage.DebugAllocator.untrack(address);
        }
        FFIClosure closure = CLOSURE_REGISTRY.get(address);
        JNINativeInterface.DeleteGlobalRef(closure.user_data());
        LibFFI.ffi_closure_free(closure);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Callback)) return false;
        return address == ((Callback) o).address();
    }

    @Override
    public int hashCode() {
        return (int) (address ^ (address >>> 32));
    }

    @Override
    public String toString() {
        return String.format("%s pointer [0x%X]", getClass().getSimpleName(), address);
    }

    // === The ClosureRegistry interface and its two implementations (matching the legacy iOS bytecode) ===
    interface ClosureRegistry {
        void put(long address, FFIClosure closure);
        FFIClosure get(long address);
        FFIClosure remove(long address);
    }

    // The Simple implementation: used when the closure address == the address of the Java FFIClosure wrapper object
    static final class SimpleClosureRegistry implements ClosureRegistry {
        @Override
        public void put(long address, FFIClosure closure) {
            // Empty implementation: it relies on FFIClosure's internal layout, so no mapping needs to be maintained
        }

        @Override
        public FFIClosure get(long address) {
            return FFIClosure.create(address);
        }

        @Override
        public FFIClosure remove(long address) {
            return get(address);
        }
    }

    // The ConcurrentHashMap implementation: the general-purpose approach
    static final class ConcurrentHashMapClosureRegistry implements ClosureRegistry {
        private final ConcurrentHashMap<Long, FFIClosure> map = new ConcurrentHashMap<>();

        @Override
        public void put(long address, FFIClosure closure) {
            map.put(address, closure);
        }

        @Override
        public FFIClosure get(long address) {
            return map.get(address);
        }

        @Override
        public FFIClosure remove(long address) {
            return map.remove(address);
        }
    }

    static {
        // 1. Read the DEBUG_MEMORY_ALLOCATOR configuration
        DEBUG_ALLOCATOR = Configuration.DEBUG_MEMORY_ALLOCATOR.get(false);

        // 2. Detect the closure address layout and choose a Registry implementation
        MemoryStack stack = MemoryStack.stackPush();
        FFIClosure testClosure;
        try {
            PointerBuffer codes = stack.mallocPointer(1);
            testClosure = LibFFI.ffi_closure_alloc(FFIClosure.SIZEOF, codes);
            if (testClosure == null) {
                throw new OutOfMemoryError();
            }
            long nativeAddress = codes.get(0);
            if (nativeAddress == testClosure.address()) {
                APIUtil.apiLog("Closure Registry: simple");
                CLOSURE_REGISTRY = new SimpleClosureRegistry();
            } else {
                APIUtil.apiLog("Closure Registry: ConcurrentHashMap");
                CLOSURE_REGISTRY = new ConcurrentHashMapClosureRegistry();
            }
            LibFFI.ffi_closure_free(testClosure);
        } finally {
            stack.close();
        }

        // 3. Initialize the native callback handler
        try {
            Method callbackMethod = CallbackI.class.getDeclaredMethod("callback", long.class, long.class);
            CALLBACK_HANDLER = getCallbackHandler(callbackMethod);
        } catch (Exception e) {
            throw new IllegalStateException("Failed to initialize the native callback handler.", e);
        }

        // 4. Trigger MemoryUtil class initialization (matching the legacy iOS version)
        MemoryUtil.getAllocator();
    }
}
