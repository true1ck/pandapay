# Android permission crash fix

The Android crash buffer identified `IllegalStateException: Reply already submitted` in the vendored telephony SMS query callback. The native handler now keeps pending permission calls with their original arguments and reply, consumes only its own outstanding callback, and guards each reply against repeated completion. Null service/signal error branches stop before submitting success.

The native APK was rebuilt and installed, rather than relying on hot reload. `verification.json` records five fresh system grants (SMS, notifications, approximate foreground location, camera and microphone) completing under process ID 12850 with no crash or restart. It also verifies the native patch is present in the built DEX and the installed APK hash matches that build.

The second permission page additionally has one combined action that asks for the four optional permissions sequentially. Already-granted permissions are skipped, each row updates to Enabled only after its actual OS grant, and blocked permissions keep an explicit Settings action. Continue for now remains available. SMS stays separate. A status revision prevents an older lifecycle refresh overwriting a newer grant.

Only dev emulator permission-history state was reset for fresh-dialog verification; login credentials and financial data were preserved. No Google Play upload was performed.

## Final combined-action verification

`sequential-verification.json` describes the final installed build. One tap on Allow permissions opened notifications, approximate foreground location, camera and microphone dialogs in order, with zero individual row taps. Every grant stayed in the same Android process; all four rows ended at Enabled, Continue to my cards returned, and no Flutter/native runtime errors were observed. The installed APK hash matches the final build.

`combined-permissions-before.png` / `combined-permissions-enabled.png` show the actual before and after states. `sequential-permissions.mp4` records the automatic sequence. Static analysis and the native dev APK build passed.
