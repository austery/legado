#!/usr/bin/env python3
"""Package a device app without AppleDouble entries that confuse AltSign."""

import argparse
import plistlib
import stat
import zipfile
from pathlib import Path, PurePosixPath


def validate(ipa: Path) -> None:
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if archive.testzip() is not None:
            raise ValueError("IPA has a corrupt ZIP entry")
        for name in names:
            parts = PurePosixPath(name).parts
            if name.startswith("/") or ".." in parts:
                raise ValueError(f"Unsafe archive path: {name}")
            if any(part.startswith("._") or part == "__MACOSX" for part in parts):
                raise ValueError(f"AppleDouble metadata can be mistaken for an app: {name}")
        # AltSign chooses the first Payload child ending in .app, including files.
        candidates = {PurePosixPath(name).parts[1] for name in names
                      if len(PurePosixPath(name).parts) >= 2
                      and PurePosixPath(name).parts[0] == "Payload"
                      and PurePosixPath(name).parts[1].lower().endswith(".app")}
        if len(candidates) != 1:
            raise ValueError(f"Expected exactly one app, found {sorted(candidates)}")
        root = f"Payload/{next(iter(candidates))}/"
        info = plistlib.loads(archive.read(root + "Info.plist"))
        for key in ("CFBundleIdentifier", "CFBundleName", "CFBundleExecutable",
                    "CFBundleVersion", "CFBundleShortVersionString"):
            if not isinstance(info.get(key), str) or not info[key]:
                raise ValueError(f"Missing bundle field: {key}")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Expected an iPhoneOS device app")
        executable = archive.getinfo(root + info["CFBundleExecutable"])
        if not (executable.external_attr >> 16) & stat.S_IXUSR:
            raise ValueError("App executable lost its executable permission")
        archive.getinfo(root + "Frameworks/ReaderEngine.framework/ReaderEngine")


def package(app: Path, output: Path) -> None:
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Input must be a built .app directory")
    # Exclusive creation preserves previously delivered artifacts.
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app)
            if any(part.startswith("._") or part in ("__MACOSX", ".DS_Store")
                   for part in relative.parts):
                continue
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink in iOS app: {relative}")
            archive.write(path, f"Payload/{app.name}/{relative.as_posix()}")
    validate(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package")
    pack.add_argument("app", type=Path)
    pack.add_argument("output", type=Path)
    check = commands.add_parser("validate")
    check.add_argument("ipa", type=Path)
    args = parser.parse_args()
    if args.command == "package":
        package(args.app, args.output)
    else:
        validate(args.ipa)
    print("IPA structure accepted")


if __name__ == "__main__":
    main()
