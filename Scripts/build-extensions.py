#!/usr/bin/env python3
"""Build native arm64 extensions with the containing app's identity/version."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build(app: pathlib.Path) -> None:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    minimum = max(15, int(info.get("MinimumOSVersion", "15").split(".")[0]))
    plugins = app / "PlugIns"
    plugins.mkdir(exist_ok=True)
    definitions = [
        ("YTKACEOpenSafari", "Safari", "YTKACESafariHandler", "com.apple.Safari.web-extension", ["Handler.m"]),
        ("YTKACEOpenShare", "Share", "YTKACEShareController", "com.apple.share-services", ["Controller.m", "Link.m"]),
    ]
    for name, folder, principal, point, sources in definitions:
        output = plugins / (name + ".appex")
        if output.exists():
            shutil.rmtree(output)
        output.mkdir()
        source = ROOT / "Extensions" / folder
        extension = {"NSExtensionPointIdentifier": point, "NSExtensionPrincipalClass": principal}
        if folder == "Share":
            extension["NSExtensionAttributes"] = {"NSExtensionActivationRule": {
                "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                "NSExtensionActivationSupportsText": True,
            }}
        else:
            for resource in source.iterdir():
                if resource.suffix in {".js", ".json", ".html", ".css"}:
                    shutil.copy2(resource, output / resource.name)
        metadata = {
            "CFBundleIdentifier": info["CFBundleIdentifier"] + "." + name,
            "CFBundleDisplayName": "Открыть в YouTube",
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "XPC!",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "ru",
            "CFBundleShortVersionString": info["CFBundleShortVersionString"],
            "CFBundleVersion": info["CFBundleVersion"],
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": str(minimum) + ".0",
            "UIDeviceFamily": info.get("UIDeviceFamily", [1, 2]),
            "NSExtension": extension,
        }
        # Reuse the containing app's primary icon for the share sheet.
        icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
        for icon in icons:
            for image in app.glob(icon + "*.png"):
                shutil.copy2(image, output / image.name)
        if icons:
            metadata["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": icons}}
        (output / "Info.plist").write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY))
        subprocess.run([
            "xcrun", "clang", "-target", f"arm64-apple-ios{minimum}.0", "-isysroot", sdk,
            "-fobjc-arc", "-fblocks", "-fapplication-extension", "-O2", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-parameter", "-framework", "Foundation", "-framework", "UIKit",
            "-Wl,-e,_NSExtensionMain", *[str(source / item) for item in sources],
            "-o", str(output / name),
        ], check=True)
        print("Built", output.name)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: build-extensions.py YouTube.app")
    build(pathlib.Path(sys.argv[1]).resolve())
