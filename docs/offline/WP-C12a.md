# WP-C12a: offline fonts and Android/iOS platform config

Branch `offline/c12a`. Covers P-01, P-02, P-04 (note only), U-03 (Android parts, FCM timeout, `launchUrl`) from
`docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`. The rest of WP-C12 (ErrorState, cold-start caps, logos) is not in this package.

## What changed

| Area | Change |
|---|---|
| Fonts (P-01) | Outfit (Regular, Medium, SemiBold, Bold, ExtraBold) and IBM Plex Sans (Medium, SemiBold, Bold) bundled as static TTFs in `app/assets/google_fonts/` under the exact Google API filenames `google_fonts` matches. `- assets/google_fonts/` added to `pubspec.yaml`. SIL OFL 1.1 texts shipped next to them (`OFL-Outfit.txt`, `OFL-IBMPlexSans.txt`). |
| Runtime fetching | `GoogleFonts.config.allowRuntimeFetching = false;` at the top of `main()`. A first-ever offline launch now renders the brand fonts, and a missing weight can no longer start an HTTP fetch that retries on every build. |
| Android manifest (P-02) | `INTERNET` declared in `src/main` (release used to get it only transitively). `<queries>` gains an `https` VIEW intent so `canLaunchUrl` works on Android 11+. Existing queries untouched. No exact-alarm permission added. |
| FCM (C-xx) | `PushNotificationService.start()` bounds `FirebaseMessaging.getToken()` with an 8 s timeout (`boundedTokenRead`). The `TimeoutException` goes to the existing catch, which tears the attempt down and schedules the existing backoff retry. Online behaviour is unchanged. The App Check timeout is not touched (sms_v2 package). |
| `launchUrl` (U-03) | The "Open portal" button in `card_detail_screen.dart` now goes through `tryOpenExternalUrl` (never throws) and shows "Could not open your browser." on failure, same copy as the discover/comparison screens. |

## Font provenance

Every file was downloaded from the exact `fonts.gstatic.com/s/a/<sha256>.ttf` URL that `google_fonts 6.3.3` itself would fetch
(URL, SHA-256 and length come from the package tables in `google_fonts_parts/part_o.g.dart` and `part_i.g.dart`), into an empty scratch
directory, and checked for SHA-256 match, exact length and the TrueType magic number (`00 01 00 00`) before being copied.
Nothing was executed from the download directory.

| File | Bytes | SHA-256 |
|---|---|---|
| Outfit-Regular.ttf | 47820 | b667551a8e7d406c089cb2fdf754f2fddfb1dc256a33fcc06c690965c6b9d5d7 |
| Outfit-Medium.ttf | 47776 | 593c02128a0077461e58f5c86a2432a3894ad365c8302f13120fc17b2c4aad88 |
| Outfit-SemiBold.ttf | 48432 | 3b9c6753e282f674c8acfa64c24eba2057c1c123830595cba4e3adbf8c5e9f24 |
| Outfit-Bold.ttf | 48316 | 8d3a851bbdbcef9f4e7bbee2ffdb74271a80d745c40dbb68888e5759d5976477 |
| Outfit-ExtraBold.ttf | 48248 | 95f91a67031e82a8ddcdbac44fcf4fff74e58f1e017f1759f90087390922f14a |
| IBMPlexSans-Medium.ttf | 121932 | b57cd7eed0b12d7a8f9242acb5507b7f9e51fe58ed7d0222493cb987c7e58fae |
| IBMPlexSans-SemiBold.ttf | 121732 | 3f31f30a0d4601ed4b3e0715294eca84276e308cfb39aefcdd31acba96135c60 |
| IBMPlexSans-Bold.ttf | 120132 | 22d9094b915bab632e8f5f38c53b2a1886dfc7fd232bdf876067a5a62313b669 |

Total added: 613,233 bytes (about 0.6 MB) including the two licence files (8,845 bytes).

Licences: Outfit (Copyright 2021 The Outfit Project Authors) and IBM Plex Sans (Copyright 2017 IBM Corp., Reserved Font Name "Plex") are
both SIL Open Font License 1.1. The licence texts are the upstream `ofl/outfit/OFL.txt` and `ofl/ibmplexsans/OFL.txt` from the
`google/fonts` repository, unmodified. The fonts are unmodified, so the Reserved Font Name clause is not triggered.

## Why these weights

Grep of `lib/`: Outfit is requested at w400/w500/w600/w700/w800 (`FontWeight.wNNN` appears 672 times; the Material text themes add
w400/w500/w700). IBM Plex Sans is only reached through `BambooFonts.money`, whose default is w800 and whose explicit weights are w500, w600
and w700. IBM Plex Sans has no ExtraBold, so w800 resolves to Bold (`google_fonts` picks the closest variant). No call uses Plex w400, so
`IBMPlexSans-Regular.ttf` is deliberately not bundled; if a future call needs it, add it (hash
`075e6118452d96b7885561e874425e99987243c040df7f6bc8d4d4999c5a4f2c`, 120340 bytes) and extend the test.

## Visual parity for an online user

Same families, same weights, same variant matching. `google_fonts` already checks the asset manifest before the device cache and before
HTTP, and the files are byte-identical to what it downloads (hash-verified), so an online user gets the same glyphs, now loaded from the
bundle. Only the source changes. Not checked on a device or with goldens (goldens use Ahem).

## Tests

- `app/test/app/offline_fonts_test.dart` (new): runs with `allowRuntimeFetching = false` and the real asset bundle. Asserts the eight font
  files and an OFL file are in the asset manifest; resolves every Outfit weight w400-w800 and every IBM Plex weight w500-w800 through
  `GoogleFonts.*` and awaits `pendingFonts()` (throws if any asset is missing); builds `BambooFonts.ui/heading/money` for all weights and both
  `AppTheme.light()` / `AppTheme.dark()`; and a negative case (Plex w400, not bundled) proving the test can fail. It failed with all
  `... was not found in the application assets` errors before the fonts were added.
- `app/test/features/notifications/push_token_timeout_test.dart` (new): 8 s constant, a never-completing read becomes `TimeoutException`,
  a prompt read (token or null) passes through.
- `app/test/features/cards/card_detail_open_portal_test.dart` (new): launcher true, false, `PlatformException`, malformed URL.
- Test helpers `BambooFonts.useSystemFontsForTests` and `test/flutter_test_config.dart` (never-responding fonts client) are unchanged and
  still work.

## Known gaps and follow-ups

- iOS (U-03 [I]): `UIBackgroundModes` lacks `remote-notification` and `Runner.entitlements` lacks `aps-environment`. Not changed: it needs a
  device check and Apple provisioning, so it was not "clearly required" for this package.
- The OFL texts are shipped as assets but not registered with Flutter's `LicenseRegistry`, so they do not appear in `showLicensePage`.
  Optional follow-up.
- `rive: ^0.14.11` is declared in `pubspec.yaml` and nothing under `app/lib`, `app/test` or `packages/` imports `package:rive`. It can be
  removed in a separate commit (not done here).
- Manifest checks done: XML parses; `scripts/check_prod_manifest.sh` denylist does not mention INTERNET or `<queries>`. A real
  `flutter build apk` merged-manifest check was not run.
