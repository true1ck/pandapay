# PandaPay permission onboarding review

Implemented after authentication for accounts that have not completed onboarding.

## Short flow

1. **SMS access (Android):** benefit preview, on-device filtering and server-processing disclosure, native permission action, and manual-entry alternative.
2. **Actual inbox import:** indeterminate progress with real checked/matched counts. Provider IDs are not treated as percentages. Captured alerts create local spending data; account sync runs separately and does not block setup. Continue in background remains available.
3. **Import result:** actual saved-alert / available SMS-spend totals from the shared account-scoped financial store. Empty and retry states are supported; pending sync is explained.
4. **Useful extras:** one compact page for notifications, foreground location, camera and microphone. Each has a purpose and a separate native grant. Background alerts remain a separate opt-in in Nearby.
5. Continue directly to the existing first-card step. The feature tour remains available separately, avoiding duplicate slides during sign-up.

The two permission explanation steps reuse the approved transparent panda artwork. Message cards, charts and progress are native Flutter UI, with no new bitmap assets or video dependency.

## Review media

- `screens-review.png`: four actual app screens together.
- `03-import-result.png`, `04-permission-choices.png`: full-resolution emulator captures.
- `01-sms-permission.png`, `02-importing.png`: clean actual frames extracted from the final recording; this small sample inbox completes quickly.
- `permission-flow.mp4`: final emulator recording at 720 × 1606.

## Manual verification

- Built and installed the dev debug APK against the local backend.
- Native SMS denial leaves manual setup available; no automatic jump to Settings after an ordinary denial.
- Native SMS grant triggers the existing paged, durable inbox pipeline.
- Sample bank-spend and bill alerts captured; sample OTP/security and personal messages excluded. A repeated bank alert did not add another spend: final result remains two unique alerts and one available SMS spend.
- Location and microphone native grants return to the app without a crash. Approximate location is recognized as allowed, with background location still denied.
- Camera native grant succeeds after SMS capture. Notifications previously blocked can be enabled through Android Settings; returning refreshes the UI to Allowed.
- All four extra permission rows were verified as Allowed. Continue opens first-card setup directly; system Back returns to the permission controls.
- Smaller 320 × 640 viewport and 200% system text: content scrolls, Continue remains reachable, no Flutter layout/runtime errors observed. Original emulator size and font scale restored.
- Final targeted static analysis: no issues. Final dev APK build and `git diff --check`: successful.
- Automated tests were not added or run for this change.

## Related fix

The vendored telephony plugin replayed its last SMS MethodChannel result when another plugin received a permission callback, causing an Android “Reply already submitted” crash. The callback now verifies both ownership and active request state before handling a result; cancelled results are denied. This is documented in `app/third_party/telephony/PANDAPAY_PATCH.md`.

Push startup and iOS local-notification initialization no longer request permission before the explanation. Token registration remains intact. Location uses Geolocator’s foreground status so approximate access is accepted.

The review uses local test-account and SMS fixtures, not a production account or a Play upload.
