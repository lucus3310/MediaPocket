"""Package a device build into an unsigned IPA, preserving framework symlinks."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import shutil
import zipfile


def package_app(app: Path, output: Path) -> None:
    app = app.resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Expected an iPhone .app directory")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Refusing to package a Simulator build")
    executable = app / info["CFBundleExecutable"]
    if not executable.is_file():
        raise ValueError("The application executable is missing")

    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise FileExistsError(output)
    with tempfile.TemporaryDirectory(prefix="mediapocket-ipa-") as staging:
        payload = Path(staging) / "Payload"
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        subprocess.run(
            ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(output)],
            check=True,
        )

    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA archive integrity check failed")
        expected = f"Payload/{app.name}/Info.plist"
        if expected not in archive.namelist():
            raise ValueError("IPA Payload directory is missing")

    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(f"{checksum}  {output.name}\n", encoding="utf-8")
    metadata = {
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "platform": "iPhoneOS",
        "signed": False,
        "sha256": checksum,
        "bytes": output.stat().st_size,
    }
    output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package_app(args.app, args.output)
