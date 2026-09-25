#!/usr/bin/env python3
"""Package full-bleed artwork with macOS Dock margins. Requires ImageMagick."""

from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
# Keep the entire tile inside the traditional macOS 824px artwork area.
CANVAS = 1024
ARTWORK = 824
# ICNS type, point size, display scale. Include Retina representations explicitly.
REPRESENTATIONS = (
    (b"icp4", 16, 1), (b"ic11", 16, 2),
    (b"icp5", 32, 1), (b"ic12", 32, 2),
    (b"ic07", 128, 1), (b"ic13", 128, 2),
    (b"ic08", 256, 1), (b"ic14", 256, 2),
    (b"ic09", 512, 1), (b"ic10", 512, 2),
)


def main():
    if not shutil.which("magick"):
        raise SystemExit("Install ImageMagick before generating app icons.")

    with tempfile.TemporaryDirectory(prefix="sorty-icons-") as directory:
        scratch = Path(directory)
        for variant in ("Debug", "Release"):
            source = ROOT / f"Assets/AppIcon/AppIcon-{variant}.png"
            master = scratch / f"{variant}.png"
            subprocess.run([
                "magick", str(source), "-resize", f"{ARTWORK}x{ARTWORK}",
                "-colorspace", "sRGB", "-strip", "-depth", "8",
                "-background", "none", "-gravity", "center", "-extent",
                f"{CANVAS}x{CANVAS}", str(master),
            ], check=True)

            chunks = []
            for kind, points, scale in REPRESENTATIONS:
                suffix = "@2x" if scale == 2 else ""
                filename = f"icon_{points}x{points}{suffix}.png"
                output = scratch / filename
                pixels = points * scale
                subprocess.run([
                    "magick", str(master), "-resize", f"{pixels}x{pixels}",
                    "-strip", "-depth", "8", str(output),
                ], check=True)
                data = output.read_bytes()
                chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
                if variant == "Release":
                    shutil.copyfile(output, ROOT / "Resources/Assets.xcassets"
                                    / "AppIcon.appiconset" / filename)

            payload = b"".join(chunks)
            icon = ROOT / f"Assets/AppIcon/AppIcon-{variant}.icns"
            icon.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
            resource = "AppIcon-Debug.icns" if variant == "Debug" else "AppIcon.icns"
            shutil.copyfile(icon, ROOT / "Resources" / resource)


if __name__ == "__main__":
    main()
