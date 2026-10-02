import ctypes
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "share_signed_executable", Path(__file__).resolve().parents[1] / "share_signed_executable.py"
)
sharing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sharing)


@unittest.skipUnless(sys.platform == "darwin", "APFS cloning requires macOS")
class ExecutableSharingTests(unittest.TestCase):
    def test_signed_bytes_metadata_and_execution_survive_sharing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.c"
            source.write_text("const char payload[1048576] = {1}; int main(void) { return payload[0] - 1; }\n")
            compiled, signed = root / "compiled", root / "signed"
            subprocess.run(["xcrun", "clang", str(source), "-o", str(compiled)], check=True)
            original = hashlib.sha256(compiled.read_bytes()).digest()
            subprocess.run(["/bin/cp", str(compiled), str(signed)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "com.sorty.cache-test", str(signed)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/xattr", "-w", "com.sorty.cache-test", "signed metadata", str(signed)], check=True)
            signed.chmod(0o751)
            os.utime(signed, ns=(1234567890123456, 1234567890123456))
            expected = hashlib.sha256(signed.read_bytes()).digest()
            self.assertTrue(sharing.share(compiled, signed))
            self.assertEqual(hashlib.sha256(signed.read_bytes()).digest(), expected)
            self.assertEqual(hashlib.sha256(compiled.read_bytes()).digest(), original)
            # APFS's private-size attribute counts unshared allocated blocks;
            # st_blocks and du count shared blocks again for every clone.
            attributes = struct.pack("<HHIIIII", 5, 0, 0, 0, 0, 0, 8)
            result = ctypes.create_string_buffer(64)
            self.assertEqual(ctypes.CDLL(None).getattrlist(os.fsencode(signed), attributes, result, 64, 32), 0)
            self.assertLess(struct.unpack_from("<Q", result.raw, 4)[0], signed.stat().st_size / 2)
            self.assertEqual(signed.stat().st_mode & 0o777, 0o751)
            self.assertEqual(signed.stat().st_mtime_ns, 1234567890123456)
            self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.sorty.cache-test", str(signed)]).strip(), b"signed metadata")
            subprocess.run(["codesign", "--verify", "--strict", str(signed)], check=True)
            subprocess.run([str(signed)], check=True)
            self.assertFalse(sharing.share(signed, signed))
            link = root / "linked"
            link.symlink_to(signed)
            self.assertFalse(sharing.share(compiled, link))


if __name__ == "__main__":
    unittest.main()
