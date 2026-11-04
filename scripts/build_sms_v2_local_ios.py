#!/usr/bin/env python3
"""Build the local rig's Debug app and optionally install on a simulator."""
import argparse
import json
import pathlib
import re
import subprocess
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("rig", type=pathlib.Path, help="Directory printed by the local rig")
parser.add_argument("--simulator", help="Booted simulator UUID to install on")
args = parser.parse_args()
rig = args.rig.resolve(strict=True)
tmp = pathlib.Path("/tmp").resolve()
if rig.parent != tmp or not rig.name.startswith("pandapay-sms-rig."):
    parser.error("Expected the scratch directory printed by the local rig")
if args.simulator and not re.fullmatch(r"[0-9a-fA-F-]{36}", args.simulator):
    parser.error("Pass an explicit simulator UUID")
defines = rig / "flutter-defines.json"
data = json.loads(defines.read_text())
if (data.get("PANDAPAY_ENV") != "dev" or data.get("SMS_PIPELINE_V2") != "true"
        or not data.get("SMS_V2_LOCAL_CA_PEM")):
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
lock = app / "ios/Podfile.lock"
swift_lock = app / "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
files = {p: p.read_bytes() if p.exists() else None for p in (project, lock, swift_lock)}
try:
    # Keep the simulator QA app distinct from the normal PandaPay install.
    original = files[project].decode()
    local = original.replace(
        "PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.pandapay",
        "PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.pandapay.smsv2rig",
    )
    if local == original:
        raise RuntimeError("Runner bundle identifier was not found")
    project.write_text(local)
    subprocess.run(
        ["flutter", "build", "ios", "--debug", "--simulator",
         f"--dart-define-from-file={defines}"],
        cwd=app, env={**os.environ, "PANDAPAY_SIMULATOR": "1"}, check=True,
    )
finally:
    for p, original in files.items():
        if original is not None:
            p.write_bytes(original)
        elif p.exists():
            p.unlink()

built = app / "build/ios/iphonesimulator/Runner.app"
if args.simulator:
    subprocess.run(["xcrun", "simctl", "install", args.simulator, str(built)], check=True)
print(built)
