# Background merchant alerts

## Behavior

The opt-in is saved on the device under the signed-in account's cache namespace
(`nearby_background_alerts_v1`). A different account and signed-out mode do not
inherit it. Saving Off stops monitoring and prevents restoration at startup.

The application root restores an enabled monitor on startup and resume,
including launches directly into an assistant screen. Restoration checks GPS,
background location permission, and OS notification permission without requesting
permissions. Only explicitly enabling alerts requests permissions.

The saved preference and runtime health are separate. The switch can stay On
while its subtitle reports location disabled, permission required, notifications
disabled, or a temporary failure. Retry and system Settings actions are shown
where appropriate. Returning from Settings rechecks availability.

The foreground location service watches published PandaPay merchants within
300 metres, with location updates filtered by 150 metres of movement. It does
not use the map-discovery fallback. Location-notification preferences, quiet
hours, muted merchants, and daily limits remain enforced by NotificationGate.
The screen warns when the location-notification category is muted.

Monitoring can continue while the app is backgrounded. Force-stopping the app
or rebooting the phone stops the location stream; reopening the signed-in app
restores the saved choice. This change does not add boot-time or headless
monitoring. No guarantee of an alert is made when the directory has no matching
merchant or the provider is unavailable.

Provider lookups time out after 15 seconds. An API response with
`unavailable: true` is treated as an outage rather than a successful empty list.
Late responses after stop or stream termination cannot mark monitoring active.
Failed or suppressed notifications do not consume the monitor's cooldown.

## Validation and device build

Regression coverage includes saved On/Off choices across controller recreation,
account isolation, startup/resume restoration, permission recovery, stream
errors and termination, provider failures, late responses after stop, merchant
matching, notification delivery failure/retry, and repeat-alert cooldown.

An isolated source snapshot was used for the Android build to exclude unrelated
work in progress in the shared checkout. It contains the committed baseline plus
the background-alert files, provider wiring, and application-root restoration.

- Date: 2026-10-18.
- Flavor/package: `prod` / `app.pandapay.pandapay`.
- Endpoints: existing production API, auth, and legal endpoints.
- Flutter build number: `18047`; ARM64 Android version code: `20047`.
- APK SHA-256: `96789047D79B5F10423939345E5A3664626F0976D26CDCC0357911E2A1DC2E3E`.
- Signing certificate SHA-256: `3dda2588c1eb6c14f19dddf3b0af1a6c798bb5c0f81a72b1878d7c39431c1042`.
- This is a debug-signed connected-device test build, not a distributable release.

All 48 isolated geofence, startup-widget, and assistant-action tests passed.
Analysis of the isolated build source reported no errors or warnings, with
one existing informational lint in unrelated provider code.

The Motorola edge 50 fusion (`ZA222MS4SF`) was updated from `20046` to `20047`
using `adb install -r`, preserving app data. Device checks confirmed:

- Enabling alerts starts the Android foreground location service.
- Pressing Home leaves that service running.
- A force-stop ends it; reopening the app automatically restores it before
  visiting the Nearby merchants screen. The saved switch remains On.
- Removing background-location permission preserves On but displays the
  paused/permission-required state with Settings and Retry actions. No
  foreground monitoring service remains active in that state.
- Restoring the original permission and resuming the app restarts monitoring.
- Saving Off and force-stopping/reopening keeps monitoring Off.

The original permission grant was restored and the preference was left Off,
matching its state before testing. Screenshots are stored locally in
`artifacts/ui-verification/background-alerts/` (ignored by Git). An actual visit
to a published merchant and a device reboot were not performed; matching and
notification delivery/retry were covered with deterministic regression tests.
