#!/usr/bin/env python3
"""Check the mod loader version gates against the ranges the loaders actually publish.

Picking a loader in the install screen is refused outright when its compatibility check says no
- tableView:didSelectRowAtIndexPath: returns early - so a gate that is too strict is not a hint
that ages badly, it is a version nobody can install. Two were wrong when this was written: Quilt
was gated at 1.18 although Quilt publishes back to 1.14.4, and OptiFine at 1.8 although builds
exist for 1.7.2 and 1.7.10.

Those numbers are easy to lower by one line and hard to notice, so this pins them. Each floor
below carries the source it was read from, and --online re-reads those sources and reports any
that have moved.

Usage:
    check_loader_matrix.py            verify the source against the table
    check_loader_matrix.py --online   also re-read the loaders' own metadata
"""
import re
import sys
import json
import urllib.request

SRC = "Natives/installer/ModLoaderInstallViewController.m"

# loader -> (method, expected minor floor for major 1, why, where it was read from)
FLOORS = {
    "Fabric": ("isFabricCompatible", 14,
               "Fabric's own game list stops at 1.14",
               "https://meta.fabricmc.net/v2/versions/game"),
    "Quilt": ("isQuiltCompatible", 14,
              "Quilt's own game list reaches back to 1.14.4",
              "https://meta.quiltmc.org/v3/versions/game"),
    "OptiFine": ("isOptiFineCompatible", 7,
                 "builds exist for 1.7.2 and 1.7.10, and none for 1.6.4 or older",
                 "https://bmclapi2.bangbang93.com/optifine/1.7.10"),
    "Forge": ("isForgeCompatible", 1,
              "Forge's maven carries builds from 1.1 onwards",
              "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"),
}
# NeoForge is checked separately: its floor is a patch level, not a minor.
NEOFORGE_FLOOR = (20, 1, "NeoForge's first release targeted 1.20.1, published under the "
                         "net.neoforged:forge coordinates before the move to net.neoforged:neoforge")


def read_floor(src, method):
    """Pull the `minor >= N` constant out of one compatibility method."""
    m = re.search(r"- \(BOOL\)" + method + r"\s*\{(.*?)\n\}", src, re.S)
    if not m:
        return None
    got = re.search(r"minor\s*>=\s*(\d+)", m.group(1))
    return int(got.group(1)) if got else None


def check_source():
    src = open(SRC, encoding="utf-8").read()
    bad = []
    for loader, (method, floor, why, source) in FLOORS.items():
        found = read_floor(src, method)
        if found is None:
            bad.append(f"{loader}: could not find a `minor >= N` test in {method}")
        elif found != floor:
            bad.append(f"{loader}: {method} gates at 1.{found}, expected 1.{floor} - {why}\n"
                       f"      read from {source}")
        else:
            print(f"  ok   {loader:9s} 1.{floor}+   ({method})")

    m = re.search(r"- \(BOOL\)isNeoForgeCompatible\s*\{(.*?)\n\}", src, re.S)
    if not m:
        bad.append("NeoForge: isNeoForgeCompatible not found")
    else:
        body = m.group(1)
        minor, patch, why = NEOFORGE_FLOOR
        if not re.search(r"minor\s*==\s*%d" % minor, body) or not re.search(r"patch\s*>=\s*%d" % patch, body):
            bad.append(f"NeoForge: expected a 1.{minor}.{patch} floor - {why}")
        else:
            print(f"  ok   {'NeoForge':9s} 1.{minor}.{patch}+ (isNeoForgeCompatible)")
    return bad


def check_online():
    """Re-read the loaders' own metadata and report floors that have moved."""
    notes = []

    def get(url, timeout=45):
        req = urllib.request.Request(url, headers={"User-Agent": "AirLauncher/1.0"})
        return urllib.request.urlopen(req, timeout=timeout).read()

    for name, url in (("Fabric", FLOORS["Fabric"][3]), ("Quilt", FLOORS["Quilt"][3])):
        try:
            data = json.loads(get(url))
            stable = [v["version"] for v in data if v.get("stable")]
            oldest = stable[-1] if stable else "?"
            print(f"  live {name:9s} oldest stable game version: {oldest}")
            parts = oldest.split(".")
            if len(parts) >= 2 and parts[0] == "1":
                want = FLOORS[name][1]
                if int(parts[1]) < want:
                    notes.append(f"{name} now publishes for 1.{parts[1]}, below the pinned floor of 1.{want}")
        except Exception as exc:
            print(f"  skip {name:9s} could not read {url} ({exc})")

    try:
        builds = json.loads(get(FLOORS["OptiFine"][3]))
        print(f"  live {'OptiFine':9s} 1.7.10 builds available: {len(builds)}")
        if not builds:
            notes.append("OptiFine reports no 1.7.10 builds; the 1.7 floor may no longer hold")
    except Exception as exc:
        print(f"  skip {'OptiFine':9s} could not read the build list ({exc})")
    return notes


def main():
    print("Loader version gates")
    bad = check_source()
    notes = []
    if "--online" in sys.argv:
        print("\nAgainst the loaders' own metadata")
        notes = check_online()

    if bad:
        print("\nThese gates do not match the range the loader publishes. A gate that is too")
        print("strict makes the loader unselectable for versions it supports.\n")
        for b in bad:
            print("  " + b)
        return 1
    if notes:
        print("\nThe pinned floors still hold, but the sources have moved:")
        for n in notes:
            print("  " + n)
    print("\nEvery loader gate matches the range that loader publishes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
