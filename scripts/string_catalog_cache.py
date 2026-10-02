#!/usr/bin/env python3
"""Reuse verified native string-catalog output across app assembly runs."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def hashes(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError("Unexpected link in string catalog cache")
        if path.is_file():
            result[str(path.relative_to(folder))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def copy_outputs(source, destination):
    for name in hashes(source):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)


def compile_catalog(catalog, destination, cache_root, toolchain):
    key = hashlib.sha256(b"strings-v1\0" + toolchain.encode() + b"\0" + catalog.name.encode()
                         + b"\0" + catalog.read_bytes()).hexdigest()
    cached = cache_root / key
    try:
        expected = json.loads((cached / "checksums.json").read_text())
        outputs = cached / "outputs"
        if not cached.is_symlink() and outputs.is_dir() and not outputs.is_symlink() and hashes(outputs) == expected:
            copy_outputs(cached / "outputs", destination)
            os.utime(cached, None)
            return
    except (OSError, ValueError):
        pass
    if cached.is_symlink():
        cached.unlink()
    elif cached.exists():
        shutil.rmtree(cached)
    cache_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".compile-", dir=cache_root) as temporary:
        staging = Path(temporary)
        outputs = staging / "outputs"
        outputs.mkdir()
        subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog),
                        "--output-directory", str(outputs)], check=True)
        (staging / "checksums.json").write_text(json.dumps(hashes(outputs)))
        copy_outputs(outputs, destination)
        try:
            staging.rename(cached)
        except OSError as error:
            # A concurrent build can publish identical completed output first.
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("cache_root", type=Path)
    parser.add_argument("toolchain")
    args = parser.parse_args()
    compile_catalog(args.catalog, args.destination, args.cache_root, args.toolchain)
