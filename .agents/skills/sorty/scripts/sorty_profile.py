#!/usr/bin/env python3
"""Read settings exported by the Sorty app into this installed skill."""

import json
import os
import sys
from pathlib import Path

STATE_DIR = Path(os.environ.get("SORTY_SKILL_STATE_DIR", str(
    Path.home() / "Library/Application Support/Sorty Skill" if sys.platform == "darwin"
    else Path.home() / ".config/sorty-skill"
)))
PROFILE_PATH = Path(__file__).resolve().parent.parent / "references/imported-settings.json"


def load_profile():
    if not PROFILE_PATH.exists():
        return {}
    profile = json.loads(PROFILE_PATH.read_text())
    if profile.get("version") != 1:
        raise ValueError("Unsupported skill profile version")
    return profile


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


if __name__ == "__main__":
    print(json.dumps(load_profile(), indent=2))
