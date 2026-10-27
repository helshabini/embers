#!/usr/bin/env python3
"""Writes the translations in this folder into the three String Catalogs.

The catalogs are what ships; these files are where the wording is kept and reviewed, one file per
language, one line per string. Run after `scripts/sync-strings.sh`.

Fails, listing each one, if a string has no translation in some language or a translation does not
carry the same placeholders as its key — a dropped `%@` shows the wrong figure, an extra one crashes.
"""
import json, re, sys, pathlib, importlib.util

here = pathlib.Path(__file__).parent
root = here.parents[1]
catalogs = {
    "App": root / "Shared/Localizable.xcstrings",
    "EmbersCore": root / "Packages/EmbersCore/Sources/EmbersCore/Localizable.xcstrings",
    "EmbersData": root / "Packages/EmbersCore/Sources/EmbersData/Localizable.xcstrings",
}

# Catalog code → the file holding it. Adding a language is a file and a line here, plus its code
# in the project's `knownRegions`.
languages = {
    "ar": "ar",
    "de": "de",
    "es": "es",
    "fr": "fr",
    "ja": "ja",
    "pt-BR": "pt_BR",
    "zh-Hans": "zh_Hans",
}


def load(name):
    spec = importlib.util.spec_from_file_location(name, here / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms):
    return {"variations": {"plural": {form: unit(text) for form, text in forms.items()}}}


placeholder = re.compile(r"%(?:\d+\$)?(@|lld|u)|%%")


def placeholders(text):
    """What a string substitutes, by type, ignoring order: `%2$@` is as good as `%@`."""
    return sorted(m.group(1) or "%" for m in placeholder.finditer(text))


# `apply.py ar de` writes only those, for working on one language before the rest are done.
chosen = sys.argv[1:] or list(languages)
common = load("common")
loaded = {code: load(languages[code]) for code in chosen}
problems = []

live_keys = set()
for catalog_name, path in catalogs.items():
    catalog = json.loads(path.read_text())
    # A string the source no longer uses is dropped, not carried: Xcode only marks it stale.
    catalog["strings"] = {
        key: entry for key, entry in catalog["strings"].items()
        if entry.get("extractionState") != "stale"
    }
    for key, entry in catalog["strings"].items():
        live_keys.add(key)
        if key in common.untranslatable or not any(c.isalpha() for c in key):
            entry["shouldTranslate"] = False
            entry.pop("localizations", None)
            continue
        localizations = entry.setdefault("localizations", {})
        if key in common.en_plurals:
            one, other = common.en_plurals[key]
            localizations["en"] = plural({"one": one, "other": other})
        lookup_key = key
        expected = placeholders(key)
        for code, module in loaded.items():
            value = module.overrides.get(catalog_name, {}).get(lookup_key, module.strings.get(lookup_key))
            if value is None:
                problems.append(f"{code} has no translation — {catalog_name}: {key}")
                continue
            for text in value.values() if isinstance(value, dict) else [value]:
                # A plural form may leave its count out ("one transaction"), never add one.
                found = placeholders(text)
                if isinstance(value, dict):
                    ok = all(found.count(p) <= expected.count(p) for p in set(found)) and \
                        all(found.count(p) == expected.count(p) for p in expected if p != "lld")
                else:
                    ok = found == expected
                if not ok:
                    problems.append(f"{code} placeholders differ — {key!r} → {text!r}")
                # Numbers are written 0–9 in every language (`Locale.display`); a digit typed
                # into the wording in another script would be the one that disagrees.
                if any(not c.isascii() and c.isdigit() for c in text):
                    problems.append(f"{code} writes a digit other than 0–9 — {key!r} → {text!r}")
            localizations[code] = plural(value) if isinstance(value, dict) else unit(value)
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

# Wording kept for strings that are gone — not an error, but it should not linger.
for code, module in loaded.items():
    unused = sorted(set(module.strings) - live_keys - set(common.untranslatable))
    if unused:
        print(f"{code}: no longer used, remove from {languages[code]}.py: {unused}")

if problems:
    print(*problems, sep="\n")
    sys.exit(1)
print(f"All strings translated into {', '.join(chosen)}.")
