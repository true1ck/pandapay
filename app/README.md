# PandaPay mobile app

Flutter mobile client with local SQLite/offline queues, account-scoped data and separate product/auth API clients. The shared rules package is `packages/pandapay_domain`.

New and changed screens follow the [mobile UI guidelines](../docs/design/mobile-ui-guidelines.md) and the existing Bamboo Ink tokens/components under `lib/app/design/`.

Start with the [current source architecture](../docs/security-current-architecture-2026-10-25.md), [root local development commands](../README.md#local-development), [environment flags](lib/app/env.dart) and [security progress](../docs/security-implementation-progress-2026-10-22.md). Release builds require explicit verified backend origins; never embed server credentials.

The existing token store uses OS secure storage. Whole-database/receipt encryption and account recovery are separate work: see the [recovery flow](../docs/security-recovery-flow-2026-10-25.md). Storage conversion components are under local test and are not enabled in normal startup. No additional user recovery password is required.

Local verification uses `flutter analyze --no-fatal-infos` and `flutter test`; [the isolated native fixture](tool/run_security_storage_fixture.py) uses its own Android package and synthetic data. It does not establish signed-device production acceptance. Use an isolated test package before touching an account-bearing installation.
