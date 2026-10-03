#!/usr/bin/env python3
"""Deterministic filesystem mechanics for the Sorty Codex skill."""

from __future__ import annotations

import argparse
import errno
import fnmatch
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from sorty_profile import STATE_DIR, exclusion_checker


PLAN_VERSION = 2
MODES = {"organize", "organizeAndRename", "renameOnly"}
PACKAGE_EXTENSIONS = {
    ".app", ".bundle", ".framework", ".key", ".numbers", ".pages",
    ".photoslibrary", ".playground", ".rtfd", ".scptd", ".xcodeproj",
    ".xcworkspace",
}
DEFAULT_STATE_DIR = STATE_DIR


class SortyError(Exception):
    pass


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def emit(value: Any) -> None:
    json.dump(value, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def canonical(path: Path) -> Path:
    return Path(os.path.abspath(path.expanduser()))


def filesystem_key(path: Path) -> str:
    """Conservative collision key for common case-insensitive macOS volumes."""
    return unicodedata.normalize("NFD", str(path)).casefold()


def has_unsafe_components(path: Path) -> bool:
    return any(
        part in {".", ".."} or any(ord(character) < 32 for character in part)
        for part in path.parts
    )


def nearest_existing_parent(path: Path) -> Path:
    current = path
    while not current.exists() and not current.is_symlink():
        if current == current.parent:
            break
        current = current.parent
    return current if current.is_dir() else current.parent


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def reject_broad_root(root: Path) -> None:
    resolved = root.resolve(strict=False)
    home = Path.home().resolve(strict=False)
    if resolved == Path(resolved.anchor) or resolved == home:
        raise SortyError(f"refusing broad source root: {resolved}")


def matches_exclusion(relative: str, patterns: Iterable[str]) -> bool:
    normalized = relative.replace(os.sep, "/")
    return any(
        fnmatch.fnmatchcase(normalized, pattern)
        or fnmatch.fnmatchcase(f"{normalized}/", pattern)
        for pattern in patterns
    )


def is_hidden(relative: Path) -> bool:
    return any(part.startswith(".") for part in relative.parts)


def is_package(path: Path) -> bool:
    return path.is_dir() and path.suffix.lower() in PACKAGE_EXTENSIONS


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_manifest(root: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        if path.is_symlink():
            entries.append({"path": relative, "kind": "symlink", "target": os.readlink(path)})
        elif path.is_dir():
            entries.append({"path": relative, "kind": "directory", "mode": stat.S_IMODE(info.st_mode)})
        elif path.is_file():
            entries.append({"path": relative, "kind": "file", "size": info.st_size, "sha256": sha256(path)})
        else:
            entries.append({"path": relative, "kind": "other"})
    return entries


def content_signature(path: Path) -> Any:
    if path.is_symlink():
        return {"kind": "symlink", "target": os.readlink(path)}
    if path.is_dir():
        return {"kind": "directory", "entries": tree_manifest(path)}
    if path.is_file():
        return {"kind": "file", "size": path.stat().st_size, "sha256": sha256(path)}
    raise SortyError(f"unsupported filesystem item: {path}")


def scan(root: Path, exclusions: list[str], include_hidden: bool, expand_packages: bool) -> dict[str, Any]:
    root = canonical(root)
    reject_broad_root(root)
    if not root.is_dir():
        raise SortyError(f"source root is not a directory: {root}")
    try:
        imported_exclusion = exclusion_checker()
    except ValueError as error:
        raise SortyError(str(error)) from error

    items: list[dict[str, Any]] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        kept_directories: list[str] = []
        for name in sorted(directories):
            path = current_path / name
            relative = path.relative_to(root)
            relative_string = relative.as_posix()
            if (not include_hidden and is_hidden(relative)) or matches_exclusion(relative_string, exclusions) or imported_exclusion(path):
                continue
            if not expand_packages and is_package(path):
                info = path.lstat()
                items.append(item_record(path, root, info, "package"))
                continue
            items.append(item_record(path, root, path.lstat(), "directory"))
            kept_directories.append(name)
        directories[:] = kept_directories

        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(root)
            relative_string = relative.as_posix()
            if (not include_hidden and is_hidden(relative)) or matches_exclusion(relative_string, exclusions) or imported_exclusion(path):
                continue
            info = path.lstat()
            kind = "symlink" if path.is_symlink() else "file"
            items.append(item_record(path, root, info, kind))

    return {
        "version": PLAN_VERSION,
        "source_root": str(root),
        "generated_at": now(),
        "exclusions": exclusions,
        "items": sorted(items, key=lambda item: item["path"]),
    }


def item_record(path: Path, root: Path, info: os.stat_result, kind: str) -> dict[str, Any]:
    record: dict[str, Any] = {
        "path": path.relative_to(root).as_posix(),
        "kind": kind,
        "size": info.st_size,
        "device": info.st_dev,
        "inode": info.st_ino,
        "modified_ns": info.st_mtime_ns,
        "modified_at": datetime.fromtimestamp(info.st_mtime, timezone.utc).isoformat(),
    }
    if kind == "symlink":
        record["target"] = os.readlink(path)
    record["snapshot"] = source_snapshot(path)
    return record


def exact_duplicates(root: Path, exclusions: list[str], include_hidden: bool) -> dict[str, Any]:
    inventory = scan(root, exclusions, include_hidden, expand_packages=False)
    root = Path(inventory["source_root"])
    by_size: dict[int, list[Path]] = {}
    inode_paths: dict[tuple[int, int], list[str]] = {}
    for item in inventory["items"]:
        if item["kind"] != "file":
            continue
        path = root / item["path"]
        info = path.stat()
        inode_paths.setdefault((info.st_dev, info.st_ino), []).append(item["path"])
        by_size.setdefault(info.st_size, []).append(path)

    groups: list[dict[str, Any]] = []
    for size, paths in sorted(by_size.items()):
        if len(paths) < 2:
            continue
        by_hash: dict[str, list[Path]] = {}
        for path in paths:
            by_hash.setdefault(sha256(path), []).append(path)
        for digest, matches in sorted(by_hash.items()):
            unique_objects = {(path.stat().st_dev, path.stat().st_ino) for path in matches}
            if len(matches) > 1:
                groups.append({
                    "sha256": digest,
                    "size": size,
                    "paths": [path.relative_to(root).as_posix() for path in sorted(matches)],
                    "stored_objects": len(unique_objects),
                    "hard_links_only": len(unique_objects) == 1,
                })

    hard_links = [paths for paths in inode_paths.values() if len(paths) > 1]
    return {
        "version": PLAN_VERSION,
        "source_root": str(root),
        "generated_at": now(),
        "duplicate_groups": groups,
        "hard_link_groups": sorted(hard_links),
    }


@dataclass(frozen=True)
class Operation:
    source: Path
    destination: Path
    expected: dict[str, Any]


def source_snapshot(path: Path) -> dict[str, Any]:
    info = path.lstat()
    if path.is_symlink():
        kind = "symlink"
    elif path.is_dir():
        kind = "package" if is_package(path) else "directory"
    elif path.is_file():
        kind = "file"
    else:
        kind = "other"
    snapshot: dict[str, Any] = {
        "kind": kind,
        "size": info.st_size,
        "device": info.st_dev,
        "inode": info.st_ino,
        "modified_ns": info.st_mtime_ns,
    }
    if kind == "symlink":
        snapshot["target"] = os.readlink(path)
    return snapshot


def snapshot_matches(path: Path, expected: dict[str, Any]) -> bool:
    try:
        actual = source_snapshot(path)
    except OSError:
        return False
    return actual == expected


def load_plan(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SortyError(f"cannot read plan: {error}") from error
    if not isinstance(value, dict):
        raise SortyError("plan must be a JSON object")
    return value


def resolve_plan(plan: dict[str, Any]) -> tuple[Path, str, list[Operation], list[str]]:
    try:
        imported_exclusion = exclusion_checker()
    except ValueError as error:
        raise SortyError(str(error)) from error
    if plan.get("version") != PLAN_VERSION:
        raise SortyError(f"unsupported plan version: {plan.get('version')!r}")
    mode = plan.get("mode")
    if mode not in MODES:
        raise SortyError(f"unsupported mode: {mode!r}")
    root_value = plan.get("source_root")
    if not isinstance(root_value, str) or not root_value:
        raise SortyError("source_root must be an absolute path")
    if not Path(root_value).expanduser().is_absolute():
        raise SortyError("source_root must be an absolute path")
    root = canonical(Path(root_value))
    reject_broad_root(root)
    if not root.is_dir():
        raise SortyError(f"source root is not a directory: {root}")
    tags = plan.get("tags", [])
    if tags:
        raise SortyError("agent mode cannot mutate Finder tags; use native Sorty")
    exclusions = plan.get("exclusions", [])
    if not isinstance(exclusions, list) or not all(isinstance(pattern, str) for pattern in exclusions):
        raise SortyError("exclusions must be an array of glob strings")
    warnings = plan.get("warnings", [])
    if not isinstance(warnings, list) or not all(isinstance(warning, str) for warning in warnings):
        raise SortyError("warnings must be an array of strings")
    duplicate_groups = plan.get("duplicate_groups", [])
    if not isinstance(duplicate_groups, list):
        raise SortyError("duplicate_groups must be an array")
    unorganized = plan.get("unorganized", [])
    if not isinstance(unorganized, list):
        raise SortyError("unorganized must be an array")

    raw_operations = plan.get("operations")
    if not isinstance(raw_operations, list):
        raise SortyError("operations must be an array")
    operations: list[Operation] = []
    errors: list[str] = []
    seen_sources: set[str] = set()
    seen_destinations: set[str] = set()

    for index, raw in enumerate(raw_operations):
        if (
            not isinstance(raw, dict)
            or not isinstance(raw.get("source"), str)
            or not isinstance(raw.get("destination"), str)
            or not isinstance(raw.get("expected"), dict)
        ):
            errors.append(f"operation {index} must contain string source and destination plus an expected snapshot")
            continue
        source_input = Path(raw["source"])
        destination_input = Path(raw["destination"])
        if has_unsafe_components(source_input) or has_unsafe_components(destination_input):
            errors.append(f"operation {index} contains dot segments or control characters")
        source = canonical(source_input if source_input.is_absolute() else root / source_input)
        destination = canonical(destination_input if destination_input.is_absolute() else root / destination_input)
        if not is_within(source, root):
            errors.append(f"source escapes source_root: {source}")
        elif not is_within(source.parent.resolve(strict=False), root.resolve(strict=False)):
            errors.append(f"source reaches outside source_root through a symlinked parent: {source}")
        else:
            relative_source = source.relative_to(root).as_posix()
            if matches_exclusion(relative_source, exclusions):
                errors.append(f"source matches an exclusion: {relative_source}")
            # Check ancestors and descendants so a directory move cannot carry
            # an imported protected item along with it.
            protected = imported_exclusion(source) or any(
                imported_exclusion(parent) for parent in source.parents if is_within(parent, root)
            )
            if source.is_dir() and not source.is_symlink():
                protected = protected or any(imported_exclusion(child) for child in source.rglob("*"))
            if protected:
                errors.append(f"source contains or matches an imported exclusion: {relative_source}")
        if source == destination:
            errors.append(f"source and destination are identical: {source}")
        source_key = filesystem_key(source)
        if source_key in seen_sources:
            errors.append(f"source appears more than once: {source}")
        destination_key = filesystem_key(destination)
        if destination_key in seen_destinations:
            errors.append(f"destination appears more than once: {destination}")
        destination_is_source = False
        if destination.exists() or destination.is_symlink():
            try:
                destination_is_source = os.path.samefile(source, destination)
            except OSError:
                destination_is_source = False
        if (destination.exists() or destination.is_symlink()) and not destination_is_source:
            errors.append(f"destination already exists: {destination}")
        if not source.exists() and not source.is_symlink():
            errors.append(f"source does not exist: {source}")
        elif not snapshot_matches(source, raw["expected"]):
            errors.append(f"source changed since scan: {source}")
        if not destination_input.is_absolute():
            resolved_parent = nearest_existing_parent(destination.parent).resolve(strict=False)
            if not is_within(resolved_parent, root.resolve(strict=False)):
                errors.append(f"relative destination reaches outside source_root through a symlinked parent: {destination}")
        if mode == "organize" and source.name != destination.name:
            errors.append(f"organize mode cannot rename: {source.name} -> {destination.name}")
        if mode == "renameOnly" and source.parent != destination.parent:
            errors.append(f"renameOnly mode cannot move folders: {source} -> {destination}")
        allow_extension_change = raw.get("allow_extension_change", False)
        if not isinstance(allow_extension_change, bool):
            errors.append(f"allow_extension_change must be boolean for operation {index}")
        elif source.suffix.casefold() != destination.suffix.casefold() and not allow_extension_change:
            errors.append(f"extension change requires explicit allow_extension_change: {source.name} -> {destination.name}")
        if source.is_dir() and is_within(destination, source):
            errors.append(f"cannot move a directory inside itself: {source} -> {destination}")
        seen_sources.add(source_key)
        seen_destinations.add(destination_key)
        operations.append(Operation(source, destination, raw["expected"]))

    operation_source_keys = {filesystem_key(operation.source) for operation in operations}
    unorganized_keys: set[str] = set()
    for index, item in enumerate(unorganized):
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("path"), str)
            or not isinstance(item.get("reason"), str)
            or not item["reason"].strip()
        ):
            errors.append(f"unorganized item {index} must contain string path and a non-empty reason")
            continue
        input_path = Path(item["path"])
        if has_unsafe_components(input_path):
            errors.append(f"unorganized item {index} contains dot segments or control characters")
            continue
        path = canonical(input_path if input_path.is_absolute() else root / input_path)
        if not is_within(path, root):
            errors.append(f"unorganized path escapes source_root: {path}")
            continue
        key = filesystem_key(path)
        if key in unorganized_keys:
            errors.append(f"unorganized path appears more than once: {path}")
        if key in operation_source_keys:
            errors.append(f"path is both organized and unorganized: {path}")
        unorganized_keys.add(key)

    for outer in operations:
        for inner in operations:
            if outer != inner and is_within(inner.source, outer.source):
                errors.append(f"overlapping sources: {outer.source} and {inner.source}")
            if outer != inner and outer.source.is_dir() and is_within(inner.destination, outer.source):
                errors.append(
                    f"destination overlaps another source directory: {inner.destination} inside {outer.source}"
                )
    return root, mode, operations, sorted(set(errors))


def validate_plan(plan_path: Path) -> dict[str, Any]:
    plan = load_plan(plan_path)
    root, mode, operations, errors = resolve_plan(plan)
    return {
        "valid": not errors,
        "version": PLAN_VERSION,
        "source_root": str(root),
        "mode": mode,
        "operation_count": len(operations),
        "errors": errors,
        "operations": [
            {
                "source": str(operation.source),
                "destination": str(operation.destination),
                "expected": operation.expected,
            }
            for operation in operations
        ],
    }


def append_journal(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def copy_then_remove(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.sorty-{uuid.uuid4().hex}.tmp"
    try:
        if source.is_symlink():
            os.symlink(os.readlink(source), temporary)
        elif source.is_dir():
            shutil.copytree(source, temporary, symlinks=True, copy_function=shutil.copy2)
        else:
            shutil.copy2(source, temporary, follow_symlinks=False)
        if content_signature(source) != content_signature(temporary):
            raise SortyError(f"cross-volume verification failed: {source}")
        os.rename(temporary, destination)
        if source.is_dir() and not source.is_symlink():
            shutil.rmtree(source)
        else:
            source.unlink()
    finally:
        if temporary.is_dir() and not temporary.is_symlink():
            shutil.rmtree(temporary, ignore_errors=True)
        elif temporary.exists() or temporary.is_symlink():
            temporary.unlink(missing_ok=True)


def guarded_move(source: Path, destination: Path) -> str:
    if destination.exists() or destination.is_symlink():
        try:
            if not os.path.samefile(source, destination):
                raise SortyError(f"destination already exists: {destination}")
        except OSError as error:
            raise SortyError(f"cannot compare destination safely: {destination}") from error
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(source, destination)
        return "rename"
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    copy_then_remove(source, destination)
    return "verified-copy"


def apply_plan(plan_path: Path, state_dir: Path) -> dict[str, Any]:
    plan = load_plan(plan_path)
    root, mode, operations, errors = resolve_plan(plan)
    if errors:
        raise SortyError("plan validation failed: " + "; ".join(errors))
    apply_id = uuid.uuid4().hex
    journal = canonical(state_dir) / "journals" / f"{apply_id}.jsonl"
    append_journal(journal, {
        "record": "header", "version": PLAN_VERSION, "apply_id": apply_id,
        "created_at": now(), "source_root": str(root), "mode": mode,
        "plan": str(canonical(plan_path)),
    })
    completed = 0
    for index, operation in enumerate(operations):
        if not snapshot_matches(operation.source, operation.expected):
            raise SortyError(f"source changed before operation {index}: {operation.source}")
        operation_id = f"{apply_id}:{index}"
        base = {
            "record": "operation", "operation_id": operation_id,
            "source": str(operation.source), "destination": str(operation.destination),
        }
        append_journal(journal, {**base, "status": "pending", "at": now()})
        method = guarded_move(operation.source, operation.destination)
        append_journal(journal, {**base, "status": "completed", "method": method, "at": now()})
        completed += 1
    append_journal(journal, {"record": "summary", "status": "completed", "completed": completed, "at": now()})
    return {"status": "completed", "apply_id": apply_id, "completed": completed, "journal": str(journal)}


def read_journal(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    except (OSError, json.JSONDecodeError) as error:
        raise SortyError(f"cannot read journal: {error}") from error
    return rows


def rollback(journal: Path) -> dict[str, Any]:
    journal = canonical(journal)
    rows = read_journal(journal)
    completed: dict[str, dict[str, Any]] = {}
    restored = {row.get("operation_id") for row in rows if row.get("status") == "restored"}
    for row in rows:
        if row.get("record") == "operation" and row.get("status") == "completed":
            completed[row["operation_id"]] = row

    restored_count = 0
    errors: list[str] = []
    for row in reversed(list(completed.values())):
        operation_id = row["operation_id"]
        if operation_id in restored:
            continue
        original = Path(row["source"])
        current = Path(row["destination"])
        if original.exists() or original.is_symlink():
            errors.append(f"original path is occupied: {original}")
            continue
        if not current.exists() and not current.is_symlink():
            errors.append(f"moved item is missing: {current}")
            continue
        method = guarded_move(current, original)
        append_journal(journal, {
            "record": "operation", "operation_id": operation_id,
            "source": row["source"], "destination": row["destination"],
            "status": "restored", "method": method, "at": now(),
        })
        restored_count += 1
    status_value = "completed" if not errors else "partial"
    append_journal(journal, {"record": "rollback", "status": status_value, "restored": restored_count, "errors": errors, "at": now()})
    return {"status": status_value, "restored": restored_count, "errors": errors, "journal": str(journal)}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("scan", "duplicates"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("root", type=Path)
        subparser.add_argument("--exclude", action="append", default=[])
        subparser.add_argument("--include-hidden", action="store_true")
        if name == "scan":
            subparser.add_argument("--expand-packages", action="store_true")
    validate = subparsers.add_parser("validate")
    validate.add_argument("plan", type=Path)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("plan", type=Path)
    apply_parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    rollback_parser = subparsers.add_parser("rollback")
    rollback_parser.add_argument("journal", type=Path)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "scan":
            result = scan(arguments.root, arguments.exclude, arguments.include_hidden, arguments.expand_packages)
        elif arguments.command == "duplicates":
            result = exact_duplicates(arguments.root, arguments.exclude, arguments.include_hidden)
        elif arguments.command == "validate":
            result = validate_plan(arguments.plan)
            emit(result)
            return 0 if result["valid"] else 2
        elif arguments.command == "apply":
            result = apply_plan(arguments.plan, arguments.state_dir)
        else:
            result = rollback(arguments.journal)
            emit(result)
            return 0 if result["status"] == "completed" else 3
        emit(result)
        return 0
    except SortyError as error:
        emit({"status": "error", "error": str(error)})
        return 2
    except OSError as error:
        emit({"status": "error", "error": f"filesystem error: {error}"})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
