import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "string_catalog_cache", Path(__file__).resolve().parents[1] / "string_catalog_cache.py"
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


@unittest.skipUnless(Path("/usr/bin/xcrun").exists(), "String catalogs require Xcode")
class StringCacheTests(unittest.TestCase):
    def test_native_outputs_survive_cache_hits_changes_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / "Localizable.xcstrings"
            destination = root / "app"
            native = root / "native"
            native.mkdir()
            store = root / "cache"
            for value in ("Hello", "Changed"):
                catalog.write_text(json.dumps({"sourceLanguage": "en", "version": "1.0", "strings": {
                    "hello": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}
                }}))
                subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog),
                                "--output-directory", str(native)], check=True)
                cache.compile_catalog(catalog, destination, store, "toolchain")
                expected = cache.hashes(native)
                self.assertTrue(expected)
                self.assertEqual(cache.hashes(destination), expected)
                product = next(destination.rglob("*.strings"))
                modified = product.stat().st_mtime_ns
                cache.compile_catalog(catalog, destination, store, "toolchain")
                self.assertEqual(cache.hashes(destination), expected)
                self.assertEqual(product.stat().st_mtime_ns, modified)
            for product in store.glob("*/outputs/**/*.strings"):
                product.write_text("corrupt")
            cache.compile_catalog(catalog, destination, store, "toolchain")
            self.assertEqual(cache.hashes(destination), cache.hashes(native))


if __name__ == "__main__":
    unittest.main()
