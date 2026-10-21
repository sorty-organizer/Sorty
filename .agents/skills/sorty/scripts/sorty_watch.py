#!/usr/bin/env python3
"""App-free watched folders for the Sorty skill.

A watcher notices settled new items in a folder's top level; it never decides
where they go. Without a handler, new items are queued for the agent's next
session. With a handler, an AI command the agent configured on this machine
receives the folder's existing structure, the new items, and saved preferences,
and replies with placements that go through the helper's validation, journal,
and rollback path. `install` registers a per-user launchd agent so runs happen
in the background when the folder changes and on a timer. Native Sorty is never
required.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from sorty_helper import (
    PLAN_VERSION,
    SortyError,
    apply_plan,
    canonical,
    emit,
    is_package,
    matches_exclusion,
    now,
    reject_broad_root,
    resolve_plan,
    source_snapshot,
)
from sorty_profile import STATE_DIR, exclusion_checker, load_profile

WATCHER_VERSION = 1
LABEL_PREFIX = "com.sorty.skill.watch."
PARTIAL_SUFFIXES = {".crdownload", ".download", ".part", ".partial", ".opdownload", ".tmp", ".icloud"}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
STRUCTURE_LIMIT = 400
HANDLER_TASK = """You are organizing new items that arrived in a watched folder.
Decide where each item belongs so the folder stays coherent with how this user already organizes it.
Infer their style from `structure` (existing folders and sample names), the item names and contents
you are allowed to read, `prompt`, `preferences`, and `learnings`. Reuse existing folders and naming
patterns before inventing new ones, avoid one-off folders and generic buckets, and leave an item in
`unorganized` with a specific reason when the evidence is weak.
Do not move, rename, delete, or edit anything yourself. Reply with only this JSON object:
{"operations": [{"source": "<item path as given>", "destination": "<path relative to source_root>"}],
 "unorganized": [{"path": "<item path>", "reason": "<why>"}]}
Destinations may rename an item but must keep its extension. Never overwrite an existing path."""


def watchers_dir() -> Path:
    return canonical(Path(STATE_DIR)) / "watchers"


def watcher_dir(watch_id: str) -> Path:
    if not ID_PATTERN.match(watch_id):
        raise SortyError(f"watcher id must be lowercase letters, digits, and hyphens: {watch_id!r}")
    return watchers_dir() / watch_id


def slug(name: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", name.casefold()).strip("-")[:40].strip("-")
    return value or "folder"


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SortyError(f"cannot read {path}: {error}") from error


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_config(watch_id: str) -> dict[str, Any]:
    config = read_json(watcher_dir(watch_id) / "config.json", None)
    if not isinstance(config, dict) or config.get("version") != WATCHER_VERSION:
        raise SortyError(f"no watcher named {watch_id!r}")
    return config


def load_state(watch_id: str) -> dict[str, Any]:
    return read_json(watcher_dir(watch_id) / "state.json", {"seen": {}, "queue": [], "runs": []})


@contextmanager
def watcher_lock(watch_id: str):
    path = watcher_dir(watch_id) / ".lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def exclusion_filter(config: dict[str, Any]):
    try:
        imported_exclusion = exclusion_checker()
    except ValueError as error:
        raise SortyError(str(error)) from error
    def keep(root: Path, path: Path) -> bool:
        relative = path.relative_to(root)
        return not (
            any(part.startswith(".") for part in relative.parts)
            or matches_exclusion(relative.as_posix(), config.get("exclusions", []))
            or imported_exclusion(path)
        )
    return keep


def top_level_items(root: Path, config: dict[str, Any], outputs: list[str] = ()) -> list[Path]:
    """New-item candidates: visible, non-excluded top-level entries, minus folders the watcher created."""
    keep = exclusion_filter(config)
    reserved = set(outputs)
    return [
        root / entry.name
        for entry in sorted(os.scandir(root), key=lambda entry: entry.name)
        if entry.name not in reserved and keep(root, root / entry.name)
    ]


def folder_structure(root: Path, config: dict[str, Any], skip: set[str]) -> list[str]:
    """Sample the folder's existing layout, two levels deep, so the AI can match the user's style."""
    keep = exclusion_filter(config)
    lines: list[str] = []
    def walk(directory: Path, depth: int) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError:
            return
        folders = [entry for entry in entries if entry.is_dir(follow_symlinks=False) and not is_package(Path(entry.path))]
        files = [entry for entry in entries if entry not in folders]
        for entry in folders:
            path = Path(entry.path)
            if len(lines) >= STRUCTURE_LIMIT or (depth == 0 and entry.name in skip) or not keep(root, path):
                continue
            lines.append(path.relative_to(root).as_posix() + "/")
            if depth < 1:
                walk(path, depth + 1)
        samples = [entry for entry in files if (depth > 0 or entry.name not in skip) and keep(root, Path(entry.path))]
        for entry in samples[:8]:
            if len(lines) < STRUCTURE_LIMIT:
                lines.append(Path(entry.path).relative_to(root).as_posix())
        if len(samples) > 8 and len(lines) < STRUCTURE_LIMIT:
            lines.append(f"{directory.relative_to(root).as_posix() or '.'}/… {len(samples) - 8} more files")
    walk(root, 0)
    return lines


def is_settled(path: Path, settle_seconds: int) -> bool:
    if path.suffix.casefold() in PARTIAL_SUFFIXES:
        return False
    return time.time() - path.lstat().st_mtime >= settle_seconds


def notify(title: str, message: str) -> bool:
    """Post a best-effort desktop notification; returns False when none could be shown."""
    try:
        if sys.platform == "darwin":
            command = [
                "osascript", "-e", "on run argv", "-e",
                "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run",
                message, title,
            ]
        elif shutil.which("notify-send"):
            command = ["notify-send", title, message]
        else:
            return False
        return subprocess.run(command, capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def add_watcher(arguments: argparse.Namespace) -> dict[str, Any]:
    root = canonical(Path(arguments.path))
    reject_broad_root(root)
    if not root.is_dir():
        raise SortyError(f"watched path is not a directory: {root}")
    watch_id = arguments.id or slug(root.name)
    directory = watcher_dir(watch_id)
    existing = read_json(directory / "config.json", None)
    if existing and not arguments.replace:
        raise SortyError(f"watcher {watch_id!r} already exists; pass --replace to update it")
    handler = shlex.split(arguments.handler) if arguments.handler else None
    if handler:
        # Store an absolute path: background runs do not get the interactive shell's PATH.
        executable = shutil.which(handler[0])
        if not executable:
            raise SortyError(f"handler command not found: {handler[0]}")
        handler[0] = executable
    if arguments.apply and not handler:
        raise SortyError("--apply needs a --handler that decides placements")
    config = {
        "version": WATCHER_VERSION,
        "id": watch_id,
        "name": arguments.name or root.name,
        "path": str(root),
        "action": "apply" if arguments.apply else "queue",
        "handler": handler,
        "handler_timeout": arguments.handler_timeout,
        "exclusions": arguments.exclude,
        "prompt": arguments.prompt,
        "settle_seconds": arguments.settle,
        "interval_seconds": arguments.interval,
        "notify": not arguments.no_notify,
        "enabled": True,
        "paused_until": None,
        "created_at": (existing or {}).get("created_at", now()),
        "updated_at": now(),
    }
    with watcher_lock(watch_id):
        write_json(directory / "config.json", config)
        state = load_state(watch_id)
        if not existing and not arguments.include_existing:
            # Baseline: only items that arrive after the watcher is added are new.
            state["seen"] = {path.name: path.lstat().st_ino for path in top_level_items(root, config)}
        write_json(directory / "state.json", state)
    return {"status": "saved", "watcher": config, "baselined": len(state["seen"])}


def import_profile_watchers() -> dict[str, Any]:
    """Create queue-only watchers from folders imported from the app. Import never authorizes apply."""
    created, skipped = [], []
    for folder in load_profile().get("watchedFolders", []):
        path = Path(folder.get("path", "")).expanduser()
        watch_id = slug(folder.get("name") or path.name)
        if (watcher_dir(watch_id) / "config.json").exists() or not path.is_dir():
            skipped.append({"id": watch_id, "path": str(path), "reason": "exists" if path.is_dir() else "path not found"})
            continue
        add_watcher(argparse.Namespace(
            path=str(path), id=watch_id, name=folder.get("name"), replace=False, handler=None, handler_timeout=600,
            apply=False, exclude=[], prompt=folder.get("customPrompt"), settle=60, interval=1800, no_notify=False,
            include_existing=False,
        ))
        created.append(watch_id)
    return {"created": created, "skipped": skipped}


def run_watcher(watch_id: str, dry_run: bool = False, settle_wait: bool = False) -> dict[str, Any]:
    config = load_config(watch_id)
    with watcher_lock(watch_id) as acquired:
        if not acquired:
            return {"id": watch_id, "status": "busy"}
        if not config.get("enabled", True):
            return {"id": watch_id, "status": "disabled"}
        paused_until = config.get("paused_until")
        if paused_until and datetime.fromisoformat(paused_until) > datetime.now(timezone.utc):
            return {"id": watch_id, "status": "paused", "paused_until": paused_until}
        state = load_state(watch_id)
        result = scan_once(config, state, dry_run)
        # Background runs wait briefly for in-flight downloads instead of leaving them for the timer.
        attempts = 0
        while settle_wait and not dry_run and result["waiting"] and attempts < 3:
            time.sleep(min(config["settle_seconds"], 120) + 1)
            result = merge_runs(result, scan_once(config, state, dry_run))
            attempts += 1
        if not dry_run:
            state["runs"] = [*state.get("runs", []), result][-20:]
            write_json(watcher_dir(watch_id) / "state.json", state)
            if config.get("notify", True) and (result["moved"] or result["queued"] or result.get("error")):
                notify(f"Sorty · {config['name']}", summary_text(result))
        return result


def merge_runs(first: dict[str, Any], second: dict[str, Any]) -> dict[str, Any]:
    return {
        **second,
        "moved": first["moved"] + second["moved"],
        "queued": first["queued"] + second["queued"],
        "journals": first["journals"] + second["journals"],
        "error": second.get("error") or first.get("error"),
    }


def summary_text(result: dict[str, Any]) -> str:
    if result.get("error"):
        return f"Needs attention: {result['error']}"
    parts = []
    if result["moved"]:
        parts.append(f"Organized {len(result['moved'])}")
    if result["queued"]:
        parts.append(f"{len(result['queued'])} waiting for review")
    return " · ".join(parts)


def scan_once(config: dict[str, Any], state: dict[str, Any], dry_run: bool) -> dict[str, Any]:
    root = Path(config["path"])
    result: dict[str, Any] = {
        "id": config["id"], "at": now(), "status": "completed", "dry_run": dry_run,
        "moved": [], "queued": [], "waiting": [], "journals": [], "error": None,
    }
    if not root.is_dir():
        result.update(status="error", error=f"watched folder is missing: {root}")
        return result
    outputs = state.get("output_folders", [])
    try:
        items = top_level_items(root, config, outputs)
    except (SortyError, OSError) as error:
        result.update(status="error", error=str(error))
        return result

    seen: dict[str, int] = state.setdefault("seen", {})
    current: dict[str, int] = {}
    new_items: list[Path] = []
    for path in items:
        info = path.lstat()
        if not is_settled(path, config["settle_seconds"]):
            result["waiting"].append(path.name)
            continue
        current[path.name] = info.st_ino
        if seen.get(path.name) != info.st_ino:
            new_items.append(path)

    operations: list[dict[str, Any]] = []
    queued: list[dict[str, str]] = []
    if new_items and config.get("handler"):
        try:
            suggested, queued = ask_handler(config, root, new_items)
            if config["action"] == "apply":
                operations = suggested
            else:
                queued.extend({"path": op["source"], "reason": f"AI suggests {op['destination']}; watcher is review-only"}
                              for op in suggested)
        except SortyError as error:
            result.update(status="error", error=str(error))
            queued = [{"path": path.name, "reason": "handler failed"} for path in new_items]
    else:
        queued = [{"path": path.name, "reason": "waiting for the agent to organize"} for path in new_items]

    if dry_run:
        result["moved"] = [{"source": op["source"], "destination": op["destination"]} for op in operations]
        result["queued"] = queued
        return result

    if operations:
        plan = {
            "version": PLAN_VERSION, "source_root": str(root),
            "mode": "organizeAndRename" if any(Path(op["source"]).name != Path(op["destination"]).name for op in operations) else "organize",
            "operations": operations, "tags": [], "exclusions": config.get("exclusions", []),
            "duplicate_groups": [], "unorganized": [], "warnings": [f"watcher:{config['id']}"],
        }
        plan_path = watcher_dir(config["id"]) / "plans" / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}.json"
        write_json(plan_path, plan)
        try:
            _, _, _, errors = resolve_plan(plan)
            if errors:
                raise SortyError("; ".join(errors))
            applied = apply_plan(plan_path, Path(STATE_DIR), origin=f"watcher:{config['id']}")
            result["journals"].append(applied["journal"])
            result["moved"] = [{"source": op["source"], "destination": op["destination"]} for op in operations]
            created = {Path(op["destination"]).parts[0] for op in operations
                       if not Path(op["destination"]).is_absolute() and len(Path(op["destination"]).parts) > 1
                       and Path(op["destination"]).parts[0] not in current}
            state["output_folders"] = sorted(set(outputs) | created)
        except (SortyError, OSError) as error:
            result.update(status="error", error=f"apply stopped: {error}. Check `sorty_helper.py history` before retrying.")
            queued.extend({"path": op["source"], "reason": "apply failed"} for op in operations if (root / op["source"]).exists())

    # Moved items leave the folder; queued and untouched ones stay seen so they are reported once.
    state["seen"] = {name: inode for name, inode in {**seen, **current}.items() if (root / name).exists()}
    queue = [entry for entry in state.get("queue", []) if (root / entry["path"]).exists()]
    known = {entry["path"] for entry in queue}
    for entry in queued:
        if entry["path"] not in known:
            queue.append({**entry, "detected_at": result["at"]})
    state["queue"] = queue
    result["queued"] = queued
    return result


def handler_request(config: dict[str, Any], root: Path, paths: list[Path]) -> dict[str, Any]:
    profile = load_profile()
    return {
        "task": HANDLER_TASK,
        "source_root": str(root),
        "prompt": config.get("prompt") or profile.get("preferences", {}).get("instructions"),
        "preferences": profile.get("preferences", {}),
        "learnings": {"agent": profile.get("agentLearnings", []), "imported": profile.get("learnings", {})},
        "structure": folder_structure(root, config, {path.name for path in paths}),
        "items": [
            {
                "path": path.name,
                "kind": "package" if is_package(path) else "directory" if path.is_dir() else "file",
                "size": path.lstat().st_size,
                "modified_at": datetime.fromtimestamp(path.lstat().st_mtime, timezone.utc).isoformat(),
            }
            for path in paths
        ],
    }


def parse_handler_output(text: str) -> dict[str, Any]:
    """Accept bare JSON or JSON wrapped in prose or a code fence, as model CLIs often print."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            raise SortyError("handler printed no JSON object") from None
        try:
            value = json.loads(text[start:end + 1])
        except json.JSONDecodeError as error:
            raise SortyError(f"handler printed invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise SortyError("handler output must be a JSON object")
    return value


def ask_handler(config: dict[str, Any], root: Path, paths: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Ask the watcher's AI handler where new items go.

    The handler gets one JSON request on stdin (see `handler_request`) with the working
    directory set to the watched folder, and prints placements. Snapshots are taken
    first, so anything the handler touches itself makes the plan fail validation.
    Items it omits are queued; everything it proposes is still checked by the helper.
    """
    snapshots = {path.name: source_snapshot(path) for path in paths}
    payload = json.dumps(handler_request(config, root, paths), indent=2)
    try:
        completed = subprocess.run(
            config["handler"], input=payload, capture_output=True, text=True,
            timeout=config.get("handler_timeout", 600), cwd=str(root),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise SortyError(f"handler could not run: {error}") from error
    if completed.returncode != 0:
        raise SortyError(f"handler exited {completed.returncode}: {completed.stderr.strip()[:300]}")
    output = parse_handler_output(completed.stdout)
    operations, unorganized, handled = [], [], set()
    for raw in output.get("operations") or []:
        source = raw.get("source") if isinstance(raw, dict) else None
        destination = raw.get("destination") if isinstance(raw, dict) else None
        if source not in snapshots or source in handled or not isinstance(destination, str) or not destination.strip():
            raise SortyError(f"handler returned an invalid operation: {raw!r}")
        handled.add(source)
        target = Path(destination).expanduser()
        if target == Path(source):
            unorganized.append({"path": source, "reason": "AI left it in place"})
        elif (target if target.is_absolute() else root / target).exists():
            unorganized.append({"path": source, "reason": f"destination already exists: {destination}"})
        else:
            operations.append({"source": source, "destination": str(target), "expected": snapshots[source]})
    for raw in output.get("unorganized") or []:
        if isinstance(raw, dict) and raw.get("path") in snapshots and raw["path"] not in handled:
            handled.add(raw["path"])
            unorganized.append({"path": raw["path"], "reason": str(raw.get("reason") or "left by the AI")})
    unorganized.extend({"path": name, "reason": "AI did not place it"} for name in snapshots if name not in handled)
    return operations, unorganized


def update_queue(watch_id: str, resolve: list[str], clear: bool) -> dict[str, Any]:
    with watcher_lock(watch_id):
        state = load_state(watch_id)
        if clear:
            state["queue"] = []
        elif resolve:
            state["queue"] = [entry for entry in state.get("queue", []) if entry["path"] not in set(resolve)]
        if clear or resolve:
            write_json(watcher_dir(watch_id) / "state.json", state)
    config = load_config(watch_id)
    return {"id": watch_id, "path": config["path"], "prompt": config.get("prompt"), "queue": state.get("queue", [])}


def set_paused(watch_id: str, minutes: int | None, paused: bool) -> dict[str, Any]:
    with watcher_lock(watch_id):
        config = load_config(watch_id)
        if paused and minutes:
            config["paused_until"] = (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()
            config["enabled"] = True
        else:
            config["paused_until"] = None
            config["enabled"] = not paused
        config["updated_at"] = now()
        write_json(watcher_dir(watch_id) / "config.json", config)
    return {"id": watch_id, "enabled": config["enabled"], "paused_until": config["paused_until"]}


def launch_agent_path(watch_id: str) -> Path:
    return Path.home() / "Library/LaunchAgents" / f"{LABEL_PREFIX}{watch_id}.plist"


def launchctl(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["launchctl", *arguments], capture_output=True, text=True)


def is_loaded(watch_id: str) -> bool:
    if sys.platform != "darwin":
        return False
    return launchctl("print", f"gui/{os.getuid()}/{LABEL_PREFIX}{watch_id}").returncode == 0


def install_watcher(watch_id: str) -> dict[str, Any]:
    """Register a per-user launchd agent that runs this watcher on folder changes and on a timer."""
    config = load_config(watch_id)
    script = Path(__file__).resolve()
    if sys.platform != "darwin":
        return {
            "id": watch_id, "status": "manual",
            "message": "Background items are only automated on macOS. Add this line with `crontab -e`:",
            "cron": f"*/{max(1, config['interval_seconds'] // 60)} * * * * {sys.executable} {script} run {watch_id}",
        }
    log = watcher_dir(watch_id) / "background.log"
    # Keep the installer's PATH so handlers written for Node or Homebrew tools still resolve.
    environment = {"PATH": os.environ.get("PATH") or "/usr/bin:/bin:/usr/sbin:/sbin"}
    if os.environ.get("SORTY_SKILL_STATE_DIR"):
        environment["SORTY_SKILL_STATE_DIR"] = os.environ["SORTY_SKILL_STATE_DIR"]
    plist = {
        "Label": f"{LABEL_PREFIX}{watch_id}",
        "ProgramArguments": [sys.executable, str(script), "run", watch_id, "--settle-wait"],
        "WatchPaths": [config["path"]],
        "StartInterval": config["interval_seconds"],
        "ThrottleInterval": 10,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "EnvironmentVariables": environment,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
    }
    path = launch_agent_path(watch_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(plist, handle)
    domain = f"gui/{os.getuid()}"
    launchctl("bootout", f"{domain}/{LABEL_PREFIX}{watch_id}")
    loaded = launchctl("bootstrap", domain, str(path))
    if loaded.returncode != 0:
        raise SortyError(f"launchctl bootstrap failed: {loaded.stderr.strip() or loaded.returncode}")
    return {"id": watch_id, "status": "installed", "launch_agent": str(path), "log": str(log)}


def uninstall_watcher(watch_id: str) -> dict[str, Any]:
    path = launch_agent_path(watch_id)
    if sys.platform == "darwin":
        launchctl("bootout", f"gui/{os.getuid()}/{LABEL_PREFIX}{watch_id}")
    removed = path.exists()
    path.unlink(missing_ok=True)
    return {"id": watch_id, "status": "uninstalled" if removed else "not installed"}


def remove_watcher(watch_id: str) -> dict[str, Any]:
    load_config(watch_id)
    background = uninstall_watcher(watch_id)
    shutil.rmtree(watcher_dir(watch_id))
    return {"id": watch_id, "status": "removed", "background": background["status"], "journals_kept": True}


def describe(watch_id: str) -> dict[str, Any]:
    config = load_config(watch_id)
    state = load_state(watch_id)
    runs = state.get("runs", [])
    return {
        **config,
        "background_installed": launch_agent_path(watch_id).exists(),
        "background_loaded": is_loaded(watch_id),
        "queue_count": len(state.get("queue", [])),
        "last_run": runs[-1] if runs else None,
        "path_exists": Path(config["path"]).is_dir(),
    }


def all_ids() -> list[str]:
    directory = watchers_dir()
    return sorted(path.name for path in directory.iterdir() if (path / "config.json").exists()) if directory.is_dir() else []


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add", help="save a watched folder")
    add.add_argument("path")
    add.add_argument("--id")
    add.add_argument("--name")
    add.add_argument("--handler", help="AI command that decides placements, e.g. a non-interactive agent CLI")
    add.add_argument("--handler-timeout", type=int, default=600, help="seconds before the handler is stopped")
    add.add_argument("--apply", action="store_true", help="apply the handler's placements unattended (needs explicit approval)")
    add.add_argument("--exclude", action="append", default=[])
    add.add_argument("--prompt", help="saved instructions for reviewing this folder's queue")
    add.add_argument("--settle", type=int, default=60, help="seconds an item must be unchanged")
    add.add_argument("--interval", type=int, default=1800, help="background timer in seconds")
    add.add_argument("--no-notify", action="store_true")
    add.add_argument("--include-existing", action="store_true", help="treat current items as new")
    add.add_argument("--replace", action="store_true")
    commands.add_parser("import-profile", help="create queue-only watchers from imported app folders")
    run = commands.add_parser("run", help="process new items once")
    run.add_argument("id", nargs="?")
    run.add_argument("--all", action="store_true")
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("--settle-wait", action="store_true", help=argparse.SUPPRESS)
    commands.add_parser("list")
    for name in ("status", "install", "uninstall", "remove", "resume"):
        commands.add_parser(name).add_argument("id")
    pause = commands.add_parser("pause")
    pause.add_argument("id")
    pause.add_argument("--minutes", type=int, help="snooze for this long instead of pausing until resumed")
    queue = commands.add_parser("queue", help="show or resolve items waiting for review")
    queue.add_argument("id")
    queue.add_argument("--resolve", action="append", default=[], metavar="NAME")
    queue.add_argument("--clear", action="store_true")
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        command = arguments.command
        if command == "add":
            result = add_watcher(arguments)
        elif command == "import-profile":
            result = import_profile_watchers()
        elif command == "run":
            if arguments.all == bool(arguments.id):
                raise SortyError("pass a watcher id or --all")
            ids = all_ids() if arguments.all else [arguments.id]
            runs = [run_watcher(watch_id, arguments.dry_run, arguments.settle_wait) for watch_id in ids]
            result = runs[0] if arguments.id else {"runs": runs}
            emit(result)
            return 3 if any(run.get("status") == "error" for run in runs) else 0
        elif command == "list":
            result = {"state_dir": str(canonical(Path(STATE_DIR))), "watchers": [describe(watch_id) for watch_id in all_ids()]}
        elif command == "status":
            result = describe(arguments.id)
        elif command == "install":
            result = install_watcher(arguments.id)
        elif command == "uninstall":
            result = uninstall_watcher(arguments.id)
        elif command == "remove":
            result = remove_watcher(arguments.id)
        elif command == "pause":
            result = set_paused(arguments.id, arguments.minutes, paused=True)
        elif command == "resume":
            result = set_paused(arguments.id, None, paused=False)
        else:
            result = update_queue(arguments.id, arguments.resolve, arguments.clear)
        emit(result)
        return 0
    except (SortyError, ValueError) as error:
        emit({"status": "error", "error": str(error)})
        return 2
    except OSError as error:
        emit({"status": "error", "error": f"filesystem error: {error}"})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
