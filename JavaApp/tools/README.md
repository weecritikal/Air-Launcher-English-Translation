# LWJGL API compatibility check

The launcher cannot use Mojang's LWJGL. That build drives a desktop window system and needs
natives nobody compiles for iOS, so the launcher supplies its own — one build of LWJGL serving
every version of Minecraft.

That is the cause of a whole family of bugs. Minecraft has shipped six different LWJGL releases
between 1.13 and today, and mods are compiled against whichever one their Minecraft version uses.
Every API that changed across those releases is a mod that crashes on this launcher and on no
other. The crash is unhelpful: a missing method raises `NoSuchMethodError` inside Forge's parallel
mod setup, one failure there aborts the whole mod queue, and the game dies with a message naming
neither the mod nor the call. It reaches the player as a long load, a black screen, and a crash.

`check_lwjgl_api.py` finds those at build time instead.

## Running it

    python3 JavaApp/tools/check_lwjgl_api.py JavaApp/build/lwjgl.jar

It accepts a jar or a directory of class files, prints what is unanswered, and exits non-zero if
anything is. Both build workflows run it after the Java build.

## What it compares against

`lwjgl_api_reference.tsv.gz` lists every class, method and descriptor published by the LWJGL
releases Minecraft has actually shipped — 3.1.6, 3.2.1, 3.2.2, 3.3.1, 3.3.2 and 3.3.3, covering
1.13 through current — restricted to the packages a mod can reach on this platform. Anything in
that list the build does not provide is a mod that will crash.

Comparison is by name and descriptor, which is what the JVM resolves a call by. A method present
under the same name with different parameters does not count: that is still a `NoSuchMethodError`,
and it is how the original bug hid.

## Allowed absences

`lwjgl_api_allowlist.txt` records what is deliberately not provided, and why. Every entry needs a
reason written next to it — if there is no reason worth writing, implement the method instead.

Some absences cannot be fixed rather than merely being unfixed. Java does not allow two methods to
differ only by return type, so where LWJGL changed a return type the launcher can carry one shape
or the other, never both; in those cases it carries the current one. Those are marked as such.

## Regenerating the reference

Needs network access to Maven Central.

1. Download `lwjgl`, `lwjgl-glfw`, `lwjgl-jemalloc`, `lwjgl-openal`, `lwjgl-opengl`, `lwjgl-stb`,
   `lwjgl-tinyfd`, `lwjgl-vulkan` and `lwjgl-nanovg` for each version listed above from
   `https://repo1.maven.org/maven2/org/lwjgl/<module>/<version>/`.
2. Read every class with the parser in `check_lwjgl_api.py` and collect public and protected
   methods.
3. Write `class<TAB>name<TAB>descriptor` lines, sorted, gzipped, for the reachable packages.

Add a Minecraft-shipped LWJGL version to that list when Mojang starts shipping one; the check only
protects the versions the reference knows about.
