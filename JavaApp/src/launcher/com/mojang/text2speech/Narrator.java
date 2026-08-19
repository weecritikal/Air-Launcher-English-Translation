package com.mojang.text2speech;

public interface Narrator {
    /** Matches the real library's constant, which callers may reference instead of getNarrator(). */
    Narrator EMPTY = new NarratorDummy();

    void say(final String msg, final boolean interrupt);

    void clear();

    /** A default method in the real library, so keep it one here too. */
    default boolean active() {
        return false;
    }

    void destroy();

    static Narrator getNarrator() {
        return new NarratorDummy();
    }

    /**
     * Stub for text2speech's nested initialisation failure.
     * Checked, extending Exception exactly as the real one does - a RuntimeException here would be
     * caught by handlers the real class would slip past.
     */
    class InitializeException extends Exception {
        public InitializeException(String message, Throwable cause) {
            super(message, cause);
        }

        public InitializeException(String message) {
            super(message);
        }
    }

    static void setJNAPath(String sep) {
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + "./src/natives/resources/");
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + System.getProperty("java.library.path"));
    }
}
