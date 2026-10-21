#!/usr/bin/env python3
"""Read and update this skill's preferences, with or without settings imported from the Sorty app."""

import argparse
import fnmatch
import json
import os
import sys
import tempfile
import uuid
from datetime import datetime, timezone
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


def validate_agent_lists(document):
    exclusions = document.get("exclusions", [])
    if not isinstance(exclusions, list) or not all(isinstance(value, str) and value.strip() for value in exclusions):
        raise ValueError("Agent exclusions must be an array of nonempty glob strings")
    learnings = document.get("learnings", [])
    if not isinstance(learnings, list) or not all(
        isinstance(item, dict) and isinstance(item.get("id"), str) and isinstance(item.get("text"), str) and item["text"].strip()
        for item in learnings
    ):
        raise ValueError("Agent learnings must be an array of objects with id and text")


def load_profile():
    profile = read_document(PROFILE_PATH)
    document = read_document(overrides_path())
    overrides = document.get("preferences", {})
    validate_preferences(overrides)
    validate_agent_lists(document)
    # Agent-managed lists work without the app and sit beside imported data.
    profile["agentExclusions"] = document.get("exclusions", [])
    profile["agentLearnings"] = document.get("learnings", [])
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


def read_overrides():
    document = read_document(overrides_path()) or {"version": 1, "preferences": {}}
    validate_agent_lists(document)
    return document


def write_overrides(document):
    path = overrides_path()
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


def update_preference(key, value=None):
    document = read_overrides()
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
    write_overrides(document)


def update_exclusion(pattern, remove=False):
    """Add or remove an agent exclusion glob; used when the user has no app-managed rules."""
    document = read_overrides()
    patterns = document.setdefault("exclusions", [])
    pattern = pattern.strip()
    if not pattern:
        raise ValueError("Exclusion pattern must be nonempty")
    if remove:
        if pattern not in patterns:
            raise ValueError(f"No agent exclusion: {pattern}")
        patterns.remove(pattern)
    elif pattern not in patterns:
        patterns.append(pattern)
    write_overrides(document)


def update_learning(text=None, remove_id=None):
    """Record a lasting organization lesson, or remove one by id."""
    document = read_overrides()
    learnings = document.setdefault("learnings", [])
    if remove_id is not None:
        remaining = [item for item in learnings if item["id"] != remove_id]
        if len(remaining) == len(learnings):
            raise ValueError(f"No agent learning: {remove_id}")
        document["learnings"] = remaining
    else:
        if not text or not text.strip():
            raise ValueError("Learning text must be nonempty")
        learnings.append({
            "id": uuid.uuid4().hex[:8], "text": text.strip(),
            "created_at": datetime.now(timezone.utc).isoformat(),
        })
    write_overrides(document)


def exclusion_checker():
    profile = load_profile()
    rules = [rule for rule in profile.get("exclusions", []) if rule.get("isEnabled", True)]
    agent_globs = profile.get("agentExclusions", [])
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
    def agent_excluded(path):
        # Globs with a slash match the absolute path; others match the item name.
        return any(
            fnmatch.fnmatch(str(path) if "/" in pattern else path.name, pattern)
            for pattern in agent_globs
        )
    def excluded(path):
        if agent_excluded(path):
            return True
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
    exclude = commands.add_parser("exclude")
    exclude.add_argument("action", choices=["add", "remove"])
    exclude.add_argument("pattern")
    learn = commands.add_parser("learn")
    learn.add_argument("action", choices=["add", "remove"])
    learn.add_argument("value", help="Learning text to add, or the id to remove")
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
        elif args.command == "exclude":
            update_exclusion(args.pattern, remove=args.action == "remove")
        elif args.command == "learn":
            if args.action == "add":
                update_learning(text=args.value)
            else:
                update_learning(remove_id=args.value)
        print(json.dumps(load_profile(), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
