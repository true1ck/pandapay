# PandaPay internal console

Flutter console for catalogue/data operations. Web builds can use the opt-in same-origin browser cookie/CSRF gateway; native clients use configured auth/product origins. Administrative privileges and allowed operations remain server-enforced.

See the [current source architecture](../docs/security-current-architecture-2026-10-25.md), [deployment guide](../deploy/DEPLOY.md), [environment/provider wiring](lib/app/providers.dart), and [security progress](../docs/security-implementation-progress-2026-10-22.md). `adminimplementation_plan.md` is a historical/product design reference, not proof of a running deployment.

Use `flutter analyze --no-fatal-infos` and `flutter test` for local checks. Browser bundles and their cookie gateway must be released together after the required acceptance checks. Do not store server keys in the Flutter bundle.
