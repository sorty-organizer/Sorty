#!/usr/bin/env python3
"""Keep inactive compiler outputs in lossless Apple Archives, preserving mtimes."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run(["/usr/bin/aa", *map(str, args)], check=True)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def sync(root, action, config, tests=False):
    root = root.resolve()
    if os.environ.get("CI") == "true" or os.environ.get("SORTY_COLD_BUILD_CACHE", "true").lower() == "false":
        return
    if not Path("/usr/bin/aa").exists():
        return
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".lock").open("a") as lock:
        # A compiler using this scratch directory owns the same SwiftPM lock.
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        folder = root / ".sorty-cache/cold"
        folder.mkdir(parents=True, exist_ok=True)
        kinds = [config + "-tests"] if tests else [config]
        for kind in kinds:
            archive = folder / (kind + ".aar")
            state = folder / (kind + ".json")
            if action == "restore":
                if not state.exists():
                    continue
                info = json.loads(state.read_text())
                target = (root / info["path"]).resolve()
                if not target.is_relative_to(root) or target == root:
                    raise ValueError("Cold cache destination leaves scratch directory")
                names = info["names"]
                if any(Path(name).name != name for name in names):
                    raise ValueError("Invalid cold cache entry name")
                # Preserve outputs created by a bare SwiftPM command since packing.
                missing = [name for name in names if not (target / name).exists()]
                if not names and target.exists():
                    missing = []
                elif not names:
                    missing = None
                if missing is None or missing:
                    if digest(archive) != info["sha256"]:
                        raise ValueError("Cold build cache checksum mismatch; archive retained")
                    # Extract and verify before touching the live output directory.
                    with tempfile.TemporaryDirectory(dir=folder) as temporary_dir:
                        staging = Path(temporary_dir) / "outputs"
                        staging.mkdir()
                        args = ["extract", "-i", archive, "-d", staging]
                        verify = ["verify", "-i", archive, "-d", staging]
                        if missing:
                            args += ["-include-regex", selection(missing)]
                            verify += ["-include-regex", selection(missing)]
                        run(*args)
                        run(*verify)
                        if missing:
                            target.mkdir(parents=True, exist_ok=True)
                            for name in missing:
                                (staging / name).replace(target / name)
                        else:
                            target.parent.mkdir(parents=True, exist_ok=True)
                            staging.replace(target)
                    print(f"Restored {kind} compiler outputs")
                archive.unlink(missing_ok=True)
                state.unlink()
                continue

            if state.exists():
                continue
            target = (root / config).resolve()
            if not target.is_dir() or not target.is_relative_to(root) or target == root:
                continue
            names = []
            if kind.endswith("-tests"):
                names = sorted(p.name for p in target.iterdir()
                               if p.name.endswith(".xctest"))
                if not names:
                    continue
            sources = [target / name for name in names] if names else [target]
            before = snapshot(sources)
            temporary = archive.with_suffix(".tmp")
            try:
                args = ["archive", "-d", target, "-o", temporary, "-a", "lzfse", "-include-field", "sh2"]
                if names:
                    args += ["-include-regex", selection(names)]
                run(*args)
                verify = ["verify", "-i", temporary, "-d", target]
                if names:
                    verify += ["-include-regex", selection(names)]
                run(*verify)
                if snapshot(sources) != before:
                    raise RuntimeError("Compiler outputs changed during packing; originals retained")
                original_bytes = sum(value[1] for value in before.values())
                if temporary.stat().st_size >= original_bytes:
                    continue
                temporary.replace(archive)
                info = {"path": str(target.relative_to(root)), "names": names, "sha256": digest(archive)}
                state.write_text(json.dumps(info))
                for source in sources:
                    if source.is_symlink() or source.is_file():
                        source.unlink()
                    else:
                        shutil.rmtree(source)
                print(f"Packed {kind}: {original_bytes // 1048576} MiB → {archive.stat().st_size // 1048576} MiB")
            finally:
                temporary.unlink(missing_ok=True)


def selection(names):
    return "^(" + "|".join(re.escape(name) for name in names) + ")($|/)"


def snapshot(sources):
    return {str(path): (path.lstat().st_mtime_ns, path.lstat().st_size, path.lstat().st_mode, path.lstat().st_ctime_ns)
            for source in sources for path in [source, *source.rglob("*")]
            if not path.is_dir() or path.is_symlink()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("pack", "restore"))
    parser.add_argument("root", type=Path)
    parser.add_argument("config", choices=("debug", "release"))
    parser.add_argument("--tests", action="store_true")
    args = parser.parse_args()
    try:
        sync(args.root, args.action, args.config, args.tests)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, RuntimeError) as error:
        # A cache cannot block a build. Keep failed archives for inspection;
        # SwiftPM will rebuild absent outputs from the sources.
        print(f"Cold cache {args.action} skipped: {error}")
