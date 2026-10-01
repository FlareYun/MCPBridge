#!/usr/bin/env python3
"""Build a self-contained local macOS distribution without an installer or daemon."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", default=str(ROOT / "dist"))
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    destination = Path(args.destination).resolve()
    if destination == ROOT or destination in ROOT.parents:
        parser.error("Destination must not be the source directory or an ancestor.")
    if not args.skip_build:
        run("swift", "build", "-c", args.configuration)
    binaries = ROOT / ".build" / args.configuration
    destination.mkdir(parents=True, exist_ok=True)
    app = destination / "MCP Bridge.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binaries / "MCPBridgeApp", macos / "MCPBridgeApp")
    shutil.copy2(binaries / "mcp-bridge", macos / "mcp-bridge")
    shutil.copy2(binaries / "mcp-bridge", destination / "mcp-bridge")
    metadata = {
        "CFBundleName": "MCP Bridge", "CFBundleDisplayName": "MCP Bridge",
        "CFBundleExecutable": "MCPBridgeApp", "CFBundleIdentifier": "local.mcpbridge.desktop",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "4",
        "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
        "CFBundleIconFile": "AppIcon", "NSPrincipalClass": "NSApplication",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(metadata, file)
    iconset = ROOT / ".build/Bridge.iconset"
    run("swift", str(ROOT / "scripts/make-icon.swift"), str(iconset))
    run("/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns"))
    for name in ["README.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.txt"]:
        shutil.copy2(ROOT / name, destination / name)
    shutil.copytree(ROOT / "docs", destination / "docs", dirs_exist_ok=True)
    source = destination / "source"
    ignored = [".build", ".git", ".swiftpm", "dist", "__pycache__", ".DS_Store"]
    if ROOT in destination.parents:
        ignored.append(destination.relative_to(ROOT).parts[0])
    shutil.copytree(ROOT, source, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(*ignored))
    notices = ["MCP Bridge — third-party notices\n\nFull upstream license texts follow. Versions are locked in Package.resolved.\n"]
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    for pin in pins:
        identity = pin["identity"]
        checkout = ROOT / ".build/checkouts" / identity
        licenses = sorted(p for p in checkout.glob("*") if p.is_file() and p.name.lower().startswith(("license", "notice", "copying")))
        if not licenses:
            raise RuntimeError("Missing dependency license for " + identity)
        notices.append("\n" + "=" * 72 + "\n" + identity + " " + pin["state"].get("version", pin["state"]["revision"]) + "\n" + pin["location"] + "\n")
        for license_file in licenses:
            notices.append("\n--- " + license_file.name + " ---\n" + license_file.read_text())
    notice_text = "\n".join(notices)
    repository_notices = (ROOT / "THIRD_PARTY_NOTICES.txt").read_text()
    npm_marker = "\n\n" + "=" * 72 + "\nWindows CLI dependencies (npm)\n"
    if npm_marker in repository_notices:
        notice_text += npm_marker + repository_notices.split(npm_marker, 1)[1]
    (destination / "THIRD_PARTY_NOTICES.txt").write_text(notice_text)
    (resources / "THIRD_PARTY_NOTICES.txt").write_text(notice_text)
    (source / "THIRD_PARTY_NOTICES.txt").write_text(notice_text)
    with zipfile.ZipFile(destination / "MCP-Bridge-source.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                archive.write(file, Path("MCP-Bridge") / file.relative_to(source))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.mcpbridge.cli", str(macos / "mcp-bridge"))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.mcpbridge.cli", str(destination / "mcp-bridge"))
    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--strict", str(app))
    print(destination)


if __name__ == "__main__":
    main()
