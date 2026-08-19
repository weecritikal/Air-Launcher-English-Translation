package com.mojang.text2speech;

import java.util.Locale;

/**
 * Stub standing in for text2speech's own OperatingSystem, matching its real shape.
 *
 * The launcher replaces the whole com.mojang.text2speech package with do-nothing versions, because
 * the narrator has nothing to talk to here. A package belongs to exactly one module, so these
 * classes are the only ones the game can see even when Mojang's jar is present - and this one was
 * missing entirely. Mixin resolves the types a target method mentions, Minecraft's constructor
 * mentions this package, and every modpack that mixins into Minecraft died during startup with
 *
 *   ClassMetadataNotFoundException: com.mojang.text2speech.OperatingSystem
 *
 * The constant names, their detection strings and the lookup below are taken from the real
 * 1.17.9 jar, so anything reading them finds what it expects. Detection is kept rather than
 * hardcoded: Narrator.getNarrator() returns the dummy regardless, so the only thing this value
 * feeds is code that asks which platform it is on, and the honest answer costs nothing.
 */
public enum OperatingSystem {
    LINUX("linux"),
    WINDOWS("win"),
    MAC_OS("mac"),
    UNSUPPORTED(null);

    private final String detectWith;

    OperatingSystem(final String detectWith) {
        this.detectWith = detectWith;
    }

    public static OperatingSystem get() {
        final String osName = System.getProperty("os.name");
        if (osName == null) {
            return UNSUPPORTED;
        }
        final String lowered = osName.toLowerCase(Locale.ROOT);
        for (final OperatingSystem os : values()) {
            if (os.detectWith != null && lowered.contains(os.detectWith)) {
                return os;
            }
        }
        return UNSUPPORTED;
    }
}
