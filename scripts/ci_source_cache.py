#!/usr/bin/env python3
"""Preserve unchanged checkout mtimes so restored build outputs stay incremental."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def source_files(root):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    for name in paths.decode().split("\0"):
        if not name:
            continue
        path = root / name
        # Never follow tracked symlinks out of the checkout.
        if path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root):
            yield name, path


def sync(mode, root, state):
    entries = {}
    if mode == "restore":
        try:
            entries = json.loads(state.read_text())
            if not isinstance(entries, dict):
                entries = {}
        except (OSError, ValueError):
            pass

    restored = 0
    for name, path in source_files(root):
        stat = path.stat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if mode == "save":
            entries[name] = [digest, stat.st_mtime_ns]
        else:
            cached = entries.get(name)
            if (isinstance(cached, list) and len(cached) == 2
                    and cached[0] == digest and isinstance(cached[1], int)
                    and 0 <= cached[1] <= stat.st_mtime_ns):
                os.utime(path, ns=(stat.st_atime_ns, cached[1]))
                restored += 1

    if mode == "save":
        state.parent.mkdir(parents=True, exist_ok=True)
        temporary = state.with_suffix(".tmp")
        temporary.write_text(json.dumps(entries, separators=(",", ":")))
        temporary.replace(state)
        print(f"Saved timestamps for {len(entries)} tracked files")
    else:
        print(f"Restored timestamps for {restored} unchanged tracked files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("save", "restore"))
    parser.add_argument("--state", default=".build/.sorty-cache/source-mtimes.json")
    args = parser.parse_args()
    sync(args.mode, Path.cwd().resolve(), Path(args.state))
