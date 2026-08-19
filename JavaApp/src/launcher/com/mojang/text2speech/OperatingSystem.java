package com.mojang.text2speech;

/**
 * Stub standing in for text2speech's own OperatingSystem.
 *
 * The launcher replaces the whole com.mojang.text2speech package with do-nothing versions, because
 * the narrator has nothing to talk to here. A package belongs to exactly one module, so these
 * classes are the only ones the game can see even when the real library is present - and this one
 * was missing. Mixin resolves the types a target method mentions, Minecraft's constructor mentions
 * this package, and every modpack that mixins into Minecraft died during startup with
 *
 *   ClassMetadataNotFoundException: com.mojang.text2speech.OperatingSystem
 *
 * naming a class nobody had asked for. The constants mirror the Narrator implementations beside
 * this file, and get() answers UNKNOWN, which is the honest reply here and leaves anything that
 * switches on it to take its default branch.
 */
public enum OperatingSystem {
    LINUX,
    WINDOWS,
    OSX,
    UNKNOWN;

    public static OperatingSystem get() {
        return UNKNOWN;
    }
}
