#!/usr/bin/env python3
"""Local, selective migration from Sorty to any agent using this skill."""

import argparse
import json
import os
import plistlib
import secrets
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


STATE_DIR = Path(os.environ.get("SORTY_SKILL_STATE_DIR", str(
    Path.home() / "Library/Application Support/Sorty Skill" if sys.platform == "darwin"
    else Path.home() / ".config/sorty-skill"
)))
PROFILE_PATH = STATE_DIR / "profile.json"
CONFIG_KEYS = (
    "mode", "enableDeepScan", "enableSmartRename", "detectDuplicates",
    "strictExclusions", "enableVision", "namingStyle", "renameNamingOptions",
    "customNamingInstructions", "renameRules", "renameRuleMode",
    "systemPromptOverride",
)
FOLDER_KEYS = (
    "id", "path", "name", "isEnabled", "autoOrganize", "triggerDelay",
    "snoozedUntil", "customPrompt", "organizationMode", "applyPolicy",
)
RULE_KEYS = (
    "id", "type", "pattern", "isEnabled", "description", "conditionGroupID",
    "pathMatchMode", "numericValue", "comparisonGreater", "caseSensitive",
    "negated", "fileTypeCategory", "ageIntervalSeconds", "ageUnit", "sizeUnit",
)
LEARNING_KEYS = (
    "inferredRules", "guidingInstructionsHistory", "additionalInstructionsHistory",
    "corrections", "rejections", "positiveExamples", "learningExclusionPatterns",
)


def decoded(value, fallback):
    if isinstance(value, bytes):
        return json.loads(value)
    return fallback if value is None else value


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


def watched_folders(support, defaults):
    journal = support / "WatchedFolders.jsonl"
    if not journal.exists():
        return decoded(defaults.get("watchedFolders"), [])
    folders = {}
    seen = set()
    for line in journal.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        identifier = row["id"]
        if row["operation"] == "upsert":
            seen.add(identifier)
            folders[identifier] = row["folder"]
        elif row["operation"] == "remove":
            seen.add(identifier)
            folders.pop(identifier, None)
        elif row["operation"] == "disableAll":
            for folder in folders.values():
                folder.update(isEnabled=False, autoOrganize=False)
        else:
            raise ValueError("Unknown watched-folder journal operation")
    for folder in decoded(defaults.get("watchedFolders"), []):
        if folder["id"] not in seen:
            folders[folder["id"]] = folder
    return list(folders.values())


def collect(defaults, support, learnings=None):
    """Allowlist app data before it enters either the page or the skill profile."""
    config = decoded(defaults.get("aiConfig"), {})
    result = {
        "preferences": {key: config[key] for key in CONFIG_KEYS if key in config},
        "exclusions": [{key: row[key] for key in RULE_KEYS if key in row}
                       for row in decoded(defaults.get("exclusionRules"), [])],
        "watchedFolders": [{key: row[key] for key in FOLDER_KEYS if key in row}
                           for row in watched_folders(support, defaults)],
        "naturalLanguageExceptions": [{key: row[key] for key in ("id", "text", "isEnabled") if key in row}
                                      for row in decoded(defaults.get("naturalLanguageExceptions"), [])],
        "learnings": {},
    }
    reveal = "automation.autoSelectOrganizedFolders"
    if reveal in defaults:
        result["preferences"]["openFolderAfterOrganization"] = bool(defaults[reveal])
    if learnings is not None:
        if "schemaVersion" in learnings and learnings["schemaVersion"] not in (1, 2):
            raise ValueError("Unsupported Learnings archive version")
        profile = learnings.get("profile", learnings)
        if not isinstance(profile, dict) or not any(key in profile for key in LEARNING_KEYS):
            raise ValueError("Choose a Sorty Learnings JSON export, not an encrypted .learning file")
        result["learnings"] = {key: profile[key] for key in LEARNING_KEYS if key in profile}
    return result


def choices(candidate):
    rows = []
    for category, values in candidate.items():
        iterator = values.items() if isinstance(values, dict) else enumerate(values)
        for key, value in iterator:
            if isinstance(value, dict):
                label = value.get("name") or value.get("description") or value.get("text") or value.get("pattern") or str(key)
            else:
                label = str(key)
            rows.append({"id": f"{category}:{key}", "category": category,
                         "key": key, "label": label, "value": value})
    return rows


def save_selection(candidate, selected, destination):
    rows = choices(candidate)
    known = {row["id"] for row in rows}
    if not isinstance(selected, list) or not all(isinstance(item, str) for item in selected) or set(selected) - known:
        raise ValueError("Invalid import selection")
    imported = {key: {} if isinstance(value, dict) else [] for key, value in candidate.items()}
    for row in rows:
        if row["id"] not in selected:
            continue
        bucket = imported[row["category"]]
        if isinstance(bucket, dict):
            bucket[row["key"]] = row["value"]
        else:
            bucket.append(row["value"])
    # AND groups are indivisible, including disabled members of the original group.
    selected_rules = imported["exclusions"]
    groups = {rule.get("conditionGroupID") for rule in selected_rules} - {None}
    for group in groups:
        if any(rule not in selected_rules for rule in candidate["exclusions"]
               if rule.get("conditionGroupID") == group):
            raise ValueError("Select every rule in an exclusion group, or leave the whole group unselected")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    previous = None
    if destination.exists():
        previous = destination.with_name(f"profile-backup-{secrets.token_hex(6)}.json")
        previous.write_bytes(destination.read_bytes())
        previous.chmod(0o600)
    fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix=".profile-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump({"version": 1, **imported}, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"saved": str(destination), "selected": len(selected),
            "backup": str(previous) if previous else None}


def serve(candidate, destination, port=0):
    token = secrets.token_urlsafe(32)
    page = (Path(__file__).parent.parent / "assets/onboarding.html").read_bytes()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, code, body, mime="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", mime)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}" and self.headers.get("X-Sorty-Token") == token

        def do_GET(self):
            if self.path == "/":
                self.reply(200, page, "text/html; charset=utf-8")
            elif self.path == "/candidate" and self.authorized():
                self.reply(200, json.dumps(choices(candidate)).encode())
            else:
                self.reply(403, b'{}')

        def do_POST(self):
            if not self.authorized() or self.path not in ("/import", "/cancel"):
                self.reply(403, b'{}')
                return
            if self.path == "/cancel":
                self.reply(200, b'{}')
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 65536:
                    raise ValueError("Invalid request size")
                selected = json.loads(self.rfile.read(length))
                result = save_selection(candidate, selected, destination)
                self.reply(200, json.dumps(result).encode())
                print(json.dumps(result), flush=True)
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            except (ValueError, OSError) as error:
                self.reply(400, json.dumps({"error": str(error)}).encode())

    with HTTPServer(("127.0.0.1", port), Handler) as server:
        print(f"Open this local onboarding page: http://127.0.0.1:{server.server_port}/#{token}", flush=True)
        print("Press Ctrl+C to cancel. No settings are saved until you click Import.", flush=True)
        server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("onboard", "show"))
    parser.add_argument("--defaults", type=Path, help="Exported Sorty defaults plist")
    parser.add_argument("--support-dir", type=Path, default=Path.home() / "Library/Application Support/Sorty")
    parser.add_argument("--learnings", type=Path, help="Sorty's exported .learnings or JSON archive")
    parser.add_argument("--profile", type=Path, default=PROFILE_PATH)
    args = parser.parse_args()
    try:
        if args.command == "show":
            print(args.profile.read_text() if args.profile.exists() else '{"version": 1}')
            return
        if args.defaults:
            defaults = plistlib.loads(args.defaults.read_bytes())
        elif sys.platform == "darwin":
            exported = subprocess.run(["defaults", "export", "com.sorty.app", "-"], capture_output=True)
            defaults = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
        else:
            defaults = {}
        learnings = json.loads(args.learnings.read_text()) if args.learnings else None
        candidate = collect(defaults, args.support_dir, learnings)
        serve(candidate, args.profile)
    except KeyboardInterrupt:
        pass
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(2, f"Import failed: {error}\n")


if __name__ == "__main__":
    main()
