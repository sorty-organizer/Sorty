#!/usr/bin/env python3
"""Retain APFS block sharing after signing rewrites a staged executable."""

import ctypes
import hashlib
import os
from pathlib import Path
import sys
import tempfile


def share(compiled, signed):
    if sys.platform != "darwin" or compiled.is_symlink() or signed.is_symlink():
        return False
    if compiled.samefile(signed):
        return False
    # Clone a stable snapshot, then patch only blocks that signing changed.
    # Concurrent compiler replacement cannot change the cloned file's bytes.
    with tempfile.TemporaryDirectory(dir=signed.parent) as directory:
        candidate = Path(directory) / signed.name
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.clonefile(os.fsencode(compiled), os.fsencode(candidate), 0):
            return False
        expected = hashlib.sha256()
        before = signed.stat()
        with signed.open("rb") as source, candidate.open("r+b") as output:
            offset = 0
            while block := source.read(131072):
                expected.update(block)
                output.seek(offset)
                if output.read(len(block)) != block:
                    output.seek(offset)
                    output.write(block)
                offset += len(block)
            output.truncate(offset)
        # Publish only a byte-identical result with the signed file's metadata.
        actual = hashlib.sha256()
        with candidate.open("rb") as stream:
            while block := stream.read(1048576):
                actual.update(block)
        if actual.digest() != expected.digest() or signed.stat() != before:
            return False
        # COPYFILE_METADATA preserves ACLs, stat data, and extended attributes
        # without copying file contents or breaking the shared code pages.
        if libc.copyfile(os.fsencode(signed), os.fsencode(candidate), None, 7):
            raise OSError(ctypes.get_errno(), "Could not preserve signed metadata")
        candidate.replace(signed)
    return True


if __name__ == "__main__":
    try:
        share(Path(sys.argv[1]), Path(sys.argv[2]))
    except OSError as error:
        # Sharing is optional; the original signed executable remains usable.
        print(f"Executable sharing skipped: {error}")
