#!/usr/bin/env python3
"""Build/install the isolated rig: Debug simulator or standalone Profile iPhone."""
import argparse
import json
import pathlib
import re
import subprocess
import os
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("rig", type=pathlib.Path, help="Directory printed by the local rig")
target = parser.add_mutually_exclusive_group()
target.add_argument("--simulator", help="Booted simulator UUID to install on")
target.add_argument("--device", help="Connected iPhone UDID to install and launch on")
parser.add_argument("--build-number", type=int, help="Positive local test build number")
args = parser.parse_args()
if args.device and not re.fullmatch(r"(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{16}|[0-9a-fA-F]{40})", args.device):
    parser.error("Pass the connected iPhone UDID")
if args.build_number is not None and args.build_number <= 0:
    parser.error("Use a positive build number")
rig = args.rig.resolve(strict=True)
tmp = pathlib.Path("/tmp").resolve()
if rig.parent != tmp or not rig.name.startswith("pandapay-sms-rig."):
    parser.error("Expected the scratch directory printed by the local rig")
if args.simulator and not re.fullmatch(r"[0-9a-fA-F-]{36}", args.simulator):
    parser.error("Pass an explicit simulator UUID")
defines = rig / "flutter-defines.json"
data = json.loads(defines.read_text())
if (data.get("PANDAPAY_ENV") != "dev"
        or not data.get("SMS_V2_LOCAL_CA_PEM") or not data.get("SMS_V2_LOCAL_RULE_PUBLIC_KEY")):
    parser.error("Expected the local SMS v2 Debug defines and scratch CA")
if args.simulator:
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"]
    ))
    if not any(d["udid"] == args.simulator and d["state"] == "Booted"
               for group in devices["devices"].values() for d in group):
        parser.error("The selected simulator must be booted")

root = pathlib.Path(__file__).resolve().parents[1]
app = root / "app"
project = app / "ios/Runner.xcodeproj/project.pbxproj"
info = app / "ios/Runner/Info.plist"
lock = app / "ios/Podfile.lock"
swift_lock = app / "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
files = {p: p.read_bytes() if p.exists() else None for p in (project, info, lock, swift_lock)}
try:
    # Keep the QA app identity stable so reinstalling preserves its container.
    original = files[project].decode()
    local = original.replace(
        "PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.pandapay",
        "PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.pandapay.smsv2rig",
    )
    if local == original:
        raise RuntimeError("Runner bundle identifier was not found")
    if args.device:
        # Personal-team test provisioning has no production capabilities.
        local = local.replace("Runner/Runner.entitlements", "Runner/DeviceTesting.entitlements")
    project.write_text(local)
    manifest = plistlib.loads(files[info])
    manifest['CFBundleDisplayName'] = 'PandaPay SMS v2 Test' if args.device else 'PandaPay SMS v2 Debug'
    manifest.pop('CFBundleURLTypes', None)
    info.write_bytes(plistlib.dumps(manifest, fmt=plistlib.FMT_XML, sort_keys=False))
    mode = ['--profile', '--no-codesign'] if args.device else ['--debug', '--simulator']
    subprocess.run(
        ["flutter", "build", "ios", *mode,
         f"--dart-define-from-file={defines}",
         *(['--dart-define=SMS_V2_LOCAL_TEST_BUILD=true'] if args.device else []),
         *([f'--build-number={args.build_number}'] if args.build_number else [])],
        cwd=app, env={**os.environ, **({} if args.device else {"PANDAPAY_SIMULATOR": "1"})}, check=True,
    )
    if args.device:
        subprocess.run(['xcodebuild', '-workspace', 'ios/Runner.xcworkspace',
            '-scheme', 'Runner', '-configuration', 'Profile', '-destination', f'id={args.device}',
            '-derivedDataPath', str(rig / 'ios-profile-build'), 'CODE_SIGN_STYLE=Automatic', 'build'],
            cwd=app, check=True)
finally:
    for p, original in files.items():
        if original is not None:
            p.write_bytes(original)
        elif p.exists():
            p.unlink()

built = rig / 'ios-profile-build/Build/Products/Profile-iphoneos/Runner.app' if args.device else app / "build/ios/iphonesimulator/Runner.app"
if args.device:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(built)], check=True)
    subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, str(built)], check=True)
    subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
        '--terminate-existing', 'app.pandapay.pandapay.smsv2rig'], check=True)
if args.simulator:
    subprocess.run(["xcrun", "simctl", "install", args.simulator, str(built)], check=True)
print(built)
