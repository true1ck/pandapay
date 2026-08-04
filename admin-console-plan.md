# PandaPay Console — Data Scraper & Admin Application

Companion to [`product-plan.md`](./product-plan.md) and [`ui-spec.md`](./ui-spec.md). This is the **third application** in the system: an internal, single-operator tool that (1) scrapes/collects bank card-reward data and (2) surfaces the crowdsourced data the PandaPay user app collects (locations, merchants, acceptance, effective rates) so it can be reviewed, corrected, and published.

**This app is never public-facing.** It's your operating console, not a user product.

---

## 1. Why This Needs Its Own Application

The main plan already establishes the principle: **AI-assisted extraction, human-verified, never auto-published.** That principle doesn't change here — this app is what makes it *operable* at scale instead of you manually running scripts and editing JSON files.

Two jobs, one console:
1. **Card data acquisition** — get reward T&C data out of bank websites and into the PandaPay database, with a human gate before anything goes live.
2. **Crowdsource oversight** — see what the user app's location/merchant/acceptance data collection is actually producing, and manage its quality.

Without this, data maintenance (the plan's stated permanent operating cost) has no interface — you'd be hand-editing rows in a database console, which doesn't scale past a handful of cards.

---

## 2. Legal Posture — Read Before Building

This matters more here than anywhere else in the plan, because scraping is the core function.

- **Scope scraping to public, unauthenticated pages only** — a bank's published reward T&C page, offer page, or fee schedule. Never anything behind a login.
- **Respect `robots.txt` and rate-limit aggressively.** No bank should ever notice load from this.
- **Cache aggressively; re-check infrequently.** T&C pages change rarely — daily or weekly crawls are more than enough, not continuous polling.
- **This is meaningfully different from the Google Maps scraping we explicitly rejected in the main plan.** That was live, proprietary, ToS-prohibited automated access to a paid product. This is periodic, low-frequency, rate-limited reading of banks' own published informational pages — closer to how a price-comparison site checks public listing pages. Still, **check each bank's site terms before scraping it**, and if a bank's ToS explicitly prohibits automated access, drop it from the scraper and fall back to manual/AI-assisted extraction from that page instead (same as the main plan already does for every card).
- **Nothing scraped auto-publishes.** Every scrape result lands in a review queue. You are always the gate between "scraped" and "live in the app."

---

## 3. Architecture

Reuses the same self-hosted infrastructure already provisioned for PandaPay — **no new recurring cost.**

| Layer | Choice | Notes |
|---|---|---|
| Admin web app | React/Next.js (or a low-code tool like Appsmith/Retool, self-hosted) | Internal only; speed of build matters more than polish here. |
| Scraper engine | Python + Playwright (headless browser) or Scrapy for simpler static pages | Runs as a scheduled job (cron / systemd timer) on the same VPS. |
| Database | **Same Postgres/Supabase instance as PandaPay** | One source of truth; the admin app reads/writes the same `cards`, `merchants`, `acceptance`, `effective_rates` tables the main app uses. |
| Diffing | Store a content hash per scraped page; only queue for review when the hash changes | Avoids re-reviewing unchanged pages every crawl. |
| Auth | Single admin account (or a small allowlist), same backend auth system | No public signup path exists for this app. |
| Hosting | Same VPS as the PandaPay backend | Check RAM headroom — Playwright is heavier than the main backend; a small bump in VPS tier may be needed once the scraper is added (~₹200–500/month extra, still trivial). |

---

## 4. Features — Card Data Acquisition Side

### 4.1 Bank Source Registry
- List of tracked banks/issuers, each with the specific URLs to crawl (reward T&C, offers page, fee schedule).
- Per-source: last crawled, last changed, crawl frequency, enabled/disabled, and a `robots.txt`/ToS compliance note.

### 4.2 Scrape Job Runner
- Scheduled crawls (default weekly; configurable per source).
- Manual "run now" trigger for a specific source.
- Job log: success/failure, duration, pages fetched, errors (dead links, layout changes breaking the scraper).

### 4.3 Change Detection & Diff Review ⭐ core loop
- Content hash comparison flags exactly what changed on a page since last crawl.
- Side-by-side diff view: old text vs. new text, highlighted.
- **AI-assisted structured extraction** on the new content — pulls proposed field changes (rate, cap, category) into a structured form for you to approve, matching the existing plan's "AI extracts, you verify" workflow.
- Actions: **Approve & publish** (writes to the live `cards` table) · **Reject** (log why, useful if the scraper misread the page) · **Needs manual re-check** (flag for you to read the source directly).

### 4.4 Card Catalogue Manager
- Full CRUD on the card database — the same data structure the PandaPay app reads.
- Manual add/edit for cards not worth scraping (small issuers, cards added from user requests).
- Data-freshness field per card, matching what the user app displays (§5.11 of the main plan).

### 4.5 New Card Request Queue
- Surfaces every "my card isn't listed" submission (A8/C8 in the UI spec) with count and frequency, so you prioritize by actual demand.
- One-click "start scraping this issuer" if not already tracked.

### 4.6 User-Reported Data Errors Queue
- Surfaces every "report wrong data" submission (C7 in the UI spec) — what the app showed, what the user says it should be, optional source link/screenshot.
- Side-by-side against the current live value, with an approve-correction action.

---

## 5. Features — Crowdsourced Data Visibility Side

This is the part you specifically asked for: **the location and merchant data collected from users must be visible and manageable here**, not just silently accumulating.

### 5.1 Merchant Map View ⭐
- Interactive map (using the same bundled OSM base layer, no paid tiles) showing every crowdsourced merchant pin.
- Each pin: merchant name, category (MCC), VPA, confidence score, number of confirming users, last confirmed date.
- Filter by category, confidence level, region, date added.
- **This is the direct answer to "location and other things should be visible"** — you can see exactly what the app has learned, where.

### 5.2 Merchant Record Detail
- Full history of a single VPA: every contribution that touched it, conflicting submissions if any, current published category/name, confidence score breakdown.
- Manual override — you can correct or merge a record directly.

### 5.3 Conflict Resolution Queue
- Records where independent user submissions disagree (e.g., two different categories reported for the same VPA).
- Matches the main plan's rule: majority wins, weighted toward recency — this screen is where you review cases the automatic rule doesn't confidently resolve.

### 5.4 Card Acceptance Map ⭐
- Same map view, filtered to acceptance data — which merchants have confirmed Amex/Diners acceptance issues, RuPay UPI acceptance, etc.
- This dataset (flagged in the main plan as something *nobody else has*) is otherwise invisible without this screen.

### 5.5 Effective Rate Monitor
- Per card+category, the statistically inferred real-world reward rate (from statement-reconciled transactions) plotted against the officially published rate.
- **Flags divergence automatically** — if users are empirically earning a different rate than the T&C states, that's an early signal of a silent bank policy change, surfaced here before it becomes a wave of user complaints.

### 5.6 Data Quality Dashboard
- Aggregate health metrics: total merchants mapped, % with confidence ≥ threshold, review queue backlog sizes (scrape diffs, error reports, new card requests, conflicts), contribution volume trend.
- This is your single "is the data getting better or worse" view.

### 5.7 Anonymization Audit ⭐ non-negotiable
- A dedicated check confirming no record in any of the above views carries user identity, exact coordinates, amounts, or timestamps beyond what the main plan's privacy architecture permits (§6.2).
- Run this as an automated test on every deploy, not just a one-time check — this is the screen that proves the privacy promise made to users is actually true in the data, not just in the docs.

---

## 6. What This App Does *Not* Do

- **No user-facing features.** No signup, no public access, no mobile app.
- **No auto-publishing of scraped or crowdsourced data.** Every path to "live in PandaPay" passes through a human approval action in this console.
- **No scraping of authenticated, paywalled, or ToS-prohibited sources.** Where that's the only path to data, fall back to manual/AI-assisted extraction, same as the main plan already does.

---

## 7. Roadmap

Build after PandaPay's core loop (main plan Phases 1–4) is working — this console exists to *maintain* data, so there needs to be data and a review workload for it to manage first.

| Phase | Scope | Effort |
|---|---|---|
| 1 | Card catalogue manager (CRUD) + new-card-request queue + error-report queue — the minimum needed to operate the initial 40–50 card dataset | 1–2 wks |
| 2 | Scraper engine (2–3 pilot banks) + change detection + diff review + AI-assisted extraction on diffs | 2–3 wks |
| 3 | Merchant map view + record detail + conflict resolution queue | 2 wks |
| 4 | Acceptance map + effective rate monitor + data quality dashboard | 1–2 wks |
| 5 | Expand scraper coverage to remaining banks; anonymization audit automation | ongoing |

**Total to a usable v1 of this console: ~6–9 weeks**, run in parallel with or just after the main app's Phase 5+ (once real crowdsourced data exists to look at).

---

## 8. Cost

**₹0 additional recurring cost**, beyond a possible small VPS tier bump (~₹200–500/month) if Playwright's memory footprint requires it. No new services, no paid APIs — same backend, same database, same hosting account.
