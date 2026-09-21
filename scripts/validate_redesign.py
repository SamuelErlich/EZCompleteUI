#!/usr/bin/env python3
"""Static preflight for the Portuguese dark redesign.

This does not compile or sign anything. It checks the source tree and reports
conditions which would make a Theos build misleading or non-reproducible.
"""
from __future__ import annotations

import argparse
import ast
import collections
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED_PRIVACY = {
    "NSMicrophoneUsageDescription",
    "NSSpeechRecognitionUsageDescription",
}
FORMAT_RE = re.compile(r"%(?:%|(?:[0-9]+\$)?[-+0#]*[0-9]*(?:\.[0-9]+)?[hlLzjt]*[diouxXeEfFgGcpasc@])")


def issue(kind: str, message: str, problems: list[str], warnings: list[str]) -> None:
    bucket = problems if kind == "ERROR" else warnings
    bucket.append(message)


def parse_strings(path: pathlib.Path, problems: list[str], warnings: list[str]):
    """Parse enough of Apple strings syntax to catch duplicate/invalid entries."""
    text = path.read_text(encoding="utf-8-sig")
    # Strip comments, preserving quoted strings. This intentionally rejects
    # malformed lines instead of silently inventing a translation.
    text_no_comments = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    pairs: list[tuple[str, str, int]] = []
    line_re = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
    for n, raw in enumerate(text_no_comments.splitlines(), 1):
        if not raw.strip():
            continue
        m = line_re.match(raw)
        if not m:
            issue("ERROR", f"{path.relative_to(ROOT)}:{n}: invalid .strings entry", problems, warnings)
            continue
        try:
            key = ast.literal_eval('"' + m.group(1) + '"')
            value = ast.literal_eval('"' + m.group(2) + '"')
        except Exception as exc:
            issue("ERROR", f"{path.relative_to(ROOT)}:{n}: invalid escape ({exc})", problems, warnings)
            continue
        pairs.append((key, value, n))
    by_key = collections.defaultdict(list)
    for key, value, n in pairs:
        by_key[key].append((value, n))
    for key, vals in by_key.items():
        if len(vals) > 1:
            issue("ERROR", f"{path.relative_to(ROOT)}: duplicate key {key!r} on lines {[n for _, n in vals]}", problems, warnings)
    return {key: value for key, value, _ in pairs}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true", help="return non-zero for any error")
    args = ap.parse_args()
    problems: list[str] = []
    warnings: list[str] = []

    info_path = ROOT / "Resources" / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except Exception as exc:
        info = {}
        issue("ERROR", f"Resources/Info.plist cannot be parsed: {exc}", problems, warnings)
    if info:
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"):
            if not info.get(key):
                issue("ERROR", f"Resources/Info.plist missing {key}", problems, warnings)
        if info.get("CFBundleIdentifier") != "com.gabriel.ezcomplete.beta":
            issue("ERROR", f"beta bundle identifier must be com.gabriel.ezcomplete.beta (got {info.get('CFBundleIdentifier')!r})", problems, warnings)
        missing_privacy = REQUIRED_PRIVACY - info.keys()
        if missing_privacy:
            issue("WARNING", "Info.plist is missing privacy key(s): " + ", ".join(sorted(missing_privacy)), problems, warnings)
        icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
        for icon in icons:
            # Icon names such as `AppIcon83.5x83.5@2x` contain dots but are
            # still extensionless CFBundleIconFiles values.
            candidates = [ROOT / "Resources" / (icon if icon.endswith(".png") else icon + ".png"), ROOT / "Resources" / icon]
            if not any(p.exists() for p in candidates):
                issue("WARNING", f"icon listed in Info.plist not found in Resources: {icon}", problems, warnings)

    make_path = ROOT / "Makefile"
    make = make_path.read_text(encoding="utf-8") if make_path.exists() else ""
    m = re.search(r"^EZCompleteUI_FILES\s*=\s*(.*?)(?=\n\S|\Z)", make, flags=re.S | re.M)
    listed: list[str] = []
    if not m:
        issue("ERROR", "Makefile has no EZCompleteUI_FILES assignment", problems, warnings)
    else:
        listed = re.findall(r"[A-Za-z0-9_+.-]+\.m", m.group(1))
        for src in listed:
            if not (ROOT / src).is_file():
                issue("ERROR", f"Makefile references missing source: {src}", problems, warnings)
    if "THEOS_PACKAGE_SCHEME = rootless" not in make and "THEOS_PACKAGE_SCHEME=rootless" not in make:
        issue("WARNING", "Makefile does not explicitly select THEOS_PACKAGE_SCHEME=rootless", problems, warnings)
    if "/Applications" not in make:
        issue("WARNING", "Makefile install path is not visibly /Applications; inspect packaging target", problems, warnings)

    for required in ("EZAuthManager.m", "EZKeyVault.m", "EZEntitlementManager.m"):
        if not (ROOT / required).is_file():
            issue("ERROR", f"missing reconstructed implementation: {required}", problems, warnings)

    config = (ROOT / "EZSupabaseConfig.m").read_text(encoding="utf-8", errors="ignore") if (ROOT / "EZSupabaseConfig.m").exists() else ""
    if "spuoimtqofhbdzosrbng" in config or "AzEVhLu" in config:
        issue("ERROR", "original Supabase project/key is still present in EZSupabaseConfig.m", problems, warnings)
    if "YOUR_PROJECT_REF" not in config:
        issue("WARNING", "EZSupabaseConfig.m no longer contains the safe placeholder; verify the new project is intentional", problems, warnings)
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts or "filesoldeR" in path.parts or ".backup-" in path.name:
            continue
        if path.resolve() == pathlib.Path(__file__).resolve():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if "spuoimtqofhbdzosrbng" in text or "sb_publishable_AzEVh" in text:
            issue("ERROR", f"original Supabase service reference remains in {path.relative_to(ROOT)}", problems, warnings)
    if not (ROOT / "supabase" / "migrations").is_dir():
        issue("ERROR", "Supabase migrations directory is missing", problems, warnings)
    config_path = ROOT / "supabase" / "config.toml"
    if not config_path.is_file():
        issue("ERROR", "supabase/config.toml is missing", problems, warnings)
    if not (ROOT / "supabase" / "functions" / "payments-webhook" / "index.ts").is_file():
        issue("ERROR", "payments webhook scaffold is missing", problems, warnings)

    localization = {}
    for path in sorted((ROOT / "Resources").glob("*.lproj/Localizable.strings")):
        localization[path.parent.name] = parse_strings(path, problems, warnings)
    pt = localization.get("pt.lproj", {})
    en = localization.get("en.lproj", {})
    if not pt:
        issue("ERROR", "Resources/pt.lproj/Localizable.strings is empty or missing", problems, warnings)
    missing_pt = sorted(set(en) - set(pt))
    if missing_pt:
        issue("WARNING", f"pt localization lacks {len(missing_pt)} English key(s) (first: {', '.join(missing_pt[:8])})", problems, warnings)
    for key in set(en) & set(pt):
        en_formats = FORMAT_RE.findall(en[key])
        pt_formats = FORMAT_RE.findall(pt[key])
        if collections.Counter(en_formats) != collections.Counter(pt_formats):
            issue("ERROR", f"format specifier mismatch for localization key {key!r}", problems, warnings)

    # Detect direct references to keys added by the redesign that are not in pt.
    referenced = set(re.findall(r'NSLocalizedString\s*\(\s*@"([^"]+)"', "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in ROOT.glob("*.m"))))
    missing_referenced = sorted(k for k in referenced if k not in pt and k in en)
    if missing_referenced:
        issue("WARNING", f"{len(missing_referenced)} referenced key(s) have no Portuguese value (first: {', '.join(missing_referenced[:8])})", problems, warnings)

    print("EZCompleteUI redesign preflight")
    print(f"  source root: {ROOT}")
    print(f"  version: {info.get('CFBundleShortVersionString', 'unknown')}")
    print(f"  Objective-C sources listed: {len(listed)}")
    for label, entries in (("ERROR", problems), ("WARNING", warnings)):
        for msg in entries:
            print(f"{label}: {msg}")
    if not problems:
        print("OK: no blocking static errors found")
    else:
        print(f"BLOCKED: {len(problems)} static error(s); do not publish a package as redesigned")
    return 1 if args.strict and problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
