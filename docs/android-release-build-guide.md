# PandaPay Android build and update runbook

This is the mandatory release procedure for PandaPay Android builds. It exists
to prevent an APK from being shared before its update compatibility, production
configuration, signing, ABI, and integrity have been verified.

## 1. Immutable production settings

Every production build must use:

| Setting | Required value |
| --- | --- |
| Flavor | `prod` |
| Package ID | `app.pandapay.pandapay` |
| API | `https://api.pandapath.site` |
| Auth | `https://auth.pandapath.site` |
| Legal | `https://api.pandapath.site/legal/` |
| Delivery format for phones | Split APK (`--split-per-abi`) |

Do not change these values while preparing a normal update. Development and
staging builds must not be sent as production updates.

## 2. APK and device rules

The split build produces three separate APKs:

| APK | Use |
| --- | --- |
| `app-arm64-v8a-prod-release.apk` | Almost every modern physical phone |
| `app-armeabi-v7a-prod-release.apk` | Older 32-bit ARM phone |
| `app-x86_64-prod-release.apk` | x86_64 emulator only |

Send exactly one APK that matches the target device. Never send the emulator
APK to a phone. Never rename one ABI APK and call it another ABI.

## 3. Mandatory pre-build checks

Run these checks from the repository root before starting a build:

```powershell
adb devices -l
adb shell getprop ro.product.cpu.abilist
adb shell dumpsys package app.pandapay.pandapay | Select-String versionCode
Test-Path app/android/key.properties
```

Record the installed version code and device ABI. If no device is connected,
do not guess the installed version; use the last verified release record or ask
for the device information.

The original release keystore is required for a genuine production update. If
`Test-Path app/android/key.properties` returns `False`, stop the release. The
build wrapper intentionally refuses this case so a debug-signed APK cannot be
mistaken for a production release.

## 4. Version-code rule

The generated Android `versionCode` must be higher than the installed APK's
actual `versionCode`. Do not compare only the requested Flutter build number;
split APKs derive ABI-specific Android version codes from it.

Incident record: the working ARM64 APK supplied on 2026-10-15 had version code
`6012`. The mistaken follow-up build had ARM64 version code `2011`, so Android
correctly rejected it as older. The corrected build used actual version codes:

```text
ARM64: 8013
ARMv7: 7013
x86_64: 10013
```

The version code must be checked from every generated APK before delivery.

Verified phone baseline on 2026-10-16:

| Device | ABI | Installed package version | Signing certificate |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `12027` | Android Debug, SHA-256 `3dda2588c1eb6c14f19dddf3b0af1a6c798bb5c0f81a72b1878d7c39431c1042` |

The ARM64 APK with version code `12027` was installed successfully over USB
without uninstalling the app, and the app launched afterward. Future update
builds for this phone must have an ARM64 version code greater than `12027` and
must match the installed signing certificate. The earlier `8013` APK is lower
than this phone's actual installed `12026` baseline and must not be delivered
to this phone.

## 5. Canonical build command

Use the repository wrapper; do not assemble a production APK with an ad-hoc
command:

```powershell
.\scripts\build_app.ps1 prod apk `
  -SplitPerAbi `
  -BuildNumber N `
  -ApiBaseUrl https://api.pandapath.site `
  -AuthBaseUrl https://auth.pandapath.site `
  -LegalBaseUrl https://api.pandapath.site/legal/
```

Replace `N` only after completing the pre-build version check. Never reuse a
version number for a new delivery.

For a temporary nearby-merchant test build only, add
`-NearbyRadiusMeters 5000`. The app defaults back to the production radius of
2 km whenever this option is omitted. Do not use the test override for a
normal release delivery; the free discovery fallback currently supports only
up to 5 km.

If the project was cleaned, regenerate Flutter plugin metadata with:

```powershell
cd app
flutter pub get
```

Do not substitute plain `dart pub get` after `flutter clean`; it can leave the
Android plugin wiring incomplete, including SMS and widget plugins.

## 6. Mandatory post-build gate

The output directory must contain these three files:

```text
app/build/app/outputs/flutter-apk/
  app-arm64-v8a-prod-release.apk
  app-armeabi-v7a-prod-release.apk
  app-x86_64-prod-release.apk
```

For each APK, verify package, ABI, version, and signature:

```powershell
$apk = "app/build/app/outputs/flutter-apk/app-arm64-v8a-prod-release.apk"
$bt = Get-ChildItem "$env:LOCALAPPDATA/Android/Sdk/build-tools" -Directory |
  Sort-Object Name -Descending | Select-Object -First 1

& "$($bt.FullName)/aapt.exe" dump badging $apk |
  Select-String "package:|versionCode|native-code"
& "$($bt.FullName)/apksigner.bat" verify --verbose --print-certs $apk
Get-FileHash $apk -Algorithm SHA256
```

Do not share the build unless all of these are true:

- package is exactly `app.pandapay.pandapay`;
- flavor is `prod` and production URLs are compiled;
- ABI matches the target device;
- actual version code is higher than the installed version;
- APK signature matches the installed app's signing certificate;
- APK v2 or newer signature verification succeeds;
- SHA-256 is recorded for the file being delivered;
- SMS and notification permissions are present in the manifest.

## 7. Delivery and installation

Use Drive, USB, or another lossless transfer for these large APKs. The phone
must install the file that was hash-checked; do not use a renamed or partially
downloaded copy.

Install only the matching ABI. Do not uninstall the old app first, because that
can remove local data. After installation, open PandaPay and grant SMS and
notification permissions from the app's permission flow. APK manifest entries
cannot silently grant runtime permissions.

## 8. “Package appears to be invalid” diagnosis

Check in this exact order:

1. Compare the delivered file's SHA-256 with the checked build file.
2. Confirm the APK ABI matches the device.
3. Confirm the actual version code is higher than the installed version.
4. Compare the signing certificate SHA-256 digest with the installed app.
5. Confirm the package ID is `app.pandapay.pandapay`.
6. If the certificate differs, locate the original release keystore; do not
   uninstall the app as a workaround.

A valid APK with the wrong signing key or a lower version code cannot update the
installed application. The build wrapper and this runbook are deliberately
designed to catch those two failures before delivery.
