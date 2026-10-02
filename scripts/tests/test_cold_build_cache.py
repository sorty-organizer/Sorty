import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "cold_build_cache", Path(__file__).resolve().parents[1] / "cold_build_cache.py"
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


@unittest.skipUnless(Path("/usr/bin/aa").exists(), "Apple Archive requires macOS")
class ColdCacheTests(unittest.TestCase):
    def test_config_and_test_bundle_round_trip_preserve_compiler_inputs(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"CI": "false", "SORTY_COLD_BUILD_CACHE": "true"}):
            root = Path(directory)
            release = root / "arm64-apple-macosx/release"
            release.mkdir(parents=True)
            (root / "release").symlink_to("arm64-apple-macosx/release")
            binary = release / "SortyApp"
            binary.write_bytes(b"compiler output\n" * 10000)
            binary.chmod(0o755)
            os.utime(binary, ns=(1234567890123456, 1234567890123456))
            (release / "linked").symlink_to("SortyApp")
            cache.sync(root, "pack", "release")
            self.assertFalse(release.exists())
            cache.sync(root, "restore", "release")
            self.assertEqual(binary.read_bytes(), b"compiler output\n" * 10000)
            self.assertEqual(binary.stat().st_mtime_ns, 1234567890123456)
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            self.assertEqual((release / "linked").readlink(), Path("SortyApp"))

            debug = root / "debug"
            bundle = debug / "SortyPackageTests.xctest"
            bundle.mkdir(parents=True)
            (bundle / "tests").write_bytes(b"test binary\n" * 10000)
            active = debug / "SortyApp"
            active.write_text("active app")
            cache.sync(root, "pack", "debug", tests=True)
            self.assertFalse(bundle.exists())
            self.assertEqual(active.read_text(), "active app")
            cache.sync(root, "restore", "debug", tests=True)
            self.assertEqual((bundle / "tests").read_bytes(), b"test binary\n" * 10000)
            self.assertEqual(active.read_text(), "active app")

    def test_corrupt_archive_cannot_create_partial_outputs_or_replace_fresh_work(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"CI": "false", "SORTY_COLD_BUILD_CACHE": "true"}):
            root = Path(directory)
            target = root / "release"
            target.mkdir()
            (target / "output").write_bytes(b"cache\n" * 10000)
            cache.sync(root, "pack", "release")
            archive = root / ".sorty-cache/cold/release.aar"
            archive.write_bytes(b"broken archive")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                cache.sync(root, "restore", "release")
            self.assertFalse(target.exists())
            self.assertTrue(archive.exists())
            target.mkdir()
            (target / "output").write_text("new compiler work")
            cache.sync(root, "restore", "release")
            self.assertEqual((target / "output").read_text(), "new compiler work")
            self.assertFalse(archive.exists())


if __name__ == "__main__":
    unittest.main()
