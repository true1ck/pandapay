# PandaPay agent operating rules

These rules apply to every agent/session working in this repository.

## Android-device verification

- These rules apply to both the Android emulator and the connected physical Android device.
- Backend selection is requirement-driven and must be recorded before building: emulator local testing uses API `http://10.0.2.2:4001` and auth `http://10.0.2.2:3210`; physical-device production testing uses API `https://api.pandapath.live` and auth `https://auth.pandapath.live`; emulator production testing may use those production URLs only when the requirement explicitly calls for production. Never mix a local-auth session with a hosted-backend build, or vice versa.
- For a physical device, do not assume the emulator address works on a phone. Confirm the production target and device connectivity before installing.
- Do not use a hosted-backend build for a local-auth session. A backend mismatch can invalidate the session and show onboarding even when app data is intact.
- Identify the exact Android serial and backend target before every install. Update the existing install with `adb install -r`. Do not uninstall the app, run `pm clear`, or clear app data on either target unless the user explicitly requests it.
- A build or successful install is not device verification. Only claim verification after the app is visibly signed in and the requested screen/flow has been exercised on that exact target.
- Before reporting a suspected reset, compare `firstInstallTime` and `lastUpdateTime`, and inspect device logs for clear/uninstall events.

## Authentication and handoff

- Do not automate password, OTP, or other authentication-dialog entry. Ask the user to take over for sign-in, then continue the non-authenticated test steps after the signed-in screen is visible.
- A static local test-auth fixture exists and has been used successfully by an earlier session. Its existence does not authorize copying credentials/OTP into messages or bypassing the current authentication handoff rule. If a dedicated permitted test-login tool is unavailable, the user must complete the authentication dialog manually.
- The repository CLI smoke test (`scripts/smoke_test.py --api http://localhost:4001 --auth http://localhost:3210`) may exercise the local test fixture and backend JWT flow. Treat that as backend authentication evidence only; it does not establish that the app UI is signed in, and do not inject its token into app storage to bypass UI authentication.

## Cross-session and worktree discipline

- Read this file and the durable memory context before acting. A different session's transcript is not a substitute for current device/repository checks.
- Preserve unrelated worktree edits and generated artifacts; never reset or broadly clean the repository to solve a scoped task.
- When reporting an Android-device result, include the target serial, installed version, backend target, sign-in state, and the exact UI flow that was verified.
