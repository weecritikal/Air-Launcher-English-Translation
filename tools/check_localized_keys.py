#!/usr/bin/env python3
"""Fail the build if a localize() key has no English text, or its format specifiers differ.

localize(@"some.key", @"Some text") takes a *comment* as its second argument, not a
fallback. NSLocalizedString returns the key itself when it is not defined, so a key
missing from en.lproj reaches the screen as "some.key". A user reported exactly that:
the download sheet showed "download.progress.downloading" instead of "Downloading...".

Nothing about that fails a build or a launch, which is why it shipped.

Two checks:
  1. Every localize() key is defined in en.lproj - the bundle every locale falls back to.
  2. The format specifiers in the .strings value match the ones in the call site. A
     mismatch is worse than a missing key: -stringWithFormat: reads arguments that were
     never passed and crashes at runtime.

OK and Cancel are exempt by design. localize() sends a key that is missing everywhere to
UIKit's own bundle, which returns a properly localised "Abbrechen" for a German user;
defining them here would replace that with the English word. For an English user the raw
key is already the right text.
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
EN = os.path.join(ROOT, "Natives/resources/en.lproj/Localizable.strings")

CALL = re.compile(r'localize\(\s*@"([^"]+)"\s*,\s*@"((?:[^"\\]|\\.)*)"\s*\)')
DEFINED = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=', re.M)
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|q|L|z|j|t)?[diouxXeEfgGaAcspn@]")

# Resolved by UIKit's bundle for non-English users; the key is already correct English.
EXEMPT = {"OK", "Cancel"}


def walk_sources():
    for base, _, files in os.walk(os.path.join(ROOT, "Natives")):
        for f in files:
            if f.endswith((".m", ".mm")):
                yield os.path.join(base, f)


def main():
    if not os.path.isfile(EN):
        print(f"cannot find {EN}", file=sys.stderr)
        return 2

    calls = {}
    where = defaultdict(list)
    for path in walk_sources():
        with open(path, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                for key, text in CALL.findall(line):
                    calls.setdefault(key, text)
                    where[key].append(f"{os.path.relpath(path, ROOT)}:{lineno}")

    with open(EN, encoding="utf-8", errors="replace") as fh:
        en_src = fh.read()
    defined = set(DEFINED.findall(en_src))
    values = dict(re.findall(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', en_src, re.M))

    missing = [k for k in sorted(calls) if k not in defined and k not in EXEMPT]
    mismatched = []
    for key, text in sorted(calls.items()):
        if key not in values:
            continue
        if SPEC.findall(text) != SPEC.findall(values[key]):
            mismatched.append((key, SPEC.findall(text), SPEC.findall(values[key])))

    if missing:
        print("These localize() keys have no English text, and reach the screen as their\n"
              "own key name:\n", file=sys.stderr)
        for key in missing:
            print(f'  "{key}" = "{calls[key]}";', file=sys.stderr)
            print(f"      used at {where[key][0]}", file=sys.stderr)
        print(f"\nAdd them to Natives/resources/en.lproj/Localizable.strings.", file=sys.stderr)

    if mismatched:
        print("\nThese keys' format specifiers differ between the call site and the\n"
              "translation. -stringWithFormat: will read arguments that were never\n"
              "passed and crash:\n", file=sys.stderr)
        for key, in_code, in_strings in mismatched:
            print(f"  {key}\n      call site : {in_code}\n      en.lproj  : {in_strings}", file=sys.stderr)

    if missing or mismatched:
        return 1

    print(f"Localized keys OK: {len(calls)} localize() call sites, all defined in en.lproj, "
          f"format specifiers consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
