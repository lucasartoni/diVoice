#!/usr/bin/python3 -I
"""Checks that every localizable string of the app has an Italian translation.

    scripts/check-localization.py            # report missing and unused keys, exit 1 if any is missing
    scripts/check-localization.py --list     # print every key found in the code

Keys are English and come from String(localized:) and from the SwiftUI views that take a
LocalizedStringKey (Text, Button, Label, Toggle, ...). Interpolations become %@: interpolate
only String values in localizable text, so the key is predictable.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "app/Sources/DiVoice", ROOT / "app/Sources/DiVoiceKit"]
STRINGS = ROOT / "app/Resources/it.lproj/Localizable.strings"

CALLS = r"(?:String\(localized:|Text\(|Button\(|Label\(|Toggle\(|Picker\(|Section\(|LabeledContent\(|TextField\(|SecureField\(|Link\(|TableColumn\(|ContentUnavailableView\(|Menu\(|metric\(|tile\(|StatTile\(title:|DisclosureGroup\(|\.help\(|\.confirmationDialog\(|SetupStep\(title:|CardRow\(|CardSection\(|Pill\(|\((?:\.\w+|\d+),\s*)\s*"
NAMED = r"(?:title|detail|prompt: Text\():\s*"


def literal_at(text, start):
    """The Swift string literal starting at text[start] == '"', with \\(...) turned into %@."""
    i = start + 1
    out = ""
    while i < len(text):
        c = text[i]
        if c == "\\" and text[i + 1] == "(":
            depth, j = 1, i + 2
            in_string = False
            while depth:
                ch = text[j]
                if ch == '"' and text[j - 1] != "\\":
                    in_string = not in_string
                elif not in_string and ch == "(":
                    depth += 1
                elif not in_string and ch == ")":
                    depth -= 1
                j += 1
            out += "%@"
            i = j
            continue
        if c == "\\":
            out += text[i:i + 2]
            i += 2
            continue
        if c == '"':
            return out, i + 1
        out += c
        i += 1
    return None, len(text)


def keys_in(text):
    keys = set()
    for match in re.finditer(r"(?:" + CALLS + "|" + NAMED + r")(?:[^\"()]*?\?\s*)?\"", text):
        start = match.end() - 1
        key, end = literal_at(text, start)
        if key is None:
            continue
        keys.add(key)
        # The other branch of a ternary: cond ? "a" : "b"
        tail = re.match(r'\s*:\s*"', text[end:])
        if tail:
            other, _ = literal_at(text, end + tail.end() - 1)
            if other is not None:
                keys.add(other)
    return keys


def is_translatable(key):
    # Format-only keys ("%@ · %@"), empty strings and symbols are not text.
    return bool(re.search(r"[A-Za-z]{2}", key.replace("%@", "")))


def code_keys():
    keys = set()
    for folder in SOURCES:
        for path in sorted(folder.glob("*.swift")):
            # The screenshot renderer's strings are file names, not interface text.
            if path.name == "ScreenRenderer.swift":
                continue
            keys |= {k for k in keys_in(path.read_text()) if is_translatable(k)}
    return keys


def translations():
    if not STRINGS.exists():
        return {}
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', STRINGS.read_text(encoding="utf-8"), re.M)
    return dict(pairs)


def main():
    keys = code_keys()
    if "--list" in sys.argv:
        for key in sorted(keys):
            print(key)
        return 0
    italian = translations()
    missing = sorted(keys - italian.keys())
    unused = sorted(italian.keys() - keys)
    for key in missing:
        print(f"missing Italian translation: \"{key}\"")
    for key in unused:
        print(f"unused translation: \"{key}\"")
    print(f"{len(keys)} keys, {len(missing)} missing, {len(unused)} unused")
    return 1 if missing else 0


sys.exit(main())
