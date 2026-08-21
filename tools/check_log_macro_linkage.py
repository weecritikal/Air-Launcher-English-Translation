#!/usr/bin/env python3
"""Fail the build if a file routes NSLog through customNSLog but cannot link it.

utils.h redefines NSLog to call customNSLog, which is defined in utils.m. utils.m
is compiled into the main executable only. A source file in a different CMake
target that includes utils.h - directly or through another header - therefore
compiles fine and then fails at link with:

    Undefined symbols for architecture arm64:
      "_customNSLog", referenced from: ...

That happened once already, to audio_capture_bridge.m in the audio_capture
shared library. The failure is a link error a long way from its cause, so this
check names the file and the target instead.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NATIVES = os.path.join(ROOT, "Natives")
CMAKE = os.path.join(NATIVES, "CMakeLists.txt")

INCLUDE = re.compile(r'^\s*#\s*(?:import|include)\s+"([^"]+)"', re.M)
TARGET_START = re.compile(r"^\s*add_(?:library|executable)\(\s*([A-Za-z0-9_]+)")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def target_sources():
    """Map every target to the source files listed in its add_* block."""
    targets, current, depth = {}, None, 0
    for line in read(CMAKE).replace("\r\n", "\n").split("\n"):
        if current is None:
            m = TARGET_START.match(line)
            if m:
                current, depth = m.group(1), line.count("(") - line.count(")")
                targets.setdefault(current, [])
                continue
        else:
            depth += line.count("(") - line.count(")")
            src = line.strip().rstrip(")").strip()
            if src.endswith((".m", ".mm", ".c", ".cpp")):
                targets[current].append(src)
            if depth <= 0:
                current = None
    return targets


def resolve(name, base):
    for cand in (os.path.join(base, name), os.path.join(NATIVES, name)):
        if os.path.isfile(cand):
            return cand
    return None


def pulls_in_utils(path, seen=None):
    """True when path reaches utils.h through any chain of local includes."""
    seen = seen if seen is not None else set()
    real = os.path.realpath(path)
    if real in seen:
        return False
    seen.add(real)
    if os.path.basename(real) == "utils.h":
        return True
    if not os.path.isfile(real):
        return False
    for inc in INCLUDE.findall(read(real)):
        nxt = resolve(inc, os.path.dirname(real))
        if nxt and pulls_in_utils(nxt, seen):
            return True
    return False


def main():
    targets = target_sources()
    if not targets:
        print("could not parse any target out of Natives/CMakeLists.txt", file=sys.stderr)
        return 2

    providers = {t for t, srcs in targets.items()
                 if any(os.path.basename(s) == "utils.m" for s in srcs)}
    if not providers:
        print("no target compiles utils.m - customNSLog would be undefined everywhere",
              file=sys.stderr)
        return 2

    problems = []
    for target, sources in targets.items():
        if target in providers:
            continue
        for src in sources:
            path = os.path.join(NATIVES, src)
            if not os.path.isfile(path):
                continue
            if pulls_in_utils(path):
                problems.append((src, target))

    if problems:
        print("Files that use the customNSLog logging macro but are not linked with utils.m:\n",
              file=sys.stderr)
        for src, target in problems:
            print(f"  {src}  (target: {target})", file=sys.stderr)
        print("\nEach one will fail to link with an undefined _customNSLog symbol.",
              file=sys.stderr)
        print("Either drop the utils.h include from the file, or add utils.m to its target.",
              file=sys.stderr)
        return 1

    checked = sum(len(s) for t, s in targets.items() if t not in providers)
    print(f"Logging macro linkage OK: {checked} sources across "
          f"{len(targets) - len(providers)} targets, none reach utils.h without utils.m.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
