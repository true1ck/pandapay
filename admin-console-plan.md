# PandaPay Console — Internal Business Data Tool (Not a User Product)

Companion to [`product-plan.md`](./product-plan.md) and [`ui-spec.md`](./ui-spec.md). This is the **third application** in the system, and it exists for one reason: **we need to know exactly what every credit card offers — rewards, caps, milestones, fees, benefits — so that we, the business, can recommend the right card to PandaPay's users.** That data is the entire product's foundation, and this console is how we build and maintain it.

**This is purely internal. No user, ever, sees or touches this application.** There is no signup, no public URL, no feature in here that a PandaPay user interacts with. It is our own operating tool — the equivalent of a back-office system, not a second consumer app.

It does two things, both for our own benefit:
1. **Builds our card database** — pulls reward/fee/benefit data for every card from the banks themselves, so we have accurate, structured data to power recommendations. This is the core deliverable.
2. **Gives us visibility into what PandaPay's users have taught the system** — which shops are which category, which cards get accepted where. This is *our* internal record of that data, purely so we can review and correct it before it's used in recommendations — not something we expose to anyone.

---

## 1. Why This Needs Its Own Application

The main plan already establishes the principle: **AI-assisted extraction, human-verified, never auto-published.** That principle doesn't change here — this app is what makes it *operable* at scale instead of you manually running scripts and editing JSON files.

Without this, data maintenance (the plan's stated permanent operating cost) has no interface — you'd be hand-editing rows in a database console, which doesn't scale past a handful of cards. Everything below exists to serve that one goal: **an accurate, current, internally-owned dataset of what every card actually offers, that PandaPay's recommendation engine reads from.**

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
| Email keyword scanner | Runs inside the same Cloudflare Worker that already parses forwarded bank emails (product plan §5.2) | No new pipeline — it's an additional pattern-match pass on mail already being received. |
| Card data versioning | `data_version` integer column per card row; bumped on every approved change | Drives client-side sync — devices pull only changed cards, not the full catalogue, on every check. |

---

## 4. Policy Change Detection — Three Sources, One Alert Queue, Automatic Propagation

**This is the core requirement driving this entire application: when a bank quietly changes a card's terms — e.g. Kiwi's 5% cashback cap drops from ₹3,000/month to ₹2,000/month — we must catch it, verify it, and have the correction reach every PandaPay user automatically, without anyone re-entering data by hand.**

Three independent sources feed one queue, because no single source is reliable alone: banks change pages without announcing it, users don't always notice a cap shrank, and news coverage is inconsistent. Cross-checking sources against each other is what makes this trustworthy.

### 4.1 Source A — Bank's Own Pages (scraping)
Covered in full in §5 below. The most *authoritative* source when it fires, but the *slowest* — banks often change actual behaviour before updating the public T&C page, sometimes weeks later.

### 4.2 Source B — Signal From Our Own Users' Data ⭐ the one you specifically asked for
This is two distinct mechanisms, both fed by data PandaPay is already collecting for tracking purposes (main plan §5) — nothing new is asked of users.

**B1 — Empirical divergence (automatic, statistical, catches silent changes fastest):**
- Every statement/email/SMS a user's transactions reconcile against tells us the *real* reward they earned for a given spend, card, and category.
- The system continuously compares aggregated real-world outcomes against what our database currently says the card offers.
- **Example matching your scenario exactly:** if our database says "5% cashback, capped at ₹3,000/month" but users are empirically hitting a ₹2,000 ceiling across multiple independent accounts, that's a statistical anomaly — flagged automatically, before any single user complains or notices.
- Requires **N ≥ 3 independent users** showing the same divergence before surfacing, to avoid false alarms from one user's math error or a one-off promo.

**B2 — Keyword detection on forwarded bank emails (fast, catches explicit bank announcements):**
- Banks occasionally email cardholders directly about term changes ("Important update to your rewards program," "Revised terms effective March 1," etc.).
- Since users already forward bank emails to us for transaction tracking (main plan §5.2), the same pipeline scans subject lines and body text for change-announcement language.
- Matches get pulled into the review queue **verbatim**, with the source email content shown (never auto-parsed as fact — a human reads the actual notice).
- This is faster than waiting for empirical divergence to accumulate, when the bank actually bothers to tell people.

**Privacy note — this does not conflict with the plan's anonymization architecture:** the *content* of a change-announcement email is read by the parser for keyword matching (same as it already reads emails for amount/merchant), but what lands in the admin queue is the bank's own policy text, not anything about the user's spending. No user identity is attached to a queue entry.

### 4.3 Source C — News & Authoritative Finance Site Monitoring ⭐ new
- A second scraper source type (alongside bank pages), targeting card-review/finance-news sites that reliably cover reward-program changes (e.g. the kind of sites that already surfaced in our earlier market research — CardExpert, Paisabazaar, established finance news outlets).
- Same crawl/diff/AI-extraction pipeline as bank pages (§5.2–5.3), just a different source type in the registry — no new architecture needed, just more rows in the source list.
- Weakest single signal (third-party reporting can be wrong or stale) but valuable as **corroboration** for Sources A and B, and sometimes fastest to report a change publicly before a bank's own page updates.

### 4.4 Unified Policy Change Alert Queue ⭐ where it all comes together
One queue, not three separate ones — because the same underlying change often shows up in more than one source, and that agreement is itself the signal worth trusting.

- Each alert is keyed to a specific card + field (e.g. "Kiwi RuPay — cashback cap").
- **Confidence rises with corroboration:** a change flagged by empirical divergence *and* a matching bank-page diff is far more trustworthy than either alone, and is visually prioritized at the top.
- Each alert shows: which source(s) triggered it, the current value on file, the proposed new value, and the raw evidence (diff text / email excerpt / news article link) for you to make the actual call.
- **Actions:** Approve & publish · Reject (log why) · Needs more evidence (wait for further corroboration before deciding).
- **Nothing here auto-publishes** — same non-negotiable rule as the rest of this console. Three sources agreeing makes a change highly likely to be real; it doesn't remove the human gate.

### 4.5 Propagation — the correction reaches every user automatically ⭐
This is the second half of what you asked for: once *you* approve a change here, it must not require touching each user.

- Approving an alert writes directly to the single shared `cards` table in the same database PandaPay's app reads from — **there is only one copy of this data, ever; not per-user, not per-device.**
- Each card record carries a `data_version` field. Approval increments it.
- The mobile app's offline-first local SQLite cache (main plan §4.3) checks card `data_version` on every sync opportunity and pulls the corrected record automatically — no app update, no user action, no re-onboarding.
- For urgent corrections (e.g. a cap drop that would otherwise cause a wrong recommendation *today*), the same remote-config/kill-switch mechanism from the main plan (§9.2) can force an immediate sync rather than waiting for the next opportunistic one.
- **Net result:** one verified correction, made once in this console, is live for every PandaPay user without you ever touching an individual account.

---

## 5. Features — Card Data Acquisition Side

### 5.1 Source Registry ⭐ now covers two source types
- List of tracked sources, each typed as either **Bank (official)** or **News/Review Site**, with the specific URLs to crawl.
- Bank sources: reward T&C page, offers page, fee schedule.
- News/review sources: card-comparison and finance-news pages likely to cover reward-program changes (§4.3).
- Per-source: type, last crawled, last changed, crawl frequency, enabled/disabled, `robots.txt`/ToS compliance note.

### 5.2 Scrape Job Runner
- Scheduled crawls (default weekly; configurable per source — news sources may warrant more frequent checks than bank T&C pages, which change rarely).
- Manual "run now" trigger for a specific source.
- Job log: success/failure, duration, pages fetched, errors (dead links, layout changes breaking the scraper).

### 5.3 Change Detection & Diff Review ⭐ core loop
- Content hash comparison flags exactly what changed on a page since last crawl.
- Side-by-side diff view: old text vs. new text, highlighted.
- **AI-assisted structured extraction** on the new content — pulls proposed field changes (rate, cap, category) into a structured form for you to approve, matching the existing plan's "AI extracts, you verify" workflow.
- **Feeds directly into the Unified Policy Change Alert Queue (§4.4)** rather than being a dead-end review — a bank-page diff and a user-data divergence for the same card+field merge into one alert.
- Actions: **Approve & publish** (writes to the live `cards` table, bumps `data_version`) · **Reject** (log why) · **Needs manual re-check.**

### 5.4 Card Catalogue Manager
- Full CRUD on the card database — the same data structure the PandaPay app reads.
- Manual add/edit for cards not worth scraping (small issuers, cards added from user requests).
- Data-freshness field per card, matching what the user app displays (main plan §5.11).

### 5.5 New Card Request Queue
- Surfaces every "my card isn't listed" submission (A8/C8 in the UI spec) with count and frequency, so you prioritize by actual demand.
- One-click "start scraping this issuer" if not already tracked.

### 5.6 User-Reported Data Errors Queue
- Surfaces every "report wrong data" submission (C7 in the UI spec) — what the app showed, what the user says it should be, optional source link/screenshot.
- Side-by-side against the current live value, with an approve-correction action. **Also feeds §4.4** as a fourth, human-sourced signal alongside the three automated ones.

---

## 6. Features — Crowdsourced Data Visibility Side

This is the part you specifically asked for: **the location and merchant data collected from users must be visible and manageable here**, not just silently accumulating.

### 6.1 Merchant Map View ⭐
- Interactive map (using the same bundled OSM base layer, no paid tiles) showing every crowdsourced merchant pin.
- Each pin: merchant name, category (MCC), VPA, confidence score, number of confirming users, last confirmed date.
- Filter by category, confidence level, region, date added.
- **This is the direct answer to "location and other things should be visible"** — you can see exactly what the app has learned, where.

### 6.2 Merchant Record Detail
- Full history of a single VPA: every contribution that touched it, conflicting submissions if any, current published category/name, confidence score breakdown.
- Manual override — you can correct or merge a record directly.

### 6.3 Conflict Resolution Queue
- Records where independent user submissions disagree (e.g., two different categories reported for the same VPA).
- Matches the main plan's rule: majority wins, weighted toward recency — this screen is where you review cases the automatic rule doesn't confidently resolve.

### 6.4 Card Acceptance Map ⭐
- Same map view, filtered to acceptance data — which merchants have confirmed Amex/Diners acceptance issues, RuPay UPI acceptance, etc.
- This dataset (flagged in the main plan as something *nobody else has*) is otherwise invisible without this screen.

### 6.5 Effective Rate Monitor ⭐ now the engine behind §4.2's Source B1
- Per card+category, the statistically inferred real-world reward rate (from statement-reconciled transactions) plotted against the officially published rate.
- **Flags divergence automatically** — if users are empirically earning a different rate/cap than the T&C states, that's an early signal of a silent bank policy change. This is exactly the mechanism that would catch a cap silently dropping from ₹3,000 to ₹2,000: real transaction data would show the reward flattening out ₹1,000 earlier than our records predict.
- Divergence alerts here feed directly into the Unified Policy Change Alert Queue (§4.4), not just a standalone view.

### 6.6 Data Quality Dashboard
- Aggregate health metrics: total merchants mapped, % with confidence ≥ threshold, review queue backlog sizes (scrape diffs, error reports, new card requests, conflicts, policy-change alerts), contribution volume trend.
- This is your single "is the data getting better or worse" view.

### 6.7 Anonymization Audit ⭐ non-negotiable
- A dedicated check confirming no record in any of the above views carries user identity, exact coordinates, amounts, or timestamps beyond what the main plan's privacy architecture permits (§6.2 of the product plan).
- Run this as an automated test on every deploy, not just a one-time check — this is the screen that proves the privacy promise made to users is actually true in the data, not just in the docs.

---

## 7. What This App Does *Not* Do

- **No user-facing features.** No signup, no public access, no mobile app.
- **No auto-publishing of scraped, user-signal, or crowdsourced data.** Every path to "live in PandaPay" passes through a human approval action in this console — including every policy-change alert in §4.4, regardless of how many sources corroborate it.
- **No scraping of authenticated, paywalled, or ToS-prohibited sources.** Where that's the only path to data, fall back to manual/AI-assisted extraction, same as the main plan already does.

---

## 8. Roadmap

Build after PandaPay's core loop (main plan Phases 1–4) is working — this console exists to *maintain* data, so there needs to be data and a review workload for it to manage first.

| Phase | Scope | Effort |
|---|---|---|
| 1 | Card catalogue manager (CRUD) + new-card-request queue + error-report queue — the minimum needed to operate the initial 40–50 card dataset | 1–2 wks |
| 2 | Scraper engine (2–3 pilot banks + 2–3 news sources) + change detection + diff review + AI-assisted extraction on diffs | 3 wks |
| 3 | Merchant map view + record detail + conflict resolution queue | 2 wks |
| 4 | Acceptance map + effective rate monitor + data quality dashboard | 1–2 wks |
| 5 | **Email keyword change-detector (§4.2 B2) + Unified Policy Change Alert Queue (§4.4) + propagation/`data_version` sync (§4.5)** | 2–3 wks |
| 6 | Expand scraper coverage to remaining banks; anonymization audit automation | ongoing |

**Total to a usable v1 of this console: ~9–12 weeks**, run in parallel with or just after the main app's Phase 5+ (once real crowdsourced data and forwarded-email flow exist to detect changes from).

---

## 9. Cost

**₹0 additional recurring cost**, beyond a possible small VPS tier bump (~₹200–500/month) if Playwright's memory footprint requires it. No new services, no paid APIs — same backend, same database, same hosting account. The email keyword scanner reuses the same Cloudflare Email Routing pipeline already built for the main app (product plan §5.2) — no separate ingest infrastructure needed.
