"""Regression checks for the AltStore IPA packaging boundary."""

import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_native_ipa import package, validate


class PackagingTests(unittest.TestCase):
    def test_metadata_is_excluded_and_existing_output_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Reader.app"
            framework = app / "Frameworks/ReaderEngine.framework"
            framework.mkdir(parents=True)
            (framework / "ReaderEngine").write_bytes(b"fixture")
            (app / "Reader").write_bytes(b"fixture")
            (app / "Reader").chmod(0o755)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.reader", "CFBundleName": "Reader",
                "CFBundleExecutable": "Reader", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
            }))
            (app / "._Info.plist").write_bytes(b"metadata")
            output = root / "reader.ipa"
            package(app, output)
            original = output.read_bytes()
            with self.assertRaises(FileExistsError):
                package(app, output)
            self.assertEqual(output.read_bytes(), original)
            # Recreate the delivered archive's misleading Payload sibling.
            with zipfile.ZipFile(output, "a") as archive:
                archive.writestr("Payload/._Reader.app", b"metadata")
            with self.assertRaisesRegex(ValueError, "AppleDouble"):
                validate(output)


if __name__ == "__main__":
    unittest.main()
