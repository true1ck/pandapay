# PandaPay Console — Detailed Implementation Plan (Flutter Web, Internal Only)

**Companion to:** [`admin-console-plan.md`](./admin-console-plan.md) · [`product-plan.md`](./product-plan.md) · [`database.sql`](./database.sql) · [`Userappimplementation_plan.md`](./Userappimplementation_plan.md)

**What this is:** the internal, single-operator back-office application that (1) builds and maintains the card-reward dataset the recommendation engine depends on, (2) detects policy changes from four independent signals and propagates approved corrections to every user automatically, and (3) makes the crowdsourced merchant/location/acceptance data visible and correctable.

**This is never public-facing.** No signup, no public route, no user-visible feature. `admin-console-plan.md` §7.

---

## 0. Stack Decision — Flutter Web (deviation from `admin-console-plan.md` §3)

The source document lists React/Next.js (or Appsmith/Retool) for the console UI. **This plan uses Flutter Web instead**, per the instruction to build in Flutter.

**Why it holds up:**
- One language, one toolchain, one CI across both applications. For a solo operator this is the dominant consideration — context-switching cost is the real budget.
- **Shared domain code.** `core/money`, the `Money` type, `Confidence`, period math, the card rule model, and the dedupe/cap arithmetic move into a shared `packages/pandapay_domain` Dart package consumed by *both* apps. The console then validates card rules using **the exact same code the engine ranks with** — a class of "console said 5%, app computed 4%" bug simply cannot occur.
- Internal tool, single operator, desktop Chrome only: Flutter Web's weak points (SEO, first-paint size, deep mobile-browser support) are all irrelevant here.

**Where it costs something, and the mitigation:**
- **Map rendering.** No mature Flutter Web equivalent of MapLibre GL. → Use `flutter_map` (raster/vector tiles, OSM base layer, no paid tiles) with marker clustering; if pin volume outgrows it, embed MapLibre GL JS in an `HtmlElementView` behind a `MapView` interface so the swap is one class.
- **Rich text diffing.** → Implement the diff view in Dart with the `diff_match_patch` package; render as styled `TextSpan`s. No JS dependency.
- **Data tables.** → `DataTable2` / custom virtualized list; the review queues are hundreds of rows, not millions.

**Unchanged from the source plan:** the **scraper engine stays Python + Playwright**, running as a scheduled job on the VPS. It is a backend worker with no UI, and Playwright has no Dart equivalent worth the risk. The console only ever reads its output tables.

---

## 1. Architecture

```
pandapay/
├── packages/
│   └── pandapay_domain/           # ⭐ SHARED Dart package (app + console)
│       ├── money/  confidence/  clock/
│       ├── card_rules/            # reward/cap/milestone/fee/forex model
│       ├── engine/                # the ranking engine — console uses it to
│       └── dedupe/                #   preview the impact of a data change
├── app/                           # Flutter mobile (Userappimplementation_plan.md)
├── console/                       # Flutter Web (this document)
│   ├── lib/
│   │   ├── app/                   # router (go_router), theme, DI
│   │   ├── data/                  # Supabase repositories, typed writers
│   │   ├── features/
│   │   │   ├── catalogue/         # AD-3
│   │   │   ├── sources/           # AD-4
│   │   │   ├── alerts/            # AD-5 ⭐ the core loop
│   │   │   ├── queues/            # AD-6
│   │   │   ├── crowdsource/       # AD-7
│   │   │   └── dashboard/         # AD-8
│   │   └── widgets/               # DiffView, EvidencePanel, MapView, QueueTable
└── scraper/                       # Python + Playwright worker (AD-4)
    ├── runner.py  fetchers/  extractors/  robots.py
```

**Data access:** the console talks to the **same Postgres/Supabase instance** as the app (`database.sql`). It authenticates as an `admin_users` row; every table it touches is gated by the `pandapay.is_admin()` RLS policies in migration 0011. There is no service-role key in the browser bundle — all privileged writes go through `security definer` RPCs (`pandapay.approve_policy_alert`, etc.).

**Hosting:** static build served from the same VPS behind Cloudflare, on a separate hostname, **IP-allowlisted or Cloudflare Access-gated**. Defence in depth on top of RLS — an internal tool should not be reachable from the open internet at all.

---

## 2. Workstream Map

| WS | Name | admin-console-plan phase | Effort | Blocked by |
|---|---|---|---|---|
| **AD-0** | Foundation, auth, shared domain package | — | 1 wk | DB-7 |
| **AD-1** | Card catalogue manager (CRUD) | 1 | 1.5 wk | AD-0, DB-2 |
| **AD-2** | Request + error-report queues | 1 | 0.5 wk | AD-1 |
| **AD-3** | Scraper engine (pilot sources) | 2 | 2 wk | AD-0 |
| **AD-4** | Change detection + diff review + AI extraction | 2 | 1.5 wk | AD-3 |
| **AD-5** | ⭐ Unified policy change alert queue + propagation | 5 | 2.5 wk | AD-1, AD-4 |
| **AD-6** | Merchant map, record detail, conflict queue | 3 | 2 wk | AD-0, DB-6 |
| **AD-7** | Acceptance map + effective rate monitor | 4 | 1.5 wk | AD-6, UA-5.4 |
| **AD-8** | Data quality dashboard | 4 | 0.5 wk | AD-5, AD-6 |
| **AD-9** | Anonymization audit automation | 5 | 0.5 wk | AD-6 |
| **AD-10** | Ops hardening, expand coverage | 5/6 | ongoing | all |

**Total to usable v1: ~9–12 weeks**, matching `admin-console-plan.md` §8.

**Sequencing constraint:** build after the app's Phases 1–4. This console exists to *maintain* data — there must be data and a review workload for it to manage. **Exception: AD-1 is needed early**, because UA-1.1 (the 40–50 card dataset) is on the app's critical path and hand-editing SQL for 50 cards × 30 fields is where that task goes to die.

---

# AD-0 · Foundation  `1 wk`

### AD-0.1 Shared domain package
- **AD-0.1.1** Extract `Money`, `Confidence`, `Clock`, the card-rule model, and the dedupe hash from the app into `packages/pandapay_domain`. Both apps depend on it by path.
- **AD-0.1.2** Move `domain/engine/` into the shared package. **The console must be able to run the real ranking engine** — that is what makes AD-5.3 (impact preview) trustworthy rather than decorative.
- **AD-0.1.3** Shared test-vector files consumed by app tests, console tests, and the pgTAP suite.
- **DoD:** a change to cap-blending arithmetic breaks both apps' tests simultaneously. That coupling is the point.

### AD-0.2 Console scaffolding
- **AD-0.2.1** Flutter Web project, `console` flavor, dev/prod Supabase targets, CanvasKit renderer (better table/text fidelity on desktop).
- **AD-0.2.2** `go_router` with a **route guard that redirects any non-`admin_users` session to a dead end**. No public route exists.
- **AD-0.2.3** Dense desktop theme — data-tool ergonomics: compact rows, keyboard-first, no mobile-style padding.
- **AD-0.2.4** Shell: left nav (Catalogue · Alerts · Queues · Sources · Merchants · Acceptance · Rates · Dashboard), global search, backlog badges on every queue.

### AD-0.3 Auth & audit
- **AD-0.3.1** Supabase email+password login against `admin_users`; **no signup path is compiled into the build**.
- **AD-0.3.2** Role handling: `owner` / `operator` / `reviewer` / `readonly`. `readonly` cannot reach any approve action — enforced in the repository layer, not just the UI.
- **AD-0.3.3** Cloudflare Access / IP allowlist in front of the host.
- **AD-0.3.4** **Every mutating action writes `admin_audit_log`** via a repository wrapper. A write path that bypasses the wrapper fails review.
- **DoD:** a non-admin authenticated user gets nothing but a dead end; every approve/reject/edit in a smoke run leaves an audit row.

---

# AD-1 · Card Catalogue Manager  `1.5 wk` → `admin-console-plan` §5.4

> The core deliverable. Everything else exists to keep this data correct.

### AD-1.1 Catalogue browse & edit
- **AD-1.1.1** Card list: issuer, network, status, `data_version`, `verified_at`, **staleness colouring at 180 days** (feeds the app's freshness display, product-plan §5.11).
- **AD-1.1.2** Card editor with a tab per rule family — Rewards · Caps · Milestones · Fees & Waivers · Benefits · Forex & Fuel · Cycle · Redemption — mirroring `database.sql` §0003 exactly.
- **AD-1.1.3** **Typed writers**, not raw JSON editing. Every field has a validator; a cap without a period, or a reward rule without a unit, cannot be saved.
- **AD-1.1.4** Draft → In review → Published state machine. **Publishing requires `verified_at`** (the DB CHECK enforces it; the UI must explain it rather than surface a constraint error).
- **AD-1.1.5** Version history per card from `card_catalogue_changes` — what changed, when, who approved, which alert drove it.

### AD-1.2 Validation & impact preview ⭐
- **AD-1.2.1** Structural validation on save: required §10 fields present (caps, milestone thresholds, fee-waiver spend, lounge quotas, forex markup, fuel caps). *Collect once per card, not five times.*
- **AD-1.2.2** **Impact preview** — run the shared engine over a fixture user portfolio before and after the edit, and show which recommendations flip. This is how an operator sees that a cap edit silently changes advice for a whole category before publishing it.
- **AD-1.2.3** Diff-before-save confirmation showing old → new for every touched field.

### AD-1.3 Bulk import/export
- **AD-1.3.1** YAML import matching `tools/card_import.dart` (UA-1.1.2) — the 40–50 card initial load runs through here.
- **AD-1.3.2** Export to YAML for review outside the tool; round-trip must be lossless.
- **AD-1.3.3** Dry-run mode reporting what would change without writing.
- **DoD:** the full initial catalogue loads, validates, and publishes from YAML; a deliberately malformed card is rejected with a field-level message.

---

# AD-2 · Request & Error Queues  `0.5 wk` → §5.5, §5.6

- **AD-2.1** New Card Request queue (A8/C8) — grouped by issuer+product with **request counts so priority follows actual demand**, not intuition. One-click "start scraping this issuer" creates the `sources` row pre-filled.
- **AD-2.2** User-Reported Data Errors queue (C7) — shown vs claimed value **side by side against the current live value**, source link, attachment. Approve-correction writes through the AD-5 publish path, never directly.
- **AD-2.3** Both queues emit a `policy_alert_evidence` row with signal `user_report` — a user report is the fourth signal into the unified queue (§5.6), not a separate workflow.
- **DoD:** approving a C7 correction produces a `card_catalogue_changes` row, a `data_version` bump, and an audit entry — verified end to end.

---

# AD-3 · Scraper Engine  `2 wk` → §5.1, §5.2 · Python + Playwright

### AD-3.1 Legal gate — build this before the first fetch (§2)
- **AD-3.1.1** `robots.py`: fetch and honour `robots.txt` per host; a disallowed path is **never** fetched. Result cached to `sources.robots_allows` with a timestamp.
- **AD-3.1.2** ToS review workflow: `sources.tos_reviewed` must be true before `is_enabled` can be set — **the DB CHECK constraint already blocks it**, so the console cannot be the weak link. If a bank's ToS prohibits automated access, drop it from the scraper and fall back to manual/AI-assisted extraction for that page.
- **AD-3.1.3** Aggressive rate limiting: ≥5s between requests per host, ≤1 concurrent request per host, weekly default crawl. **No bank should ever notice load from this.**
- **AD-3.1.4** Honest, identifiable User-Agent with a contact URL. Scope: **public, unauthenticated pages only** — never anything behind a login.

### AD-3.2 Fetch & extract
- **AD-3.2.1** Static fetcher (`httpx` + `selectolax`) tried first; Playwright only when the page requires JS. Cheaper, and lighter on the VPS.
- **AD-3.2.2** Content extraction to normalized text using `source_pages.selector_hint`, with boilerplate stripping so nav/footer churn doesn't produce false diffs.
- **AD-3.2.3** `content_hash` → skip unchanged pages (`skipped_unchanged`). **This is what stops you re-reviewing the same page weekly.**
- **AD-3.2.4** Snapshot persistence to `page_snapshots`; retain last N per page for diffing.
- **AD-3.2.5** Job orchestration → `scrape_runs`; per-source scheduling; manual "run now"; failure alerting to your phone after 3 consecutive failures on a page (a layout change breaking an extractor is a silent data-staleness bug).

### AD-3.3 Two source types (§4.3, §5.1)
- **AD-3.3.1** `bank_official` — reward T&C, fee schedule, offers. Most authoritative, **slowest**: banks often change behaviour weeks before the page.
- **AD-3.3.2** `news_review` — card-review/finance-news pages that cover reward-program changes. Same pipeline, different `source_kind` and a higher crawl frequency. Weakest single signal; valuable as **corroboration**, and often fastest.
- **AD-3.3.3** Pilot set: 2–3 banks + 2–3 news sources. Prove the pipeline before expanding.

---

# AD-4 · Change Detection, Diff Review, AI Extraction  `1.5 wk` → §5.3

- **AD-4.1** Diff computation between the last two snapshots; word-level highlighting; noise suppression for dates/counters that change on every load.
- **AD-4.2** **Side-by-side diff view** in Flutter Web — old vs new, highlighted, with the source URL and capture timestamps.
- **AD-4.3** **AI-assisted structured extraction** on changed content → `extraction_proposals` with `proposed_fields`, model confidence, and the **verbatim evidence excerpt**. Matches the plan's standing rule: *AI extracts, you verify.*
- **AD-4.4** Proposals render as a **pre-filled, editable form over the real card-rule model** — the operator corrects rather than retypes.
- **AD-4.5** ⭐ **A diff does not become its own review item.** It creates or reinforces a `policy_change_alerts` row keyed to (card, field), so a bank-page diff and a user-data divergence for the same field **merge into one alert** (§5.3). Building three parallel queues here would destroy the corroboration signal that makes AD-5 worth having.
- **DoD:** a simulated T&C edit on a pilot page produces exactly one alert with a readable diff and a correctly pre-filled proposal.

---

# AD-5 · ⭐ Unified Policy Change Alert Queue + Propagation  `2.5 wk` → §4

> **The core requirement driving this entire application.** When a bank quietly drops a cap from ₹3,000 to ₹2,000, we must catch it, verify it, and have the correction reach every user automatically.

### AD-5.1 Signal ingestion — four independent sources, one queue
- **AD-5.1.1** **Signal A — scrape diff** (from AD-4).
- **AD-5.1.2** **Signal B1 — empirical divergence** ⭐. `pandapay.detect_rate_divergence()` runs nightly over `effective_rate_summary`, built from statement-reconciled transactions (UA-5.4.5). Requires **N ≥ 3 independent devices** before surfacing, to avoid false alarms from one user's math error or a one-off promo. *This is the mechanism that catches a silent cap drop: real transaction data shows the reward flattening ₹1,000 earlier than our records predict — before any user complains.*
- **AD-5.1.3** **Signal B2 — email keyword hit.** The Cloudflare Worker that already parses forwarded bank mail (UA-5.2.2) runs an additional pattern pass for change-announcement language ("revised terms", "effective from", "important update to your rewards"). Matches enter the queue **verbatim**, never auto-parsed as fact — a human reads the actual notice.
  - **Privacy:** what lands in the queue is the *bank's own policy text*, with **no user identity attached** to the alert. The evidence row links the email for the operator only, and the email is purged on the normal 30-day schedule.
- **AD-5.1.4** **Signal C — news/review diff** (AD-3.3.2), routed identically.
- **AD-5.1.5** **Signal D — user report** (AD-2.3).
- **AD-5.1.6** Alert keying and merge: `(card_product_id, field_path)` while `state` is open. Second signal on an open alert **increments `signal_count`, raises `corroboration_score`, and appends evidence** — it does not create a duplicate.

### AD-5.2 Queue UI
- **AD-5.2.1** Queue ranked by `corroboration_score desc` — **alerts with multiple agreeing sources sort to the top**, because that agreement is itself the signal worth trusting.
- **AD-5.2.2** Alert detail: which source(s) fired, current value on file, proposed new value, and **the raw evidence for each signal** (diff text · email excerpt · news link · divergence statistics) so the operator makes the actual call on evidence, not on a summary.
- **AD-5.2.3** Actions: **Approve & publish** · **Reject** (log why — useful when a scraper misread a page) · **Needs more evidence** (park until further corroboration).
- **AD-5.2.4** Impact preview (AD-1.2.2) shown inline: *"approving this flips the recommendation for groceries on 3 of 8 fixture portfolios."*
- **AD-5.2.5** **Nothing auto-publishes.** Three sources agreeing makes a change highly likely to be real; it does not remove the human gate (§4.4, §7).

### AD-5.3 Propagation ⭐ (§4.5)
- **AD-5.3.1** Approval calls `pandapay.approve_policy_alert()` — a single transaction that writes the catalogue change, **bumps `data_version`**, records `card_catalogue_changes`, and writes the audit row. There is no other code path to publish.
- **AD-5.3.2** **One shared `cards` table, one copy of this data — not per-user, not per-device.** Devices pull only changed rows via `data_version > catalogue_version_seen`.
- **AD-5.3.3** **Urgent corrections**: `force_sync` sets the `force_catalogue_sync_after` remote-config key, so a cap drop that would otherwise cause a wrong recommendation *today* propagates immediately rather than on the next opportunistic sync.
- **AD-5.3.4** Optional user-visible changelog entry (H10) when the change alters advice, so users understand why a recommendation moved.
- **AD-5.3.5** ✅ **End-to-end acceptance test (run this as one scripted scenario, it is the whole point of the console):**
  1. Simulate a bank page changing a cap from ₹3,000 to ₹2,000.
  2. Scraper detects the diff → alert created with `scrape_diff` evidence.
  3. Seed divergent `effective_rate_samples` from 3 devices → same alert gains a second signal, `corroboration_score` rises, it sorts to the top.
  4. Operator reviews both evidence panels and approves.
  5. `data_version` bumps; `card_catalogue_changes` and `admin_audit_log` rows exist.
  6. A device with the old value syncs and shows ₹2,000 **with no app update and no user action**.
  7. The affected user's cap state and Home recommendation recompute correctly.
- **DoD:** that seven-step scenario passes in CI against a seeded database.

---

# AD-6 · Crowdsourced Data Visibility  `2 wk` → §6.1–§6.3

> The location and merchant data users produce must be **visible and manageable**, not silently accumulating.

### AD-6.1 Merchant map ⭐
- **AD-6.1.1** `MapView` abstraction over `flutter_map` with the **OSM base layer — no paid tiles**, ODbL attribution rendered on the map.
- **AD-6.1.2** Clustered pins from `merchant_locations` (geohash6-bucketed server-side; the browser never loads the full set).
- **AD-6.1.3** Pin detail: merchant name, category/MCC, VPA, confidence score, confirming-device count, last confirmed date.
- **AD-6.1.4** Filters: category · confidence level · region · date added · published/unpublished.
- **AD-6.1.5** The map renders **grid-snapped coordinates only** — the console is structurally incapable of displaying a precise location because none is stored (`database.sql` §0007 CHECK constraint).

### AD-6.2 Merchant record detail (§6.2)
- **AD-6.2.1** Full contribution history for a VPA: every contribution that touched it, conflicting submissions, current published values, **confidence score breakdown showing how it was computed**.
- **AD-6.2.2** Manual override / merge, setting `operator_locked` so automated recomputation cannot undo an operator decision.
- **AD-6.2.3** Unpublish action for a record found to be wrong or poisoned.

### AD-6.3 Conflict resolution queue (§6.3)
- **AD-6.3.1** `merchant_conflicts` list where independent submissions disagree.
- **AD-6.3.2** Competing values with counts and recency — the automatic rule is **majority wins, weighted toward recency**; this screen is only for the cases that rule does not confidently resolve.
- **AD-6.3.3** Resolution writes the value, locks the record, recomputes confidence, and audits.

### AD-6.4 Abuse & quality controls (product-plan §6.3)
- **AD-6.4.1** `abuse_signals` review: burst submissions, impossible geography, high conflict rate per device hash.
- **AD-6.4.2** Block a device hash from contributing; bulk-revert its contributions and recompute affected records.
- **AD-6.4.3** Quota configuration through `remote_config`. *A poisoned merchant database produces wrong financial advice at scale — this is a data-integrity control, not an anti-spam nicety.*

---

# AD-7 · Acceptance Map & Effective Rate Monitor  `1.5 wk` → §6.4, §6.5

- **AD-7.1** **Acceptance map** — the same map filtered to `acceptance_summary`: confirmed Amex/Diners acceptance problems, RuPay UPI acceptance, per network and rail. *Flagged in the product plan as a dataset nobody else has; without this screen it is invisible.*
- **AD-7.2** Acceptance record detail with report counts and confidence, and a publish gate mirroring the merchant gate.
- **AD-7.3** **Effective rate monitor** — per card+category, statistically inferred real-world rate plotted against the published rate, with sample count and distinct-device count always shown next to the number.
- **AD-7.4** **Cap-ceiling detection view** — observed reward ceiling vs published cap value. This is the exact ₹3,000 → ₹2,000 detector, made legible.
- **AD-7.5** Divergence rows link straight to their alert in AD-5; this is a monitor, **not a standalone dead-end view**.

---

# AD-8 · Data Quality Dashboard  `0.5 wk` → §6.6

- **AD-8.1** Single-query dashboard over `v_data_quality_dashboard`: merchants mapped, % above confidence threshold, all queue backlog depths (scrape diffs, error reports, card requests, conflicts, **policy-change alerts**), contribution volume trend.
- **AD-8.2** Catalogue health: published cards, cards stale >180 days, cards missing §10 fields, scrape failures in the last 7 days.
- **AD-8.3** Trend lines, not just current values — *"is the data getting better or worse"* is a derivative, and a single snapshot cannot answer it.
- **AD-8.4** Operator alerting when any backlog crosses a threshold, since there is no on-call team (product-plan §2.6).

---

# AD-9 · Anonymization Audit Automation  `0.5 wk` ⭐ non-negotiable → §6.7

- **AD-9.1** Console view over `anonymization_audit_runs`: latest result, findings, history, git SHA.
- **AD-9.2** **Wire `pandapay.run_anonymization_audit()` into CI as a deploy-blocking gate.** A failing audit fails the build. Not a one-time check.
- **AD-9.3** Extend the audit whenever a crowdsource table is added — a new table with no audit coverage should itself be a finding.
- **AD-9.4** Nightly cron run with alerting, so a data-level regression is caught even without a deploy.
- **DoD:** deliberately inserting a 6-decimal coordinate fails both the DB constraint and the audit, and blocks the build. *This is the check that proves the privacy promise is true in the data, not just in the docs.*

---

# AD-10 · Ops Hardening & Coverage Expansion  `ongoing` → §8 phase 6

- **AD-10.1** Expand scraper coverage from the pilot set to all tracked issuers, one at a time, each with its own ToS review.
- **AD-10.2** Extractor resilience: alert on repeated extraction failure for a page (layout change), with a "needs manual re-check" path rather than silent staleness.
- **AD-10.3** VPS capacity: monitor Playwright memory; **budget a tier bump of ~₹200–500/month** if needed (§9). Run the scraper niced and off-peak.
- **AD-10.4** Backup/restore drills recorded in `restore_drills` — an untested backup is not a backup.
- **AD-10.5** Console operational runbook: how to kill the recommendation engine, how to force a catalogue sync, how to roll back a bad publish (publish the inverse change — the catalogue is append-versioned, so there is no destructive undo to get wrong).

---

## 3. Security Posture

| Control | Implementation |
|---|---|
| Network | Cloudflare Access / IP allowlist in front of the console host |
| AuthN | Supabase auth against `admin_users`; **no signup path compiled in** |
| AuthZ | Postgres RLS via `pandapay.is_admin()`; roles enforced in the repository layer |
| Privileged writes | `security definer` RPCs only; **no service-role key in the browser bundle** |
| Audit | Every mutation writes `admin_audit_log` through a mandatory wrapper |
| Scraping | robots.txt honoured, ToS-gated by DB constraint, rate-limited, public pages only |
| Data exposure | Console can read crowdsourced data — which by construction contains no identity |
| Secrets | Scraper credentials and AI API keys live on the VPS, never in the console build |

---

## 4. Testing Strategy

| Layer | What | Gate |
|---|---|---|
| Unit (Dart) | Validators, diff rendering, confidence math, role checks | 85% |
| Shared | `pandapay_domain` engine — same suite as the app | 100% on engine |
| Unit (Python) | robots parsing, extractors per source, hash stability | 85% |
| Integration | AD-5.3.5 seven-step propagation scenario | **Blocking** |
| Integration | Publish path always writes change + version bump + audit | **Blocking** |
| DB (pgTAP) | Admin RLS isolation; non-admin sees nothing | **Blocking** |
| CI gate | `run_anonymization_audit()` returns passed = true | **Blocking** |
| Manual | Scrape a real bank page, review a real diff | Per source added |

---

## 5. Sequencing

```
        ── app Phases 1–4 complete ──►
AD-0 ── AD-1 ──────────────────────────►     (AD-1 pulled early for UA-1.1)
              AD-2 ──►
                     AD-3 ── AD-4 ─────►
                                  AD-5 ⭐ ─────────►
              AD-6 ──────────────────────►
                          AD-7 ──► AD-8 ──► AD-9 ──►
                                                    AD-10 ongoing
```

**Hard rule carried from `admin-console-plan.md` §7:** no path from scraped, user-signalled, or crowdsourced data to "live in PandaPay" exists without a human approval action in this console — **regardless of how many sources corroborate it**.
