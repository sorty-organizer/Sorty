#!/usr/bin/env python3
"""App-free watched folders for the Sorty skill.

A watcher is a saved folder plus rules. Each `run` looks at the folder's top-level
items once: settled new items that match an approved rule are moved through the
helper's guarded, journaled apply, and everything else is queued for the agent's
next session. When glob rules are not expressive enough, an agent can write a
routing script on the user's machine; its JSON output goes through the same
validation, journal, and rollback path. `install` registers a per-user launchd agent so runs happen in the
background when the folder changes and on a timer. Native Sorty is never required.
"""

from __future__ import annotations

import argparse
import fcntl
import fnmatch
import json
import os
import plistlib
import re
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
    has_unsafe_components,
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


def parse_rule(value: str) -> dict[str, str]:
    """Parse `GLOB=DESTINATION`, where the glob matches top-level item names case-insensitively."""
    if "=" not in value:
        raise SortyError(f"rule must look like GLOB=DESTINATION: {value!r}")
    pattern, destination = (part.strip() for part in value.split("=", 1))
    if not pattern or not destination:
        raise SortyError(f"rule must look like GLOB=DESTINATION: {value!r}")
    destination_path = Path(destination).expanduser()
    if has_unsafe_components(destination_path):
        raise SortyError(f"rule destination contains dot segments or control characters: {destination}")
    return {"match": pattern, "destination": str(destination_path)}


def top_level_items(root: Path, config: dict[str, Any], outputs: list[str] = ()) -> list[Path]:
    try:
        imported_exclusion = exclusion_checker()
    except ValueError as error:
        raise SortyError(str(error)) from error
    reserved = rule_folders(config) | set(outputs)
    items = []
    for entry in sorted(os.scandir(root), key=lambda entry: entry.name):
        path = root / entry.name
        if entry.name.startswith(".") or entry.name in reserved:
            continue
        if matches_exclusion(entry.name, config.get("exclusions", [])) or imported_exclusion(path):
            continue
        items.append(path)
    return items


def rule_folders(config: dict[str, Any]) -> set[str]:
    """Top-level folders that rules move items into, so a watcher never queues its own output."""
    return {
        Path(rule["destination"]).parts[0]
        for rule in config.get("rules", [])
        if not Path(rule["destination"]).is_absolute()
    }


def is_settled(path: Path, settle_seconds: int) -> bool:
    if path.suffix.casefold() in PARTIAL_SUFFIXES:
        return False
    return time.time() - path.lstat().st_mtime >= settle_seconds


def matching_rule(name: str, rules: list[dict[str, str]]) -> dict[str, str] | None:
    folded = name.casefold()
    return next((rule for rule in rules if fnmatch.fnmatchcase(folded, rule["match"].casefold())), None)


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
    rules = [parse_rule(value) for value in arguments.rule]
    script = str(canonical(Path(arguments.script))) if arguments.script else None
    if script and not os.access(script, os.X_OK):
        raise SortyError(f"routing script must exist and be executable: {script}")
    if arguments.apply and not (rules or script):
        raise SortyError("--apply needs at least one --rule or a --script")
    config = {
        "version": WATCHER_VERSION,
        "id": watch_id,
        "name": arguments.name or root.name,
        "path": str(root),
        "action": "apply" if arguments.apply else "queue",
        "rules": rules,
        "script": script,
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
            path=str(path), id=watch_id, name=folder.get("name"), replace=False, rule=[], apply=False,
            exclude=[], prompt=folder.get("customPrompt"), settle=60, interval=1800, no_notify=False,
            include_existing=False, script=None,
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
        parts.append(f"Moved {len(result['moved'])}")
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
    try:
        items = top_level_items(root, config, state.get("output_folders", []))
    except (SortyError, OSError) as error:
        result.update(status="error", error=str(error))
        return result

    seen: dict[str, int] = state.setdefault("seen", {})
    current: dict[str, int] = {}
    operations: list[dict[str, Any]] = []
    queued: list[dict[str, str]] = []
    scripted: list[Path] = []
    for path in items:
        info = path.lstat()
        if not is_settled(path, config["settle_seconds"]):
            result["waiting"].append(path.name)
            continue
        current[path.name] = info.st_ino
        if seen.get(path.name) == info.st_ino:
            continue
        rule = matching_rule(path.name, config.get("rules", []))
        if rule is None and config.get("script"):
            scripted.append(path)
        elif path.is_dir() and not is_package(path):
            queued.append({"path": path.name, "reason": "new folder needs review"})
        elif rule is None:
            queued.append({"path": path.name, "reason": "no rule matched"})
        elif config["action"] != "apply":
            queued.append({"path": path.name, "reason": f"matches {rule['match']} but this watcher is queue-only"})
        else:
            destination_folder = Path(rule["destination"])
            destination = (destination_folder if destination_folder.is_absolute() else root / destination_folder) / path.name
            if destination.exists() or destination.is_symlink():
                queued.append({"path": path.name, "reason": f"destination already exists: {destination}"})
            else:
                operations.append({
                    "source": path.name,
                    "destination": str(destination if destination_folder.is_absolute() else destination.relative_to(root)),
                    "expected": source_snapshot(path),
                })

    if scripted:
        try:
            routed, unrouted = run_routing_script(config, root, scripted)
            if config["action"] == "apply":
                operations.extend(routed)
            else:
                unrouted.extend({"path": op["source"], "reason": f"script suggests {op['destination']} but this watcher is queue-only"} for op in routed)
            queued.extend(unrouted)
        except SortyError as error:
            result["error"] = str(error)
            queued.extend({"path": path.name, "reason": "routing script failed"} for path in scripted)

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
            outputs = {Path(op["destination"]).parts[0] for op in operations
                       if not Path(op["destination"]).is_absolute() and len(Path(op["destination"]).parts) > 1}
            state["output_folders"] = sorted(set(state.get("output_folders", [])) | outputs)
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


def run_routing_script(config: dict[str, Any], root: Path, paths: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Ask the watcher's agent-written script where new items go.

    The script reads `{"source_root", "prompt", "items": [{"path", "kind", "size", "modified_at"}]}`
    on stdin and prints `{"operations": [{"source", "destination"}], "unorganized": [{"path", "reason"}]}`.
    Items it omits are queued. Sources must be items it was given; everything else is checked by the helper.
    """
    items = {
        path.name: {
            "path": path.name,
            "kind": "package" if is_package(path) else "directory" if path.is_dir() else "file",
            "size": path.lstat().st_size,
            "modified_at": datetime.fromtimestamp(path.lstat().st_mtime, timezone.utc).isoformat(),
        }
        for path in paths
    }
    payload = json.dumps({"source_root": str(root), "prompt": config.get("prompt"), "items": list(items.values())})
    try:
        completed = subprocess.run(
            [config["script"]], input=payload, capture_output=True, text=True, timeout=120, cwd=str(root),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise SortyError(f"routing script could not run: {error}") from error
    if completed.returncode != 0:
        raise SortyError(f"routing script exited {completed.returncode}: {completed.stderr.strip()[:300]}")
    try:
        output = json.loads(completed.stdout or "{}")
        raw_operations = output.get("operations", [])
        raw_unorganized = output.get("unorganized", [])
    except (json.JSONDecodeError, AttributeError) as error:
        raise SortyError(f"routing script printed invalid JSON: {error}") from error
    operations, unorganized, handled = [], [], set()
    for raw in raw_operations:
        source = raw.get("source") if isinstance(raw, dict) else None
        destination = raw.get("destination") if isinstance(raw, dict) else None
        if source not in items or source in handled or not isinstance(destination, str) or not destination:
            raise SortyError(f"routing script returned an invalid operation: {raw!r}")
        handled.add(source)
        target = Path(destination).expanduser()
        if (target if target.is_absolute() else root / target).exists():
            unorganized.append({"path": source, "reason": f"destination already exists: {destination}"})
            continue
        operations.append({"source": source, "destination": str(target), "expected": source_snapshot(root / source)})
    for raw in raw_unorganized:
        if isinstance(raw, dict) and raw.get("path") in items and raw["path"] not in handled:
            handled.add(raw["path"])
            unorganized.append({"path": raw["path"], "reason": str(raw.get("reason") or "left by routing script")})
    unorganized.extend({"path": name, "reason": "routing script did not place it"} for name in items if name not in handled)
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
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
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
    add.add_argument("--rule", action="append", default=[], help="GLOB=DESTINATION, first match wins")
    add.add_argument("--apply", action="store_true", help="move rule matches unattended (needs explicit approval)")
    add.add_argument("--script", help="agent-written executable that routes items rules do not match")
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
