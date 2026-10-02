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
            catalog = root / "Assets.xcassets"
            unchanged_set = catalog / "Unchanged.imageset"
            changed_set = catalog / "Changed.imageset"
            for folder in (unchanged_set, changed_set):
                folder.mkdir(parents=True)
                (folder / "Contents.json").write_text("old")
            outside = root.parent / (root.name + "-outside")
            try:
                outside.write_text("outside")
                (root / "link").symlink_to(outside)
                for path in (unchanged, changed, deleted):
                    path.write_text("old")
                    os.utime(path, ns=(1_000_000_000, 1_000_000_000))
                for folder in (catalog, unchanged_set, changed_set):
                    os.utime(folder, ns=(1_000_000_000, 1_000_000_000))
                subprocess.run(["git", "add", "."], cwd=root, check=True)
                state = root / ".build/state.json"
                cache.sync("save", root, state)
                outside_mtime = outside.stat().st_mtime_ns
                changed.write_text("new")  # Same size, different contents.
                (changed_set / "Contents.json").write_text("new")
                deleted.unlink()
                added = root / "added.swift"
                added.write_text("new")
                subprocess.run(["git", "add", str(added)], cwd=root, check=True)
                for path in (unchanged, changed, added):
                    os.utime(path, ns=(2_000_000_000, 2_000_000_000))
                for folder in (catalog, unchanged_set, changed_set):
                    os.utime(folder, ns=(2_000_000_000, 2_000_000_000))
                cache.sync("restore", root, state)
                self.assertEqual(unchanged.stat().st_mtime_ns, 1_000_000_000)
                self.assertEqual(changed.stat().st_mtime_ns, 2_000_000_000)
                self.assertEqual(added.stat().st_mtime_ns, 2_000_000_000)
                self.assertFalse(deleted.exists())
                self.assertEqual(outside.stat().st_mtime_ns, outside_mtime)
                self.assertEqual(unchanged_set.stat().st_mtime_ns, 1_000_000_000)
                self.assertEqual(changed_set.stat().st_mtime_ns, 2_000_000_000)
                self.assertEqual(catalog.stat().st_mtime_ns, 2_000_000_000)
                (unchanged_set / "untracked.png").write_text("new asset")
                os.utime(unchanged_set, ns=(3_000_000_000, 3_000_000_000))
                cache.sync("restore", root, state)
                self.assertEqual(unchanged_set.stat().st_mtime_ns, 3_000_000_000)
                state.write_text("invalid json")
                cache.sync("restore", root, state)
                self.assertEqual(changed.read_text(), "new")
            finally:
                outside.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
