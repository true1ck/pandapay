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

For a local physical-device regression test over an already debug-signed
installation, the wrapper has one explicit exception:
`-AllowDebugSigningForDeviceTest`. It is accepted only for the `prod` flavor,
only when the release keystore is absent, and only with an explicit build
number. This keeps the package ID and hosted endpoints identical for testing
while making it impossible to accidentally use debug signing when the release
keystore is available. Such an APK must not be distributed as a production
release.

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

Verified phone baseline before this update on 2026-10-16:

| Device | ABI | Installed package version | Signing certificate |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `12027` | Android Debug, SHA-256 `3dda2588c1eb6c14f19dddf3b0af1a6c798bb5c0f81a72b1878d7c39431c1042` |

The ARM64 APK with version code `12027` was installed successfully over USB
without uninstalling the app, and the app launched afterward. Future update
builds for this phone must have an ARM64 version code greater than `12027` and
must match the installed signing certificate. The earlier `8013` APK is lower
than this phone's actual installed `12026` baseline and must not be delivered
to this phone.

Verified update on 2026-10-17:

| Device | ABI | Installed package version | APK SHA-256 | Signing certificate |
| --- | --- | ---: | --- | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `14029` | `7A3D03EDB71EB44347BEDCA3190670A2ABC6258FD0BFFA735773137581340B8B` | Android Debug, SHA-256 `3dda2588c1eb6c14f19dddf3b0af1a6c798bb5c0f81a72b1878d7c39431c1042` |

The update was installed with `adb install -r`; local app data was preserved and
the app launched afterward. Future update builds for this phone must have an
ARM64 version code greater than `14029` and must match the same certificate.
The matching build command used `-BuildNumber 12029`, which produced ARM64
`14029`, ARMv7 `13029`, and x86_64 `16029`.

Verified update on 2026-10-18:

| Device | ABI | Installed package version | APK SHA-256 | Signing certificate |
| --- | --- | ---: | --- | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `18036` | `911FD22C2F884F9ACEEB90BFB6363B05665E75194512095CF2FA25A3AAADD953` | Android Debug, SHA-256 `3dda2588c1eb6c14f19dddf3b0af1a6c798bb5c0f81a72b1878d7c39431c1042` |

The ARM64 split was installed with `adb install -r` and launched; app data was
preserved. The build used `-BuildNumber 16036` and produced ARM64 `18036`,
ARMv7 `17036`, and x86_64 `20036`. All three APKs were verified to use the
expected package ID and the same Android Debug certificate. The debug-signed
APK is for this connected-device test only and is not distributable. Future
updates for this phone must have an ARM64 version code greater than `18036`
and match the same certificate.

Verified nearby-merchant name/address update on 2026-10-18:

| Device | ABI | Installed package version | APK SHA-256 |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `20046` | `121F3D60D4C6A9295482866A837F9812493A824D70826E31628C82723203A35C` |

Built with `-BuildNumber 18046`, the hosted production endpoints, and
`-AllowDebugSigningForDeviceTest`. The ARM64 package ID and Android Debug
certificate matched the baseline above. Installed with `adb install -r` over
version `20045`; existing account and wallet data remained available.

On-device manual searches verified that `Shell Bengaluru` displays station
names, addresses, and card suggestions, while `petrol pump` explicitly marks
generic map names as business-name unavailable and displays their addresses.
These checks used the hosted API before deployment of the metadata enrichment;
brand/operator substitution is additionally covered by API regression tests.
All 365 API tests, 10 Flutter repository tests, and analysis of the changed
Flutter screen/repository passed. This debug-signed build is for the connected
device only. Future updates must exceed version `20046` and match its certificate.

Verified background-alert persistence update on 2026-10-18:

| Device | ABI | Installed package version | APK SHA-256 |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `20047` | `96789047D79B5F10423939345E5A3664626F0976D26CDCC0357911E2A1DC2E3E` |

Built with `-BuildNumber 18047`, the production endpoints, and the explicit
debug-signing device-test exception. The signing certificate matches the
baseline above. Installed over version `20046` with `adb install -r`, preserving
app data. On-device checks verified saved On/Off choices across force-stop and
reopen, automatic monitoring restoration, and permission-loss/recovery status.
See [background merchant alerts](background-merchant-alerts.md) for details.
This is a connected-device test build only. Future updates for this phone must
exceed version `20047` and match the same signing certificate.

Verified local-first device-test update on 2026-10-18:

| Device | ABI | Installed package version | APK SHA-256 |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `20048` | `6896EA0C4FADB75DA5F1BA0BC3288F7A18CE4E1E5B37609322CF621EEDC31BDB` |

Built with `-BuildNumber 18048`, the hosted production endpoints, and
`-AllowDebugSigningForDeviceTest`. The ARM64 split has the production package ID,
the expected SMS and notification permissions, a valid APK v2 signature, and
the same Android Debug certificate as the installed version. `adb install -r`
updated the phone from `20047` without clearing app data. The app launched,
showed the existing wallet, and Payments due displayed its saved card and due
date while a stored refresh status indicated authentication trouble; that
status was later found to be an unreliable sign-in signal. The prior full-screen
refresh error did not appear. A force-stop and relaunch succeeded. This verifies local display
through the expired-session state, but does not establish background SMS capture
or server reconciliation. This debug-signed APK is for the connected device
test only. Future updates for this phone must exceed version `20048` and match
its certificate.

Verified session-banner device-test update on 2026-10-18:

| Device | ABI | Installed package version | APK SHA-256 |
| --- | --- | ---: | --- |
| Motorola edge 50 fusion (`ZA222MS4SF`) | `arm64-v8a` | `20050` | `2838BEA8BC32D4ED770802927E201026E126E726B6B6B6C0EA58FEB495831E68` |

Built with `-BuildNumber 18050`, hosted production endpoints and the explicit
debug-signing device-test exception. The ARM64 package ID and Android Debug
certificate match the preceding installed version, and APK v2 verification
passed. Installed using `adb install -r`, preserving app data. Home and
Payments due rendered saved content without a sign-in or bulk pending-SMS
warning. This is not a distributable release. Future updates for this phone
must exceed version `20050` and use the same signing certificate.

## 5. Canonical build command

Use the repository wrapper; do not assemble a production APK with an ad-hoc
command:

```powershell
.\scripts\build_app.ps1 prod -Target apk `
  -SplitPerAbi `
  -BuildNumber N `
  -ApiBaseUrl https://api.pandapath.site `
  -AuthBaseUrl https://auth.pandapath.site `
  -LegalBaseUrl https://api.pandapath.site/legal/
```

Replace `N` only after completing the pre-build version check. Never reuse a
version number for a new delivery.

For the currently connected debug-signed test phone only, append:

```powershell
  -AllowDebugSigningForDeviceTest
```

This does not change the production signing requirement for distributable
builds.

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
