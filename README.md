# PandaPay

*Tells you which of your cards to use for every transaction, at the moment you're about to pay.*

An India-focused credit/debit card advisor app: scan any UPI QR code, get an instant card recommendation, and track caps, milestones, and fee-waiver progress automatically — all self-hosted, solo-buildable, and free to run.

## Documents

- [`product-plan.md`](./product-plan.md) — full product plan: feature set, technical architecture, data acquisition, costs, roadmap, legal/compliance, and risks for the v1.0 production release.
- [`ui-spec.md`](./ui-spec.md) — complete UI specification: every screen (66 + system surfaces), with purpose, data sources, feature logic, actions, edge cases, and states. Includes a feature-to-screen traceability matrix.
- [`admin-console-plan.md`](./admin-console-plan.md) — plan for the internal-only companion app: scrapes/collects bank card-reward data, detects policy changes from multiple sources, and surfaces the crowdsourced merchant/location/acceptance data for review and publishing.
- [`docs/sms-feature-architecture.md`](./docs/sms-feature-architecture.md) — verified SMS architecture and operations guide: live capture, backup import, card discovery, server parsing, downstream features, privacy boundaries, production readiness, and known defects.

Read together, these documents are intended to be sufficient to implement the entire system: the user-facing app, its UI, and the internal data-operations console behind it.

## Local development

The host-native development stack uses the local `pandapay` and
`pandapay_auth` PostgreSQL databases. Start it with:

```bash
scripts/start_local_backend.sh
scripts/build_app.sh dev apk --debug
```

The dev APK talks to this computer through `10.0.2.2` when running in the
Android emulator. The local OTP fixture accepts `test@example.com` or
`newuser4@example.com` with code `1234`; it is enabled only by the local
development backend.

Production builds require explicit hosted endpoints and never use the local
backend:

```bash
PANDAPAY_API_BASE_URL=https://api.pandapath.site \
PANDAPAY_AUTH_BASE_URL=https://auth.pandapath.site \
scripts/build_app.sh prod appbundle --release
```

For Android phone updates, use the split-APK checklist in
[`docs/android-release-build-guide.md`](./docs/android-release-build-guide.md).
It covers version codes, ABI selection, signing-key compatibility, and runtime
SMS/notification permissions.

## Implementation plans

- [`docs/security-completion-checklist-2026-10-23.md`](./docs/security-completion-checklist-2026-10-23.md) — verified implementation status and remaining P0–P7/release gates.
- [`docs/security-secrets-inventory-2026-10-23.md`](./docs/security-secrets-inventory-2026-10-23.md) — protected key, credential and backup locations, recovery procedure and current storage limits; contains no secret values.
- [`docs/security-implementation-plan-2026-10-22.md`](./docs/security-implementation-plan-2026-10-22.md) — reviewed security rollout for the current free hosting, preserving existing behavior and full-data portability across PostgreSQL hosts; includes encryption, both-database recovery, migration and rollback gates. [`Six Luna work packages`](./docs/security-luna-handoff-2026-10-22.md) provide the implementation handoff.
- [`Userappimplementation_plan.md`](./Userappimplementation_plan.md) — detailed build plan for the **Flutter** user app: 14 workstreams broken into tasks and sub-engineering tasks, each with deliverables, dependencies, and definitions of done.
- [`adminimplementation_plan.md`](./adminimplementation_plan.md) — detailed build plan for the **Flutter Web** internal console, including the Python/Playwright scraper worker and the unified policy-change alert pipeline.
- [`database.sql`](./database.sql) — historical consolidated schema and database workstream reference. Current deployment uses separate product and auth databases; use the maintained migration directories and security portability plan for upgrades and rehosting.

Both applications are built in Flutter and share one Dart domain package (`pandapay_domain`), so the console validates card data with the exact code the app ranks with. The product API and separate auth service use their respective PostgreSQL databases; the mobile app also keeps local SQLite data.
