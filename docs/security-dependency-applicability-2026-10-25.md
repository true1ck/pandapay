# Dependency license and applicability review — 2026-10-25

## Scope and result

This is a source and lockfile review of the working tree on 2026-10-25. It reads the current npm, Dart, CocoaPods, and SwiftPM locks plus the locally vendored `telephony` source. Dependency and cache inspection was offline; a primary-source lookup was used only to check the public CSQLite repository description. No dependency versions, lockfiles, native declarations, or application behavior changed. The bounded scanner emitted by `node db/scripts/review_dependency_licenses.js` reports lock-only evidence; `node db/scripts/release_dependency_inventory.js` hashes local inputs. Supplementary native cache evidence is saved in the linked private temporary manifests below.

**Result: incomplete.** The existing npm audit artifact reports zero advisories for its scanned API and auth lockfiles, but that does not clear native or Dart dependencies, license obligations, package support, or app applicability. Several license/provenance questions remain unreviewed below. No “safe” conclusion is drawn from absent metadata.

## Resolved source evidence

Lock SHA-256 values below bind the observations to the inputs reviewed. Package counts exclude the npm lock root entry and count CocoaPods subspecs as the lock records them.

| Ecosystem / lock | Resolved entries | License evidence | Provenance evidence |
|---|---:|---|---|
| API npm (`api/package-lock.json`) | 98 | 98 have `license` metadata: MIT 87, ISC 7, BSD-3-Clause 2, BSD-2-Clause 1, Apache-2.0 1. Metadata is not a legal approval or a source-file/notice check. | npm lock integrity on 98/98; SHA-256 `78d576e00816012541e0c414ec45351d07b9e327fa194ed726193351bba9ef5c`. |
| Auth npm (`auth/package-lock.json`) | 186 | 186 have `license` metadata: MIT 135, Apache-2.0 37, ISC 8, BSD-3-Clause 3, BSD-2-Clause 1, MIT-0 1, 0BSD 1. Metadata is not a legal approval or a source-file/notice check. | Integrity on 186/186; SHA-256 `802ee82ef90e7b557bd077a4591fd7342e86f74761c912e4830449a000345497`. |
| App Dart (`app/pubspec.lock`) | 235 | Cached hosted package `LICENSE` files exist for 225/225 hosted entries. Evidence also includes the vendored telephony MIT license; the nine remaining SDK/path entries are listed below. Presence is not content review. SHA-256 `a37b99c5b9e62e28c9075053285449e18b2267c6c27a80ee57d838cb54574bfe`. | Hosted package content hashes are in lock; 7 SDK and 3 path entries. |
| Console Dart (`console/pubspec.lock`) | 98 | Cached hosted package `LICENSE` files exist for 93/93 hosted entries; five SDK/path entries below. SHA-256 `e7f59fc389ccc15499f1745d5d0f93e04b6451fa6ae6ce9cdf6c1a6539facbdf`. | Hosted content hashes are in lock; 4 SDK and 1 path entries. |
| Lints Dart (`packages/pandapay_lints/pubspec.lock`) | 43 | Cached hosted package `LICENSE` files exist for 43/43 hosted entries. SHA-256 `94e9cc9da7cdd52a62359a1fed5ca12c4c9d10cd137412310f153e73f902929c`. | Hosted content hashes are in lock. This is a development tooling package, not app runtime. |
| iOS CocoaPods (`app/ios/Podfile.lock`) | 77 | The lock alone has no license terms. Supplementary local evidence matched 26/26 cached public podspec JSON files to the lock's version and checksum prefix; all have a license field. All 27 local Flutter podspec JSON files also have a license field. The installed source tree contains 19 external pod license files (four distinct content hashes); 25 of 26 non-Flutter local plugin source roots have the declared license file. Terms were not legally reviewed; six Google ML Kit specs give only a `Copyright` label/text. SHA-256 `c51e6dfaf93dd8550e2b40ac243bf501a0912c2de7f9a1366f52d34a10adcfb8`. | Pod versions, trunk spec-repo origin, checksums, and local Flutter plugin paths are locked. The 77 entries map to 53 unique base specs (26 public and 27 local); subspecs account for repeated base names. Aggregate SHA-256 of sorted normalized path/file SHA-256 pairs: public specs `7c99f33a36f396e7a22f363604b3b639cdcc512aac9cafddecc8153e3a853955`, local podspecs `e6d6654f2d9213d11615f69012942caba227b9db44e28f8a058ff54128dfcc4b`. |
| iOS SwiftPM (`app/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) | 1 | No local SwiftPM checkout/cache for CSQLite was found. Its [upstream repository](https://github.com/simolus3/CSQLite) describes it as SQLite and states SQLite is public domain, but the exact pinned revision's license file could not be fetched and remains unverified. SHA-256 `862e34bd50494de33fe88711a4cca6a3494f2c341ec2efce323189ed317c0f79`. | Pin identity `csqlite`, URL `https://github.com/simolus3/CSQLite.git`, revision `1ee46d19a4f451a7aa64ffc64fc99b4748131e62`. |

The npm audit artifact at `artifacts/security-dnmw-2026-10-25/npm-audit-summary.json` was checked against the same API/auth lock hashes and records zero known advisories in those two scopes at its recorded timestamp. It says nothing about other ecosystems or license compatibility.

### Dart entries without cached hosted-package license files

These are preserved as unknown by the lock-only scanner rather than treated as licensed packages. SDK entries are Flutter/Dart toolchain sources, and path entries are repository sources; they need review in those source locations or explicit scope treatment. The `telephony` path entry is separately supported by the checked-in MIT license described below.

- App: `flutter`, `flutter_driver`, `flutter_test`, `flutter_web_plugins`, `fuchsia_remote_debug_protocol`, `integration_test`, `sky_engine` (SDK); `pandapay_domain`, `pandapay_lints` (path).
- Console: `flutter`, `flutter_test`, `flutter_web_plugins`, `sky_engine` (SDK); `pandapay_domain` (path).

## Native resolution and applicability

The iOS lock makes 77 CocoaPods entries concrete, including Flutter plugin pods and transitive pods such as Firebase, Google ML Kit, AppAuth, nanopb, Promises, and sqlite3. The cached public podspec files' five-character filename checksum prefixes matched the full checksum entries in `Podfile.lock` for all 26 public specs. Their license metadata groups as 11 Apache-2.0, 4 Apache, 1 “Apache License, Version 2.0”, 2 ISC, 1 zlib, 1 Public Domain, and 6 `Copyright` entries. The last group does not establish an open-source license grant. AppAuth declares an Apache 2.0 license string and its installed `LICENSE` file is present. The 27 local podspecs all declare license metadata; 25 non-Flutter plugin source roots have a file at the declared license path. The Flutter engine wrapper's license field is BSD and the Flutter SDK root license is present. The `integration_test` wrapper says a BSD-style license can be found in `LICENSE`, but no package-local file was found. These results are source evidence, not legal compatibility approval. Package-level podspec/license hashes are listed in [pod-license-evidence.json](../artifacts/security-storage-2026-10-25/pod-license-evidence.json) (35,291 bytes, SHA-256 `b071d6dd665e43a569be512437007794b7b00b0ef6781b4d9ab7d3b26faf46eb`). The directory's [dependency-evidence.json](../artifacts/security-storage-2026-10-25/dependency-evidence.json) summarizes retained evidence and unresolved states.

The Flutter SDK root `LICENSE` exists and has SHA-256 `a598db94b6290ffbe10b5ecf911057b6a943351c727fdda9e5f2891d68700a20`. No `LICENSE*` files exist in `packages/pandapay_domain` or `packages/pandapay_lints`; these first-party path packages remain policy-unresolved. The installed external Pod license files total 19 and have four distinct SHA-256 values; the aggregate hash over sorted `path<TAB>file-sha256<LF>` rows is `8e1a7ddd3b3f269ea809ba4aad4b17c6f461ed52af2fbd4a55d47aa8aea78b44`.

SwiftPM pins `CSQLite` at the revision above. It is part of the iOS native dependency graph through the SQLite support in the app's dependency setup, so its license and shipped-artifact inclusion remain relevant to check. The exact revision tree, commit, raw `LICENSE.md`, and GitHub API contents route were requested from the official repository; the web tool returned cache-miss or inaccessible-URL errors for those immutable paths. The current [official repository page](https://github.com/simolus3/CSQLite) says CSQLite packages SQLite and calls SQLite public domain, but that current-page text is not attributed to the pinned commit. No immutable license file or hash is available from this review.

An offline Gradle dependency report succeeded for `:app:dependencies --configuration devReleaseRuntimeClasspath --offline --no-daemon`. The 1,110-line tree selects 197 external coordinates and references 28 Flutter plugin project modules. The sanitized report at [android-resolved.txt](../artifacts/security-storage-2026-10-25/android-resolved.txt) is 82,123 bytes with SHA-256 `4472044f74385882fbea92fcc13d8aff301ee8fcf5fe2550485b61d334cbed0d`. Its bounded [cache fingerprint manifest](../artifacts/security-storage-2026-10-25/android-cache-evidence.json) has SHA-256 `3efd9ee5af251ce197be7c5275cca6c3e522cdb64108ba4c558d59f9106f01dd`; it lists 168 exact-coordinate cached jar/AAR/zip/klib files totaling 166,935,107 bytes with per-file SHA-256. This proves only that matching artifacts exist in the local Gradle cache; it does not prove their inclusion in an APK. The dependency task produced no APK and did not change a Gradle lockfile. Gradle also executed included Flutter build-logic tasks, including `compileKotlin`, and used local Gradle cache/build-report state. Existing app build outputs were preserved.

For native/applicability decisions, this Android graph is for `devReleaseRuntimeClasspath`; production and staging runtime graphs still need comparison. The Dart development lints lock is development-only. Existing APK hashes in `artifacts/security-dnmw-2026-10-25/native-build-artifacts.json` demonstrate built artifacts existed, but they do not prove that every locked or cached dependency is shipped.

## Vendored telephony

`app/third_party/telephony` identifies itself as `telephony` 0.2.0 and links to `https://github.com/shounakmulay/Telephony`. Its checked-in `LICENSE` is MIT and names Shounak Mulay, copyright 2020. The local `PANDAPAY_PATCH.md` enumerates PandaPay changes to Android toolchain metadata and permission callback handling. The local package is used as a path dependency in the app and appears as a local iOS pod; this makes it directly applicable to the mobile app.

The upstream identity is documented, but an immutable upstream commit or original package archive hash was not established. The vendor directory's per-file source hashes are retained in `artifacts/security-dnmw-2026-10-25/dependency-inventory.json`; those hashes identify the current local patched source only. The MIT notice should be retained with distributed copies. The review did not compare every patched file to a specific upstream revision.

## Remaining evidence required for completion

1. Review actual package license texts/notices for all 98 API and 186 auth npm entries, including downstream notice/attribution duties; lock metadata alone is insufficient.
2. Review the 361 cached hosted Dart package license texts (225 + 93 + 43 lock occurrences; packages may repeat across locks), and determine release-variant inclusion. Confirm SDK and first-party path package policy explicitly.
3. Review the actual license terms and acknowledgements for all 77 Podfile.lock entries, including the six Google ML Kit `Copyright` records and the local Flutter plugin licenses.
4. Verify CSQLite's license at the exact pinned revision; the local SwiftPM cache has no checkout to inspect.
5. Review license metadata and app inclusion for the 197 Android coordinates in the resolved dev graph; compare production and staging runtime graphs.
6. Establish telephony's upstream commit/archive provenance and compare local changes while retaining the MIT license and copyright notices.

Until those items are addressed, this report is evidence of scope and known metadata only; it is not a license compatibility determination, dependency support assessment, or release clearance.

## Primary references

- [npm package-lock format](https://docs.npmjs.com/files/package-lock.json/) — lock package records can carry a `license` metadata field and integrity values.
- [Dart package layout](https://dart.dev/tools/pub/package-layout) — published package layout recommends a root `LICENSE` file; a file's presence is not a review of its terms.
- [Dart versioning and lockfiles](https://dart.dev/tools/pub/versioning) — lockfiles record selected dependency versions/content hashes.
- [CocoaPods podspec license field](https://guides.cocoapods.org/syntax/podspec.html) — license terms are specified by podspec metadata/source license files, not the lockfile.
- [Swift Package Manager package resolution](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html) — `Package.resolved` records the dependency resolution.
- [Upstream CSQLite repository](https://github.com/simolus3/CSQLite) — current repository description identifies SQLite and states its public-domain status; this review could not verify that text at the pinned revision from local source.
- [Upstream Telephony repository](https://github.com/shounakmulay/Telephony) and [pub.dev Telephony API](https://pub.dev/documentation/telephony/latest/telephony/) — upstream identity reference; local checked-in license and patch remain the reviewed evidence for this checkout.

## Current bounded tool update

The root-reviewed tool now also includes the shared domain lock, validates Dart package names/versions before resolving cache paths, checks lock read stability and never prints parser error context. Its current [machine report](../artifacts/security-storage-2026-10-25/dependency-license-review.json) includes 8 locks and 92 unresolved entries. Earlier 92-entry counts above describe the initial seven-lock tool slice; supplemental Pod/SDK metadata remains separate evidence, not automatic legal approval. The current focused tool suite has five tests, including CLI exit 2 whenever unresolved license evidence remains.
