#!/usr/bin/env python3
"""Fail the build when the launcher cannot answer an LWJGL call some Minecraft version makes.

The launcher has to supply its own LWJGL, because the real one drives a desktop window system
and needs natives that do not exist for iOS. That means one build of LWJGL serves every version
of Minecraft, and every API that changed between LWJGL releases becomes a mod that crashes on
this launcher and nowhere else. The failure is not obvious from the crash: a missing method
raises NoSuchMethodError inside Forge's parallel mod setup, which aborts the whole mod queue and
kills the game with a message naming neither the mod nor the call.

That class of bug used to be found by a player losing an evening. This finds it at build time.

lwjgl_api_reference.tsv.gz lists every class, method and descriptor published by the LWJGL
releases Minecraft has actually shipped - 3.1.6, 3.2.1, 3.2.2, 3.3.1, 3.3.2 and 3.3.3, which
covers 1.13 through current - restricted to packages a mod can reach on this platform. Anything
in there that the built launcher does not provide is a mod that will crash, unless it is listed
in lwjgl_api_allowlist.txt with a reason.

Usage:
    check_lwjgl_api.py <built-lwjgl.jar | directory-of-classes>

Regenerating the reference needs network access and is documented in tools/README.md.
"""
import gzip
import os
import re
import struct
import sys
import zipfile


def parse_class(data):
    """Return (internal class name, [(method name, descriptor)]) for public/protected methods."""
    if data[:4] != b"\xca\xfe\xba\xbe":
        return None
    o = 8
    cp_count = struct.unpack_from(">H", data, o)[0]
    o += 2
    cp = [None] * cp_count
    i = 1
    while i < cp_count:
        tag = data[o]
        o += 1
        if tag == 1:
            ln = struct.unpack_from(">H", data, o)[0]
            o += 2
            cp[i] = data[o:o + ln].decode("utf-8", "replace")
            o += ln
        elif tag in (7, 8, 16, 19, 20):
            cp[i] = struct.unpack_from(">H", data, o)[0]
            o += 2
        elif tag == 15:
            o += 3
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            o += 4
        elif tag in (5, 6):
            o += 8
            i += 1                      # long and double occupy two constant pool slots
        else:
            return None
        i += 1
    o += 2                              # access_flags
    this_idx = struct.unpack_from(">H", data, o)[0]
    o += 4                              # this_class, super_class
    ifc = struct.unpack_from(">H", data, o)[0]
    o += 2 + 2 * ifc
    name = cp[cp[this_idx]] if isinstance(cp[this_idx], int) else None

    def members():
        nonlocal o
        n = struct.unpack_from(">H", data, o)[0]
        o += 2
        out = []
        for _ in range(n):
            acc, nm, de = struct.unpack_from(">HHH", data, o)
            o += 6
            na = struct.unpack_from(">H", data, o)[0]
            o += 2
            for _ in range(na):
                o += 2
                ln = struct.unpack_from(">I", data, o)[0]
                o += 4 + ln
            out.append((acc, cp[nm], cp[de]))
        return out

    members()                           # fields, skipped
    # 0x0001 public | 0x0004 protected - what a mod is able to call
    return name, [(nm, de) for acc, nm, de in members() if acc & 0x0005]


def surface_of(path):
    """Build {class: {(method, descriptor)}} from a jar or a directory of .class files."""
    api = {}

    def add(data):
        r = parse_class(data)
        if not r or not r[0] or not r[0].startswith("org/lwjgl/"):
            return
        api.setdefault(r[0], set()).update(r[1])

    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for fn in files:
                if fn.endswith(".class"):
                    with open(os.path.join(root, fn), "rb") as fh:
                        add(fh.read())
    else:
        with zipfile.ZipFile(path) as z:
            for e in z.namelist():
                if e.endswith(".class"):
                    add(z.read(e))
    return api


def load_allowlist(path):
    """Read the three shapes a rule can take.

    class<TAB>name<TAB>descriptor  one exact method
    class<TAB>name                 every overload of that name
    class                          the whole class, for LWJGL internals with no mod-facing contract
    ~regex                         matched against "class<TAB>name<TAB>descriptor", for whole
                                   categories of generated plumbing that repeat across many classes
    """
    exact, by_name, by_class, patterns = set(), set(), set(), []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.lstrip().startswith("~"):
                patterns.append(re.compile(line.lstrip()[1:]))
                continue
            parts = line.split("\t")
            if len(parts) == 3:
                exact.add(tuple(parts))
            elif len(parts) == 2:
                by_name.add(tuple(parts))
            elif len(parts) == 1:
                by_class.add(parts[0])
            else:
                sys.exit(f"allowlist: cannot read line: {line!r}")
    return exact, by_name, by_class, patterns


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    built = sys.argv[1]
    if not os.path.exists(built):
        sys.exit(f"not found: {built}")

    here = os.path.dirname(os.path.abspath(__file__))
    with gzip.open(os.path.join(here, "lwjgl_api_reference.tsv.gz"), "rt", encoding="utf-8") as fh:
        reference = [tuple(l.rstrip("\n").split("\t")) for l in fh if l.strip()]
    exact, by_name, by_class, patterns = load_allowlist(os.path.join(here, "lwjgl_api_allowlist.txt"))

    api = surface_of(built)
    missing = []
    for cls, name, desc in reference:
        if cls in by_class or (cls, name) in by_name or (cls, name, desc) in exact:
            continue
        if any(p.search(f"{cls}\t{name}\t{desc}") for p in patterns):
            continue
        if (name, desc) not in api.get(cls, ()):
            missing.append((cls, name, desc))

    print(f"Reference API entries : {len(reference)}")
    print(f"Classes in the build  : {len(api)}")
    print(f"Allowed absences      : {len(exact) + len(by_name) + len(by_class) + len(patterns)} rules")
    print(f"Unanswered calls      : {len(missing)}")

    if not missing:
        print("\nEvery LWJGL call a shipped Minecraft version can make has an answer.")
        return 0

    print("\nThese are published by an LWJGL that Minecraft ships, and this build has no answer")
    print("for them. A mod calling one gets NoSuchMethodError and takes the game down with it.")
    print("Implement it, or add it to lwjgl_api_allowlist.txt with the reason it stays absent.\n")
    by_class = {}
    for cls, name, desc in missing:
        by_class.setdefault(cls, []).append((name, desc))
    for cls in sorted(by_class, key=lambda c: -len(by_class[c])):
        print(f"  {cls}  ({len(by_class[cls])})")
        for name, desc in sorted(by_class[cls])[:12]:
            print(f"      {name}{desc}")
        if len(by_class[cls]) > 12:
            print(f"      ... and {len(by_class[cls]) - 12} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
