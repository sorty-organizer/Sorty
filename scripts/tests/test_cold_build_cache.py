import importlib.util
import os
from pathlib import Path
import stat
import subprocess
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
    def test_filesystem_compression_keeps_sdk_bytes_and_vendor_signatures(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"CI": "false", "SORTY_COLD_BUILD_CACHE": "true"}):
            root = Path(directory)
            sdk = root / "ModuleCache" / "Foundation.pcm"
            sdk.parent.mkdir()
            expected = b"SDK compiler input\n" * 100000
            sdk.write_bytes(expected)
            os.utime(sdk, ns=(1234567890123456, 1234567890123456))
            test_binary = root / "debug" / "SortyPackageTests.xctest" / "Contents" / "MacOS" / "tests"
            test_binary.parent.mkdir(parents=True)
            test_binary.write_bytes(expected)
            test_binary.chmod(0o755)
            os.utime(test_binary, ns=(1234567890123456, 1234567890123456))
            source = root / "main.c"
            source.write_text("const char payload[1048576] = {1}; int main(void) { return payload[0] - 1; }\n")
            binary = root / "artifacts" / "vendor"
            binary.parent.mkdir()
            subprocess.run(["xcrun", "clang", str(source), "-o", str(binary)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/xattr", "-w", "com.sorty.cache-test", "vendor metadata", str(binary)], check=True)
            signed = binary.read_bytes()
            directory_times = {path: path.stat().st_mtime_ns for path in
                               (sdk.parent, binary.parent, test_binary.parent, test_binary.parents[2])}
            cache.sync(root, "compact", "debug")
            for path, mtime in directory_times.items():
                self.assertEqual(path.stat().st_mtime_ns, mtime)
            self.assertEqual(sdk.read_bytes(), expected)
            self.assertEqual(sdk.stat().st_mtime_ns, 1234567890123456)
            self.assertTrue(sdk.stat().st_flags & stat.UF_COMPRESSED)
            self.assertLess(sdk.stat().st_blocks * 512, sdk.stat().st_size / 2)
            self.assertEqual(test_binary.read_bytes(), expected)
            self.assertEqual(test_binary.stat().st_mtime_ns, 1234567890123456)
            self.assertEqual(test_binary.stat().st_mode & 0o777, 0o755)
            self.assertTrue(test_binary.stat().st_flags & stat.UF_COMPRESSED)
            self.assertEqual(binary.read_bytes(), signed)
            self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.sorty.cache-test", str(binary)]).strip(), b"vendor metadata")
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
            inode = sdk.stat().st_ino
            cache.sync(root, "compact", "debug")
            self.assertEqual(sdk.stat().st_ino, inode)

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
