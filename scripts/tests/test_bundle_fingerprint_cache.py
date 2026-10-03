import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "bundle_fingerprint", Path(__file__).resolve().parents[1] / "bundle_fingerprint.py"
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class BundleFingerprintTests(unittest.TestCase):
    def test_small_edits_read_only_changed_files_and_keep_content_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = [root / "large.bin", root / "small.txt", root / "missing.txt"]
            inputs[0].write_bytes(b"unchanged resource" * 10000)
            inputs[1].write_text("before")
            state = root / "cache"
            names = list(map(str, inputs))
            original_open = Path.open
            reads = []

            def read_file(path, *args, **kwargs):
                if path in inputs:
                    reads.append(path)
                return original_open(path, *args, **kwargs)

            with patch.object(Path, "open", read_file):
                first = cache.fingerprint("resources", names, state)
                self.assertEqual(reads, inputs[:2])
                reads.clear()
                self.assertEqual(cache.fingerprint("resources", names, state), first)
                self.assertEqual(reads, [])
                before = inputs[1].stat()
                inputs[1].write_text("after!")
                os.utime(inputs[1], ns=(before.st_atime_ns, before.st_mtime_ns))
                reads.clear()
                changed = cache.fingerprint("resources", names, state)
                self.assertNotEqual(changed, first)
                self.assertEqual(reads, [inputs[1]])
                os.utime(inputs[1], ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000))
                self.assertEqual(cache.fingerprint("resources", names, state), changed)
                inputs[2].write_text("added")
                inputs[1].unlink()
                final = cache.fingerprint("resources", names, state)

            # Independent recipe matches the prior shell fingerprint format.
            lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}\n"
                     if path.is_file() else f"{path} missing\n" for path in inputs]
            expected = hashlib.sha256("".join(sorted(lines)).encode()).hexdigest()
            self.assertEqual(final, f"{expected} group=resources")
            for path in state.glob("*.json"):
                path.write_text("corrupt state")
            self.assertEqual(cache.fingerprint("resources", names, state), final)


if __name__ == "__main__":
    unittest.main()
