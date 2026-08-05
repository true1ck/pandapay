# PandaPay

*Tells you which of your cards to use for every transaction, at the moment you're about to pay.*

An India-focused credit/debit card advisor app: scan any UPI QR code, get an instant card recommendation, and track caps, milestones, and fee-waiver progress automatically — all self-hosted, solo-buildable, and free to run.

## Documents

- [`product-plan.md`](./product-plan.md) — full product plan: feature set, technical architecture, data acquisition, costs, roadmap, legal/compliance, and risks for the v1.0 production release.
- [`ui-spec.md`](./ui-spec.md) — complete UI specification: every screen (66 + system surfaces), with purpose, data sources, feature logic, actions, edge cases, and states. Includes a feature-to-screen traceability matrix.
- [`admin-console-plan.md`](./admin-console-plan.md) — plan for the internal-only companion app: scrapes/collects bank card-reward data, detects policy changes from multiple sources, and surfaces the crowdsourced merchant/location/acceptance data for review and publishing.

Read together, these documents are intended to be sufficient to implement the entire system: the user-facing app, its UI, and the internal data-operations console behind it.

## Implementation plans

- [`Userappimplementation_plan.md`](./Userappimplementation_plan.md) — detailed build plan for the **Flutter** user app: 14 workstreams broken into tasks and sub-engineering tasks, each with deliverables, dependencies, and definitions of done.
- [`adminimplementation_plan.md`](./adminimplementation_plan.md) — detailed build plan for the **Flutter Web** internal console, including the Python/Playwright scraper worker and the unified policy-change alert pipeline.
- [`database.sql`](./database.sql) — the single shared PostgreSQL schema backing **both** applications, with the database workstream plan, migration split, RLS policies, propagation RPCs, the anonymization audit, and the on-device SQLite mirror.

Both applications are built in Flutter and share one Dart domain package (`pandapay_domain`) and one database, so the console validates card data with the exact code the app ranks with.
