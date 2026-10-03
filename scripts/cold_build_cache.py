#!/usr/bin/env python3
"""Keep inactive compiler outputs in lossless Apple Archives, preserving mtimes."""

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
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
        if action == "compact":
            compact(root, folder)
            return
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


def compact(root, folder):
    # Test executables stay readable too: archiving them after each app build
    # forces SwiftPM to relink them on the next bare `swift test` invocation.
    debug = (root / "debug").resolve()
    bundles = sorted(debug.glob("*.xctest")) if debug.is_relative_to(root) else []
    for tree in (root / "ModuleCache", root / "artifacts", *bundles):
        if not tree.is_dir() or tree.is_symlink():
            continue
        sources = [path for path in tree.rglob("*")
                   if path.is_file() and not path.is_symlink()
                   and path.stat().st_nlink == 1
                   and path.stat().st_size >= 1048576
                   and not path.stat().st_flags & stat.UF_COMPRESSED]
        if not sources:
            continue
        before = snapshot(sources)
        directory_times = {parent: (parent.stat().st_atime_ns, parent.stat().st_mtime_ns)
                           for source in sources for parent in source.parents
                           if parent.is_relative_to(tree)}
        with tempfile.TemporaryDirectory(dir=folder) as directory:
            temporary = Path(directory)
            archive = temporary / "inputs.aar"
            outputs = temporary / "outputs"
            outputs.mkdir()
            selected = selection([str(path.relative_to(tree)) for path in sources])
            run("archive", "-d", tree, "-o", archive, "-a", "raw",
                "-include-field", "sh2", "-include-regex", selected)
            run("extract", "-i", archive, "-d", outputs, "-afsc", "lzfse", "-afsc-all")
            # Compression deliberately adds UF_COMPRESSED; all other archive
            # fields still match, and we verify remaining file flags below.
            run("verify", "-i", archive, "-d", outputs, "-exclude-field", "flg,xat",
                "-include-regex", selected)
            if snapshot(sources) != before:
                raise RuntimeError("Cache inputs changed during compression; originals retained")
            if any((outputs / source.relative_to(tree)).stat().st_flags & ~stat.UF_COMPRESSED
                   != source.stat().st_flags for source in sources):
                raise ValueError("Filesystem compression changed unrelated file flags")
            if any(xattrs(outputs / source.relative_to(tree)) != xattrs(source) for source in sources):
                raise ValueError("Filesystem compression changed extended attributes")
            saved = 0
            for source in sources:
                compressed = outputs / source.relative_to(tree)
                reduction = (source.stat().st_blocks - compressed.stat().st_blocks) * 512
                if compressed.stat().st_flags & stat.UF_COMPRESSED and reduction > 0:
                    compressed.replace(source)
                    saved += reduction
            # Bundle directories are compiler inputs too. Changing their
            # timestamps would unnecessarily recopy dependency frameworks.
            for directory, times in directory_times.items():
                if directory.stat().st_mtime_ns != times[1]:
                    os.utime(directory, ns=times)
            print(f"Filesystem-compressed {tree.name}: saved {saved // 1048576} MiB")


def xattrs(path):
    # macOS stamps new files with the current process's provenance. Native
    # APIs hide compression storage attributes; compare every other attribute.
    libc = ctypes.CDLL(None, use_errno=True)
    name = os.fsencode(path)
    count = libc.listxattr(name, None, 0, 0)
    if count < 0:
        raise OSError(ctypes.get_errno(), "Could not list extended attributes")
    names = ctypes.create_string_buffer(count)
    if libc.listxattr(name, names, count, 0) != count:
        raise OSError("Extended attributes changed during compression")
    values = {}
    for attribute in names.raw.split(b"\0"):
        if not attribute or attribute == b"com.apple.provenance":
            continue
        size = libc.getxattr(name, attribute, None, 0, 0, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "Could not read extended attribute")
        value = ctypes.create_string_buffer(size)
        if libc.getxattr(name, attribute, value, size, 0, 0) != size:
            raise OSError("Extended attribute changed during compression")
        values[attribute] = value.raw
    return values


def snapshot(sources):
    return {str(path): (path.lstat().st_mtime_ns, path.lstat().st_size, path.lstat().st_mode, path.lstat().st_ctime_ns)
            for source in sources for path in [source, *source.rglob("*")]
            if not path.is_dir() or path.is_symlink()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("pack", "restore", "compact"))
    parser.add_argument("root", type=Path)
    parser.add_argument("config", choices=("debug", "release"))
    parser.add_argument("--tests", action="store_true")
    args = parser.parse_args()
    try:
        sync(args.root, args.action, args.config, args.tests)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, RuntimeError) as error:
        # A cache cannot block a build. Keep failed archives for inspection;
        # SwiftPM will rebuild absent outputs from the sources.
        detail = f"Apple Archive exited {error.returncode}" if isinstance(error, subprocess.CalledProcessError) else error
        print(f"Cold cache {args.action} skipped: {detail}")
