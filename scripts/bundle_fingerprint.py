#!/usr/bin/env python3
"""Hash bundle inputs, reading only files whose identity or metadata changed."""

import argparse
import hashlib
import json
from pathlib import Path
import os


def fingerprint(group, paths, cache_root):
    key = hashlib.sha256(group.encode()).hexdigest()
    state = cache_root / (key + ".json")
    try:
        previous = json.loads(state.read_text())
        if not isinstance(previous, dict):
            previous = {}
    except (OSError, ValueError):
        previous = {}

    current = {}
    lines = []
    for name in paths:
        path = Path(name)
        if not path.is_file():
            lines.append(f"{name} missing\n")
            continue
        info = path.stat()
        metadata = [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        cached = previous.get(name)
        if (isinstance(cached, dict) and cached.get("metadata") == metadata
                and isinstance(cached.get("hash"), str) and len(cached["hash"]) == 64):
            digest = cached["hash"]
        else:
            content = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    content.update(chunk)
            after = path.stat()
            if metadata != [after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns]:
                raise RuntimeError(f"Bundle input changed while hashing: {name}")
            digest = content.hexdigest()
        current[name] = {"metadata": metadata, "hash": digest}
        lines.append(f"{digest}  {name}\n")

    # Match shasum's existing fingerprint format so migration preserves hits.
    result = hashlib.sha256("".join(sorted(lines)).encode()).hexdigest()
    if current != previous:
        cache_root.mkdir(parents=True, exist_ok=True)
        temporary = state.with_suffix(f".tmp.{os.getpid()}")
        try:
            temporary.write_text(json.dumps(current, separators=(",", ":")))
            temporary.replace(state)
        finally:
            temporary.unlink(missing_ok=True)
    return f"{result} group={group}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache_root", type=Path)
    parser.add_argument("group")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    print(fingerprint(args.group, args.paths, args.cache_root))
