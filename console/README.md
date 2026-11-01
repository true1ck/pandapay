# PandaPay internal console

Flutter console for catalogue/data operations. Web builds can use the opt-in same-origin browser cookie/CSRF gateway; native clients use configured auth/product origins. Administrative privileges and allowed operations remain server-enforced.

The requested PC-only admin setup is specified in the [implementation/deployment plan](../docs/admin-console-implementation-plan-2026-10-30.md). Its [source candidate verification](../docs/admin-console-source-verification-2026-10-30.md) and [operator runbook](../deploy/admin/RUNBOOK.md) record the implemented private flow and open release gates. The public-host Nginx example and old development launcher do not satisfy that setup.

See the [current source architecture](../docs/security-current-architecture-2026-10-25.md), [deployment guide](../deploy/DEPLOY.md), [environment/provider wiring](lib/app/providers.dart), and [security progress](../docs/security-implementation-progress-2026-10-22.md). `adminimplementation_plan.md` is a historical/product design reference, not proof of a running deployment.

Use `flutter analyze --no-fatal-infos` and `flutter test` for local checks. Browser bundles and their cookie gateway must be released together after the required acceptance checks. Do not store server keys in the Flutter bundle.

Text fonts are bundled under `assets/fonts/` with their license and declared in `pubspec.yaml`. Keep the local Roboto family and fallback when changing the theme: the private proxy's CSP blocks external font downloads, so relying on Flutter's network-hosted default can leave the console text invisible even when the release build passes.

The login screen includes desktop and compact Flutter widget previews (`adminLoginPreview`) and uses the existing PandaPay brand mark. Its account, email-code and pending-enrollment states share a single primary action. Run `flutter test test/features/auth/login_screen_test.dart` for input, responsive layout and enrollment-state checks.

Manual enrollment accepts the full 43-character base64url grant issued by the provisioning CLI, separately from the email code. With opt-in approved browser enrollment, the server handles the grant internally and the field is absent: verified pending users click Register security key. The gateway still checks a completed, current-version operator approval through the bounded database routine. The private sign-in cookie lasts two minutes from the email-code request; the one-use internal grant lasts ten minutes. Rejections, invalid sign-in, browser passkey cancellation/unavailability and server verification failures have separate safe messages. No raw gateway response or credential is displayed, and enrollment completes only after an explicit `enrolled: true` response.

After verified email proof, the gateway includes `enrolledSlots` for pending administrators so the UI can distinguish initial registration, backup registration and pending activation. It also returns the slots after successful registration. These progress states never create an admin session. Registration success stays on a confirmation with the remaining setup instructions. See the [local access guide](../docs/admin-local-access-guide.md) for the Desktop helpers.
