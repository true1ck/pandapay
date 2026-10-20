# PandaPay account entry redesign

Implemented in Flutter for review on the Pixel 9 Pro emulator. The reference is saved as `design-reference.png`.

## Screens

- Welcome: the existing wallet panda, three swipeable introductions, direct sign-up and sign-in actions.
- Sign-in: the matching peeking panda over native green waves.
- Sign-up: the same form styling, required terms consent and separate optional contribution/marketing choices.
- OTP: the matching envelope panda, one accessible input rendered as four cells, numeric paste/autofill, change-email and resend actions.
- Permissions, tour, first-card introduction and completion use the shared entry palette and components.

Existing authentication APIs, local test identifiers and consent writes are preserved. The card introduction opens the real card picker and keeps its skip path.

## Artwork

Project assets are in `app/assets/illustrations/`. Existing `app/assets/logo/pandapay_mark.png` is reused without modification on welcome and first-card screens.

`panda_peek.png` and `panda_mail.png` were generated with the built-in image generation tool, using the existing logo and supplied UI reference. Both have a real transparent alpha channel. The exact prompt set is in `image-prompts.md`.

The two animated WebP files are cropped image sequences derived from the previously approved Gemini renders, and play once. The source MP4 files and Blender files are not packaged in the app. The marked outer regions are excluded from these exports; the spending scene uses the cleaner chart illustration rather than the generated phone with unreadable labels. The shared widget fades the outer background and supports the system reduced-motion preference.

- `panda_card_story.webp`: 71 frames over 4.75 seconds; source `artifacts/panda-mascot/pandapay_onboarding_overwhelmed_gemini.mp4`, first 4.75 seconds, crop 620×930 at (80,190).
- `panda_spending_story.webp`: 84 frames at approximately 15 fps; source `artifacts/panda-mascot/pandapay_onboarding_gemini.mp4`, 4.2–9.8 seconds, crop 720×950 at (0,180).

## Review artifacts

The PNGs are actual emulator screenshots. `screens-review.png` collects the welcome, sign-in, sign-up, OTP and first-card screens. `emulator-motion-review.mp4` is a recording of the running application, not a video asset used by it.

## Validation

- Flutter analysis: no issues in the modified onboarding/auth code and layout checks.
- 12 focused widget checks passed: routing/back navigation, required and optional consent behavior, active-OTP handling, successful verification, numeric input/paste, and narrow screens at 200% text scaling.
- Android dev debug APK built, installed on the emulator and reviewed using the local test account.
- Manual flow exercised through OTP, optional permissions, tour, real card picker, completion, account settings and sign-out.

No Play Store upload or release is part of this change.
