#!/usr/bin/env python3
"""Combine separately built release apps before signing and packaging."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Optional


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def is_macho(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(4) in {
            bytes.fromhex(value)
            for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
        }


def files(root: Path) -> dict[Path, Path]:
    return {
        path.relative_to(root): path
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink()
        and "_CodeSignature" not in path.parts
    }


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def same_generated_resource(relative: Path, arm_file: Path, intel_file: Path) -> bool:
    if relative == Path("Contents/Resources/Assets.car"):
        def catalog(path: Path) -> list:
            entries = json.loads(run("xcrun", "assetutil", "--info", str(path)))
            if not entries:
                raise SystemExit(f"Empty asset catalog: {path}")
            entries[0].pop("Timestamp", None)
            return entries

        return catalog(arm_file) == catalog(intel_file)

    if relative == Path("Contents/Resources/Metadata.appintents/extract.actionsdata"):
        def intents(path: Path) -> dict:
            data = json.loads(path.read_text())
            for action in data.get("actions", {}).values():
                for parameter in action.get("parameters", []):
                    types = parameter.get("resolvableInputTypes", [])
                    types.sort(key=lambda value: json.dumps(value, sort_keys=True))
            return data

        return intents(arm_file) == intents(intel_file)

    return False


def sign(path: Path, entitlements: Optional[Path] = None) -> None:
    command = ["codesign", "--force", "--options", "runtime", "--sign", "-"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    subprocess.run(command + [str(path)], check=True)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: merge_release_slices.py arm64.app x86_64.app output.app")
    arm, intel, output = map(Path, sys.argv[1:])
    if output.exists():
        raise SystemExit(f"Refusing to replace existing output: {output}")

    arm_files, intel_files = files(arm), files(intel)
    if arm_files.keys() != intel_files.keys():
        missing_arm = sorted(map(str, intel_files.keys() - arm_files.keys()))
        missing_intel = sorted(map(str, arm_files.keys() - intel_files.keys()))
        raise SystemExit(f"Slice bundles differ. Missing arm64: {missing_arm}; missing x86_64: {missing_intel}")

    merged = []
    for relative in sorted(arm_files):
        arm_file, intel_file = arm_files[relative], intel_files[relative]
        if is_macho(arm_file) != is_macho(intel_file):
            raise SystemExit(f"Mach-O mismatch: {relative}")
        if not is_macho(arm_file):
            if digest(arm_file) != digest(intel_file) and not same_generated_resource(relative, arm_file, intel_file):
                raise SystemExit(f"Resource mismatch: {relative}")
            continue
        arm_archs = set(run("lipo", "-archs", str(arm_file)).split())
        intel_archs = set(run("lipo", "-archs", str(intel_file)).split())
        if arm_archs == intel_archs == {"arm64", "x86_64"}:
            if digest(arm_file) != digest(intel_file):
                raise SystemExit(f"Prebuilt universal binary differs: {relative}")
        elif arm_archs == {"arm64"} and intel_archs == {"x86_64"}:
            merged.append(relative)
        else:
            raise SystemExit(f"Unexpected architectures for {relative}: {arm_archs}, {intel_archs}")

    expected = {
        Path("Contents/MacOS/Sorty"),
        Path("Contents/Frameworks/Sentry.framework/Versions/A/Sentry"),
        Path("Contents/PlugIns/SortyFinderSync.appex/Contents/MacOS/SortyFinderSync"),
    }
    if set(merged) != expected:
        raise SystemExit(f"Expected project executables {expected}, found {set(merged)}")

    subprocess.run(["ditto", str(arm), str(output)], check=True)
    for relative in merged:
        target = output / relative
        temp = target.with_name(target.name + ".merged")
        subprocess.run(["lipo", "-create", str(arm_files[relative]), str(intel_files[relative]), "-output", str(temp)], check=True)
        temp.chmod(target.stat().st_mode)
        temp.replace(target)
        if set(run("lipo", "-archs", str(target)).split()) != {"arm64", "x86_64"}:
            raise SystemExit(f"Merged binary is not universal: {relative}")

    sign(output / "Contents/Frameworks/Sentry.framework")
    extension = output / "Contents/PlugIns/SortyFinderSync.appex"
    sign(extension / "Contents/MacOS/SortyFinderSync")
    sign(extension, Path("SortyFinderSync/SortyFinderSync.entitlements"))
    sign(output, Path("Sorty.entitlements"))
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
    print("Merged and signed Sorty, Sentry, and Finder extension slices.")


if __name__ == "__main__":
    main()
