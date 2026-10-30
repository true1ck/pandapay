# Onboarding navigation and iOS permissions

This follows the main iPhone SMS implementation. Changes are on `codex/ios-shortcuts-prototype`; Android shares the Dart navigation changes, while the native permission fix is iOS-specific.

## Problems corrected

- iOS had the usage descriptions but did not enable the `permission_handler_apple` camera, microphone, notification or location strategies in CocoaPods. The Podfile now enables those strategies in Debug, Profile and Release. Location remains read/requested through Geolocator for foreground access; background location is a separate opt-in.
- iOS skipped straight to permission step 2. It now has a first SMS page that opens the main PandaPay Shortcuts setup, without requesting Android-only inbox permission. Back from optional permissions returns to that page.
- Returning from setup could expose sign-up/sign-in even with an active session. The introduction now offers **Continue setup** for signed-in users. Account activation is still enforced when continuing; Back does not clear credentials or complete onboarding.
- Adding cards replaced the previous route. It now pushes card details and keeps selection. Returning and continuing reuses the cards already added during that screen session, including successful additions preceding a failed request.
- Card introduction, card details, tracking setup, account activation and All Set now have explicit back arrows and cold-start fallback destinations. The same in-page step rules handle Android system Back. Tour Back visits the previous slide; OTP Back returns to the identifier form.
- Card details keep draft values when traversing cards. Missing card-detail route arguments recover to the card page instead of failing a cast/index lookup.
- Returning from a tracking-channel screen stays on the channel menu. Only **Continue** or **Set up later** advances to All Set. Back from All Set returns to the previous setup screen without marking setup complete.

## Permission behavior

Grants are re-read from the OS, including after returning from Settings. Permanently denied access opens Settings only on that row's explicit action. Restricted or declined permissions remain optional. The combined permission button skips grants already present and requests the remaining permissions sequentially. Quiet/provisional notification access is recognized as enabled.

The native configuration follows the package's [iOS setup](https://pub.dev/packages/permission_handler#ios). Shared back handling follows Flutter's [PopScope behavior](https://api.flutter.dev/flutter/widgets/PopScope-class.html). A system permission dialog or final account-completion request can temporarily disable navigation while its operation finishes.

## Validation

Regression coverage includes iOS and Android permission-step Back, unchanged credentials, main SMS setup return, grant/denial/Settings refresh, card-selection replay without a second add, card draft preservation, cold-start recovery, tracking-channel return, tour slides, and activation enforcement. Existing onboarding completion and OTP tests are included in the focused suite.

On-device permission dialogs still require the user's tap and choice. Compiled strategy verification is separate from claiming a real-device grant; existing denied permissions may need the **Settings** action after updating.

Verified checks:

- Full Flutter suite: **2,337 tests passed**, including ten new navigation/permission regression scenarios.
- Static analysis: **zero errors and zero warnings**, with 126 informational notices elsewhere in the repository.
- Podfile syntax and required iOS usage descriptions checked. Generated CocoaPods configurations include the permission definitions in all three build configurations.
- The main-app artifact verifier now rejects builds missing the native audio/video, notification or location strategies, alongside its existing main-app/SMS action checks.

The signed **PandaPay 1.0.15 (63)** Profile build passed the artifact verifier and deep code-signature validation, then installed successfully on the paired iPhone 16 Pro Max. Device read-back confirmed build 63; iOS launched the main bundle and its process remained running at the follow-up check. The prototype remains installed. No account data or existing permission choice was reset.

Visual phone testing was unavailable because iPhone Mirroring reported **iPhone in Use** and a disconnected mirror. This result does not claim that a user has granted a real-device permission. Test **Enable** (or **Settings** for a previous denial), Back between the two permission pages, and Back through cards/tracking/All Set on the phone. The Android navigation source is updated and covered by platform-specific widget tests; this follow-up does not publish an Android release.
