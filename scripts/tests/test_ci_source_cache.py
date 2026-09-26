import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "ci_source_cache", Path(__file__).resolve().parents[1] / "ci_source_cache.py"
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class SourceCacheTests(unittest.TestCase):
    def test_restore_only_content_identical_tracked_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            unchanged = root / "unchanged.swift"
            changed = root / "changed.swift"
            deleted = root / "deleted.swift"
            outside = root.parent / (root.name + "-outside")
            try:
                outside.write_text("outside")
                (root / "link").symlink_to(outside)
                for path in (unchanged, changed, deleted):
                    path.write_text("old")
                    os.utime(path, ns=(1_000_000_000, 1_000_000_000))
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                state = root / ".build/state.json"
                cache.sync("save", root, state)
                outside_mtime = outside.stat().st_mtime_ns
                changed.write_text("new")  # Same size, different contents.
                deleted.unlink()
                added = root / "added.swift"
                added.write_text("new")
                subprocess.run(["git", "add", str(added)], cwd=root, check=True)
                for path in (unchanged, changed, added):
                    os.utime(path, ns=(2_000_000_000, 2_000_000_000))
                cache.sync("restore", root, state)
                self.assertEqual(unchanged.stat().st_mtime_ns, 1_000_000_000)
                self.assertEqual(changed.stat().st_mtime_ns, 2_000_000_000)
                self.assertEqual(added.stat().st_mtime_ns, 2_000_000_000)
                self.assertFalse(deleted.exists())
                self.assertEqual(outside.stat().st_mtime_ns, outside_mtime)
                state.write_text("invalid json")
                cache.sync("restore", root, state)
                self.assertEqual(changed.read_text(), "new")
            finally:
                outside.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
