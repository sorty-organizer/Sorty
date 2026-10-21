#!/usr/bin/env python3
"""Read and change macOS Finder tags without the Sorty app.

Tags live in the `com.apple.metadata:_kMDItemUserTags` extended attribute as a
binary plist of `Name` or `Name\\nColorIndex` strings. Every change is journaled
with the previous value so `restore` can undo it.
"""

from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from sorty_helper import SortyError, append_journal, canonical, emit, now, read_journal
from sorty_profile import STATE_DIR

ATTRIBUTE = "com.apple.metadata:_kMDItemUserTags"
COLORS = {"none": 0, "gray": 1, "grey": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5, "red": 6, "orange": 7}


def require_macos() -> None:
    if sys.platform != "darwin":
        raise SortyError("Finder tags are only available on macOS")


def xattr(*arguments: str) -> subprocess.CompletedProcess[str]:
    # -s acts on a symlink itself instead of the item it points to.
    return subprocess.run(["/usr/bin/xattr", "-s", *arguments], capture_output=True, text=True)


def read_tags(path: Path) -> list[str]:
    result = xattr("-px", ATTRIBUTE, str(path))
    if result.returncode != 0:
        if "No such xattr" in result.stderr or not result.stderr.strip():
            return []
        raise SortyError(f"cannot read tags for {path}: {result.stderr.strip()}")
    raw = bytes.fromhex("".join(result.stdout.split()))
    value = plistlib.loads(raw) if raw else []
    if not isinstance(value, list) or not all(isinstance(tag, str) for tag in value):
        raise SortyError(f"unexpected tag data for {path}")
    return value


def write_tags(path: Path, tags: list[str]) -> None:
    if not tags:
        result = xattr("-d", ATTRIBUTE, str(path))
        if result.returncode != 0 and "No such xattr" not in result.stderr:
            raise SortyError(f"cannot clear tags for {path}: {result.stderr.strip()}")
        return
    data = plistlib.dumps(tags, fmt=plistlib.FMT_BINARY).hex()
    result = xattr("-wx", ATTRIBUTE, data, str(path))
    if result.returncode != 0:
        raise SortyError(f"cannot write tags for {path}: {result.stderr.strip()}")


def tag_name(tag: str) -> str:
    return tag.split("\n", 1)[0]


def parse_tag(value: str) -> str:
    """Turn `Name` or `Name:color` into Finder's stored form; color names alone get their color."""
    name, _, color = value.partition(":")
    name = name.strip()
    if not name or "\n" in name:
        raise SortyError(f"invalid tag: {value!r}")
    color = color.strip().casefold() or (name.casefold() if name.casefold() in COLORS else "")
    if color and color not in COLORS:
        raise SortyError(f"unknown tag color {color!r}; use one of {', '.join(sorted(set(COLORS) - {'grey'}))}")
    return f"{name}\n{COLORS[color]}" if color else name


def resolve_paths(values: list[str]) -> list[Path]:
    paths = [canonical(Path(value)) for value in values]
    missing = [str(path) for path in paths if not path.exists() and not path.is_symlink()]
    if missing:
        raise SortyError("paths do not exist: " + ", ".join(missing))
    return paths


def show(values: list[str]) -> dict[str, Any]:
    require_macos()
    return {"items": [
        {"path": str(path), "tags": [{"name": tag_name(tag), "color": int(tag.split("\n")[1]) if "\n" in tag else 0}
                                     for tag in read_tags(path)]}
        for path in resolve_paths(values)
    ]}


def change(values: list[str], add: list[str], remove: list[str], state_dir: Path) -> dict[str, Any]:
    require_macos()
    paths = resolve_paths(values)
    additions = [parse_tag(value) for value in add]
    removals = {tag_name(parse_tag(value)).casefold() for value in remove}
    if not additions and not removals:
        raise SortyError("pass --add or --remove")
    change_id = uuid.uuid4().hex
    journal = canonical(state_dir) / "tag-journals" / f"{change_id}.jsonl"
    append_journal(journal, {"record": "header", "change_id": change_id, "created_at": now()})
    changed = []
    for path in paths:
        before = read_tags(path)
        after = [tag for tag in before if tag_name(tag).casefold() not in removals]
        for tag in additions:
            existing = next((index for index, value in enumerate(after) if tag_name(value).casefold() == tag_name(tag).casefold()), None)
            if existing is None:
                after.append(tag)
            elif "\n" in tag:
                after[existing] = tag
        if after == before:
            continue
        write_tags(path, after)
        append_journal(journal, {"record": "tags", "path": str(path), "before": before, "after": after, "at": now()})
        changed.append({"path": str(path), "tags": [tag_name(tag) for tag in after]})
    return {"status": "completed", "changed": changed, "unchanged": len(paths) - len(changed), "journal": str(journal)}


def restore(journal: Path) -> dict[str, Any]:
    """Put back each item's previous tags unless someone changed them since."""
    require_macos()
    restored, conflicts = 0, []
    for row in reversed(read_journal(canonical(journal))):
        if row.get("record") != "tags":
            continue
        path = Path(row["path"])
        if not path.exists() and not path.is_symlink():
            conflicts.append(f"missing: {path}")
            continue
        if read_tags(path) != row["after"]:
            conflicts.append(f"tags changed since: {path}")
            continue
        write_tags(path, row["before"])
        restored += 1
    append_journal(canonical(journal), {"record": "restore", "restored": restored, "conflicts": conflicts, "at": now()})
    return {"status": "completed" if not conflicts else "partial", "restored": restored, "conflicts": conflicts}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("show").add_argument("paths", nargs="+")
    setter = commands.add_parser("set")
    setter.add_argument("paths", nargs="+")
    setter.add_argument("--add", action="append", default=[], metavar="NAME[:COLOR]")
    setter.add_argument("--remove", action="append", default=[], metavar="NAME")
    setter.add_argument("--state-dir", type=Path, default=STATE_DIR)
    commands.add_parser("restore").add_argument("journal", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "show":
            result = show(arguments.paths)
        elif arguments.command == "set":
            result = change(arguments.paths, arguments.add, arguments.remove, arguments.state_dir)
        else:
            result = restore(arguments.journal)
        emit(result)
        return 0 if result.get("status", "completed") == "completed" else 3
    except SortyError as error:
        emit({"status": "error", "error": str(error)})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
