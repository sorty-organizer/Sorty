#!/usr/bin/env python3
"""Read settings exported by the Sorty app into this installed skill."""

import argparse
import json
import tempfile
import os
import sys
from pathlib import Path

STATE_DIR = Path(os.environ.get("SORTY_SKILL_STATE_DIR", str(
    Path.home() / "Library/Application Support/Sorty Skill" if sys.platform == "darwin"
    else Path.home() / ".config/sorty-skill"
)))
PROFILE_PATH = Path(__file__).resolve().parent.parent / "references/imported-settings.json"


def overrides_path():
    return PROFILE_PATH.with_name("agent-preferences.json")


CHOICES = {
    "namingStyle": {"descriptive", "minimalist", "technical", "datePrefix", "screenshotFriendly", "custom"},
    "separator": {"spaces", "hyphen", "underscore", "smart"},
    "caseStyle": {"natural", "title", "sentence", "camel", "pascal", "snake", "kebab"},
    "datePolicy": {"never", "whenFound", "alwaysWhenReliable"},
}
TEXT_KEYS = {"instructions", "customNamingInstructions", "outputLanguage"}
FORMAT_KEYS = {"separator", "caseStyle", "datePolicy", "outputLanguage"}


def read_document(path):
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("version") != 1:
        raise ValueError(f"Unsupported skill profile: {path}")
    return value


def validate_preferences(values):
    if not isinstance(values, dict):
        raise ValueError("Agent preferences must be an object")
    for key, value in values.items():
        if key in CHOICES:
            valid = isinstance(value, str) and value in CHOICES[key]
        elif key in TEXT_KEYS:
            valid = isinstance(value, str) and bool(value.strip())
        elif key == "openFolderAfterOrganization":
            valid = isinstance(value, bool)
        else:
            valid = False
        if not valid:
            raise ValueError(f"Invalid agent preference: {key}")


def load_profile():
    profile = read_document(PROFILE_PATH)
    overrides = read_document(overrides_path()).get("preferences", {})
    validate_preferences(overrides)
    preferences = profile.setdefault("preferences", {})
    if not isinstance(preferences, dict):
        raise ValueError("Imported preferences must be an object")
    for key, value in overrides.items():
        if key in FORMAT_KEYS:
            formatting = preferences.setdefault("renameNamingOptions", {})
            if not isinstance(formatting, dict):
                raise ValueError("Imported filename formatting must be an object")
            formatting[key] = value
        else:
            preferences[key] = value
    return profile


def update_preference(key, value=None):
    path = overrides_path()
    document = read_document(path) or {"version": 1, "preferences": {}}
    values = document.setdefault("preferences", {})
    validate_preferences(values)
    # Validate the key even when removing an override.
    validate_preferences({key: value if value is not None else (
        next(iter(CHOICES[key])) if key in CHOICES else False if key == "openFolderAfterOrganization" else "unset"
    )})
    if value is None:
        values.pop(key, None)
    else:
        values[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".agent-preferences-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def exclusion_checker():
    rules = [rule for rule in load_profile().get("exclusions", []) if rule.get("isEnabled", True)]
    supported = {"File Extension", "File Name", "Folder Name", "Path Contains", "Hidden Files", "System Files"}
    for rule in rules:
        if rule.get("type") not in supported:
            raise ValueError(f"Imported exclusion needs native Sorty: {rule.get('type')}. Resolve it before agent work.")
    def matches(rule, path):
        kind = rule["type"]
        pattern = rule.get("pattern", "").strip()
        name, full = path.stem, str(path)
        if not rule.get("caseSensitive", False):
            pattern, name, full = pattern.lower(), name.lower(), full.lower()
        if kind == "File Extension":
            extension = path.suffix.lstrip(".")
            if not rule.get("caseSensitive", False):
                extension = extension.lower()
            result = bool(pattern.lstrip(".")) and extension == pattern.lstrip(".")
        elif kind == "File Name":
            result = bool(pattern) and pattern in name
        elif kind == "Folder Name":
            result = bool(pattern) and pattern in Path(full).parts
        elif kind == "Path Contains":
            tree = rule.get("pathMatchMode") == "folderTree" or (rule.get("pathMatchMode") is None and pattern.startswith("/"))
            pattern = pattern.rstrip("/") if tree else pattern
            result = bool(pattern) and (full == pattern or full.startswith(pattern + "/") if tree else pattern in full)
        elif kind == "Hidden Files":
            result = path.name.startswith(".")
        else:
            result = any(value in str(path) for value in (".DS_Store", "Thumbs.db", "desktop.ini", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"))
        return not result if rule.get("negated", False) else result
    def excluded(path):
        groups = {}
        for rule in rules:
            group = rule.get("conditionGroupID")
            if group:
                groups.setdefault(group, []).append(rule)
            elif matches(rule, path):
                return True
        return any(all(matches(rule, path) for rule in group) for group in groups.values())
    return excluded


def main():
    parser = argparse.ArgumentParser(description="Read or update this Sorty skill's preferences")
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("show")
    setter = commands.add_parser("set")
    setter.add_argument("key", choices=sorted(set(CHOICES) | TEXT_KEYS | {"openFolderAfterOrganization"}))
    setter.add_argument("value")
    unsetter = commands.add_parser("unset")
    unsetter.add_argument("key", choices=sorted(set(CHOICES) | TEXT_KEYS | {"openFolderAfterOrganization"}))
    args = parser.parse_args()
    try:
        if args.command == "set":
            value = args.value
            if args.key == "openFolderAfterOrganization":
                if value not in {"true", "false"}:
                    raise ValueError("Use true or false")
                value = value == "true"
            update_preference(args.key, value)
        elif args.command == "unset":
            update_preference(args.key)
        print(json.dumps(load_profile(), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
