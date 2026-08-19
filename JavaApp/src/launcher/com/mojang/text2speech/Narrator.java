package com.mojang.text2speech;

public interface Narrator {
    void say(final String msg, final boolean interrupt);

    void clear();

    boolean active();

    void destroy();

    static Narrator getNarrator() {
        return new NarratorDummy();
    }

    /** Stub for text2speech's nested initialisation failure, referenced by Minecraft's narrator code. */
    class InitializeException extends RuntimeException {
        public InitializeException(String message) {
            super(message);
        }

        public InitializeException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    static void setJNAPath(String sep) {
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + "./src/natives/resources/");
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + System.getProperty("java.library.path"));
    }
}
