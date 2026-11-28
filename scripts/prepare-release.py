"""Stage both installers, signed updater assets and manifests for GitHub Releases."""

import base64
import hashlib
import json
import plistlib
import shutil
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path


def find_one(directory, pattern):
    matches = list(directory.rglob(pattern))
    if len(matches) != 1:
        raise ValueError(f"Expected one {pattern} in {directory}, found {len(matches)}")
    return matches[0]


def main(version, repository, bundles, output, notes):
    bundles = Path(bundles)
    output = Path(output)
    output.mkdir(exist_ok=False)
    archive = find_one(bundles, "*.app.tar.gz")
    with tarfile.open(archive) as app:
        plists = [m for m in app.getmembers() if m.name.endswith(".app/Contents/Info.plist")]
        if len(plists) != 1 or plistlib.load(app.extractfile(plists[0]))["CFBundleShortVersionString"] != version:
            raise ValueError(f"macOS updater archive does not contain App version {version}")

    mac_name = f"FundDesk-{version}-macOS-universal"
    windows_name = f"FundDesk-{version}-Windows-x64-setup.exe"
    installer = find_one(bundles, f"*_{version}_x64-setup.exe")
    assets = {
        f"{mac_name}.dmg": find_one(bundles, f"*_{version}_universal.dmg"),
        f"{mac_name}.app.tar.gz": archive,
        f"{mac_name}.app.tar.gz.sig": archive.with_name(archive.name + ".sig"),
        windows_name: installer,
        f"{windows_name}.sig": installer.with_name(installer.name + ".sig"),
    }
    for name, source in assets.items():
        if source.stat().st_size == 0:
            raise ValueError(f"Empty release asset: {source}")
        shutil.copyfile(source, output / name)

    def platform(name):
        signature = (output / f"{name}.sig").read_text().strip()
        comment = next(
            (line for line in base64.b64decode(signature, validate=True).decode().splitlines()
             if line.startswith("trusted comment: ")),
            "",
        )
        if f"version:{version}" not in comment.split("	"):
            raise ValueError(f"Updater signature for {name} does not declare version {version}")
        return {
            "url": f"https://github.com/{repository}/releases/download/v{version}/{name}",
            "signature": signature,
        }

    mac = platform(f"{mac_name}.app.tar.gz")
    manifest = {
        "version": version,
        "notes": Path(notes).read_text().strip(),
        "pub_date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "platforms": {
            "darwin-aarch64": mac,
            "darwin-x86_64": mac.copy(),
            "windows-x86_64": platform(windows_name),
        },
    }
    (output / "latest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    for entry in manifest["platforms"].values():
        entry["url"] = f'https://ghfast.top/{entry["url"]}'
    mirrored = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    (output / "latest-cn.json").write_text(mirrored)
    # v1.0.1 clients have this fixed name configured as their primary endpoint.
    (output / "latest-cn-v1.0.1.json").write_text(mirrored)
    sums = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}" for path in sorted(output.iterdir())]
    (output / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:])
