# Device-aware PandaPay authentication

## Findings

The main iOS target lacked `NSFaceIDUsageDescription`. Apple requires this for Face ID authorization. The existing setup sheet also hardcoded a fingerprint icon, “Enable fingerprint lock” and an Android-only privacy sentence, regardless of device capabilities.

Enrollment authenticated the user and then enabled the persisted app-lock flag while the current process still appeared locked. The router could therefore demand a second challenge immediately after successful enrollment.

## Changes

- Add the required Face ID purpose string to the main app's Info.plist and require it in the compiled-app verifier.
- Query the operating system through the installed `local_auth` plugin for device authentication support and enrolled biometric types. Do not infer authentication capability from an iPhone model-name list.
- Use Face ID and a face icon on enrolled Face ID iOS devices; Touch ID and a fingerprint icon on enrolled Touch ID devices. Android uses its reported face/fingerprint capability or a generic biometric label when the OS only reports a strength class. A device with credentials but no available enrolled biometric is described as using device lock, with platform-appropriate passcode/screen-lock wording.
- Apply the same detected labels to enrollment, the lock screen and Account settings. Remove the Android-only privacy statement.
- After successful enrollment authentication, mark this process unlocked before enabling the lock flag. Cancellation does not unlock or enable the feature. The state remains in memory, and cold launches retain the existing app-lock challenge.
- Keep authentication with the operating system's biometric-first device-owner policy. Do not collect an app password, force a password-only policy, disable fallback, or start an automatic retry loop after cancellation. The OS can still require the device passcode when biometrics are unavailable or security policy requires it.

References: [Flutter local_auth](https://pub.dev/packages/local_auth), [Face ID configuration](https://pub.dev/packages/local_auth_darwin), [Apple biometric capability labels](https://developer.apple.com/documentation/localauthentication/lacontext/biometrytype), [Apple device-owner authentication policy](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication).

## Verification

Fifteen focused widget/router tests passed, covering Face ID and Touch ID labels/icons, passcode-only copy, enrollment challenge reuse, cancellation, unsupported devices, retry behavior, and cold/locked/unlocked router enforcement. The full Flutter suite passed **2,351 tests**. Static analysis reported no errors or warnings, with the existing 126 informational notices.

The signed main-app build **1.0.15 (67)** succeeded. Its compiled artifact passed the main-app verifier, including the required Face ID Info.plist entry, device-aware labels, absence of the Android-only enrollment privacy sentence, and the previously corrected SMS action schema. Deep signature verification and `git diff --check` passed. Installation on the paired iPhone succeeded and an app-list read-back confirmed build **67**. The separate prototype remains installed unchanged. No Face ID scan, passcode entry or authentication permission was completed by the tools.

Tests use synthetic OS responses. A successful build/install does not prove that the user granted Face ID permission or completed a physical Face ID scan. Any system-mandated passcode fallback remains under iOS control.
