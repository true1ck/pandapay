# Permission status follows Android Settings

Both onboarding and Privacy & Permissions read current device permissions on initial load and each app resume. Settings includes notifications, foreground location, camera, microphone and Android SMS. Approximate foreground location counts as enabled. Status checks never open permission prompts. Failed reads do not retain an old Enabled badge.

Onboarding also rechecks after each individual request or the complete request sequence, covering resume callbacks that arrived while a native dialog was busy. Settings no longer treats launching Android Settings as returning from it.

## Emulator review

- Turned notifications off in Android Settings: Android ended the app process as part of permission revocation; cold launch correctly showed the option disabled.
- Restored notifications in Android Settings: onboarding changed to Enabled on return, in the same process (PID 14615).
- Turned camera off in Android Settings: the refreshed Privacy & Permissions page showed Not enabled.
- Restored camera through its Settings action: the existing Privacy & Permissions screen changed to Enabled on return, in the same process (PID 15354).
- All five native permission statuses matched the displayed rows. Approximate location was granted while precise location was denied, and the Location row correctly remained Enabled.
- No new Flutter or Android runtime errors appeared during these round trips.

Screenshots and `verification.json` record this review. The APK hash in that report identifies the permission-only review build; subsequent tutorial changes are a newer build.
