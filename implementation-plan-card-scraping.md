# PandaPay - Implementation Plan: Card Data Collection

**Goal:** build a reliable backend pipeline that collects and refreshes actual credit card product data from free public sources, then turns that into structured catalogue records the app can use.

**Scope:** card products only:
- reward rates
- caps and exclusions
- welcome benefits
- fee/waiver rules
- lounge / travel / forex / fuel benefits
- issuer, network, card type, and source freshness

**Out of scope for this plan:**
- transaction parsing
- SMS/email discovery of user-owned cards
- partner attribution / clicks
- non-card merchant data

---

## 1. Current State

The repo already has the right storage shape for card data:
- `card_products` is the canonical product table
- `reward_rules`, `cap_rules`, `milestone_rules`, `fee_waiver_rules`, `card_benefits`, `forex_rules`, `fuel_surcharge_rules`, `billing_cycle_rules`, and `redemption_options` hold structured fields
- `sources`, `source_pages`, `scrape_runs`, `page_snapshots`, and `extraction_proposals` already exist for crawling and review
- `card_source_drafts` now provides a staging queue for provenance-backed structured imports

What is missing today:
- no full structured card ingestion pipeline
- no browser fallback for JS-heavy issuer pages
- no PDF brochure ingestion path
- no canonical source-ranking policy for which scraped page wins when fields conflict
- no automatic promotion from snapshot text to structured card records

Relevant code paths:
- `api/src/index.js`
- `api/src/card_discovery.js`
- `scraper/pandapay_scraper/run.py`
- `scraper/pandapay_scraper/fetcher.py`
- `scraper/pandapay_scraper/extractor.py`
- `scraper/pandapay_scraper/llm_extraction.py`
- `scraper/CANDIDATE_SOURCES.md`
- `db/supabase/migrations/0003_card_catalogue.sql`
- `db/supabase/migrations/0006_ingest.sql`
- `db/supabase/migrations/0029_crowdsource_ingest.sql`

---

## 2. What The Research Shows

Free public issuer sources are usually good enough if we treat them as a layered set:

1. **Primary:** issuer product page
2. **Secondary:** issuer brochure / membership kit / MITC / key fact statement
3. **Tertiary:** issuer rewards FAQ / product T&C / offers page
4. **Fallback:** archived snapshot or structured evidence from the same issuer domain

Examples from current official pages:
- HDFC product pages expose reward rates, caps, and exclusions directly in the page text.
- SBI Card membership e-kits expose digital brochures plus T&C documents.
- ICICI and RBL pages expose reward programs, annual fee, exclusions, and common T&C on public pages.
- Yes Bank, Kotak, and IDFC FIRST also expose usable product text on public pages.

The key implication:
- we do not need a paid aggregator if the goal is issuer-grade coverage
- but we do need a crawler that can handle HTML, PDF, and JS-rendered pages

There is also a better upstream than scraping everything ourselves from day one:
- **CardAdvisor publishes a free Indian credit-card dataset** with JSON, CSV, change history, point valuations, and provenance audit pages.
- It is explicitly **CC BY 4.0**, cites source-verified issuer data, and is already shaped as structured card facts.
- For India-only coverage, this is the strongest free structured source I found.

Useful open-source/community complements:
- `secure-credit-card-rewards-optimiser` has a large community-maintained `cards.config` with Indian cards, reward strings, fees, and heuristics.
- `ccreward-web` covers India and Singapore and already models MCC-based best-card decisioning.

These are not replacements for issuer verification, but they are strong seed/backfill sources and useful cross-checks.

---

## 3. Recommended Source Strategy

### 3.1 Source hierarchy

For every card, store multiple source pages and rank them by trust:

1. `structured_dataset` or `structured_third_party`
   - CardAdvisor JSON/CSV is the best starting point
   - use as seed/backfill and as a canonical structured baseline

2. `product_page`
   - highest priority
   - best for headline rewards, fee, welcome benefit, eligibility, network, UPI-linkability

3. `brochure_pdf`
   - highest completeness for fine print
   - best for eligibility, exclusions, fee rules, cap notes, and detailed terms

4. `mitc_or_tnc`
   - best for exact fee and exclusion language
   - often the authoritative source for tricky reward exclusions and cap rules

5. `faq_or_rewards_page`
   - good for redemption rules and helper explanations
   - lower priority than brochure/T&C if there is a conflict

6. `press_release_or_offer_page`
   - good for launch dates and promotional benefits
   - should never override the core product page for permanent fields unless it is the only current source

### 3.2 Source policy

Use scraped data only when:
- the source is on the issuer domain or another clearly attributable official domain
- the field is current or explicitly dated
- the page can be fetched reliably
- the source has a recorded review status in `sources.tos_reviewed`

For CardAdvisor and other third-party sources:
- allow them as data sources
- do not treat them as final authority for value-sensitive fields unless corroborated
- always preserve `source_url` and `last_verified`

For anything that changes user-visible economics:
- fee
- reward rate
- cap
- milestone
- exclusion
- forex mark-up

require at least two independent issuer sources before publishing, unless one source is the issuer brochure or MITC and the second source is a contemporaneous product page.

If you want faster coverage with direct DB writes, a practical compromise is:
- write CardAdvisor-backed rows directly into a `staging`/`draft` state
- auto-promote only when the same values are corroborated by an issuer source or a second strong third-party source
- otherwise keep the row flagged as `needs_verification`

---

## 4. Backend Gaps To Fix

### 4.1 Add a structured ingestion layer

Right now the scraper captures page snapshots and diff signals, but not structured card fields.

Add a pipeline that:
- ingests CardAdvisor JSON/CSV on a schedule
- ingests selected third-party pages
- fetches source content
- extracts text from HTML and PDFs
- detects candidate fields
- normalizes them into a structured draft object
- writes a review artifact, not a live catalogue row

Suggested review artifact:
- `card_source_drafts`
  - `source_id`
  - `source_page_id`
  - `source_url`
  - `source_class`
  - `source_license`
  - `page_role`
  - `source_priority`
  - `card_key`
  - `card_name`
  - `issuer_name`
  - `normalized_fields` JSON
  - `field_confidence` JSON
  - `evidence` JSON
  - `raw_text` extracted from the source
  - `provenance` JSON
  - `status` (`draft`, `ready`, `rejected`, `promoted`)
  - `created_at`, `updated_at`

This is better than writing directly to `card_products` because it gives operators a single review surface before publication.

### 4.2 Add browser fallback

`scraper/pandapay_scraper/fetcher.py` currently has a stub for JS rendering.

Implement:
- static HTTP fetch first
- browser fallback only when:
  - static fetch returns thin content
  - critical selectors are missing
  - the source is known to be JS-rendered

Use browser rendering sparingly because it is slower and more expensive.

### 4.3 Add PDF ingestion

Many issuer terms live in PDFs or kit downloads.

Add a PDF fetch/extract path that:
- downloads the PDF
- extracts text with a PDF parser first
- falls back to OCR only if the text layer is missing or poor
- stores extracted text and page metadata in the snapshot history

### 4.4 Add field-level extraction

Current extraction is page-level diff detection, not card-field extraction.

Create field extractors for:
- `annual_fee_inr`
- `joining_fee_inr`
- `base_reward_rate`
- `base_reward_unit`
- `point_value_inr`
- `is_upi_linkable`
- `fee_waiver_rules`
- `forex_rules`
- `fuel_surcharge_rules`
- `milestone_rules`
- `card_benefits`

Use deterministic parsing first, then LLM only for ambiguous cases.

### 4.5 Add source-specific extraction templates

Banks do not format card pages consistently.

Recommended approach:
- maintain per-issuer extraction templates
- prefer CSS selector hints for known page regions
- fall back to text search/regex
- keep an issuer-specific glossary for reward words:
  - cashpoints
  - reward points
  - miles
  - cashback
  - bonus points

---

## 5. Data Model Changes

### 5.1 Extend `sources`

Add optional columns for source quality and extraction strategy:
- `source_priority`
- `content_type` (`html`, `pdf`, `mixed`)
- `extraction_mode` (`static`, `browser`, `pdf`, `hybrid`)
- `last_good_snapshot_at`
- `coverage_notes`
- `source_class` (`issuer_official`, `third_party_structured`, `third_party_page`, `community_open_source`)
- `license_note`

### 5.2 Extend `source_pages`

Add page role types for card data:
- `product_page`
- `brochure_pdf`
- `mitc`
- `faq`
- `offers`
- `press_release`

Also add:
- `field_targets` JSON
  - tells the extractor which fields this page is expected to support

### 5.3 Add a structured draft table

Recommended new table:
- `card_source_drafts`

Purpose:
- store extracted candidate values from scraped sources
- keep evidence attached
- support human review before promotion

### 5.4 Add source provenance to catalogue fields

For published catalogue rows, store:
- `source_url`
- `verified_at`
- `verified_by`
- a compact provenance JSON plus source-link JSON for the latest source set that justified the field set

The current schema extension follows that approach:
- `card_products` keeps a compact provenance blob and a `source_links` JSON object for canonical/brochure/T&C/FAQ URLs
- child rule tables keep their own source URL, verification timestamp, and provenance blob
- the draft queue keeps raw payloads and evidence so the live tables do not need one-off columns for every upstream variation

This makes later audits much easier.

---

## 6. Extraction Rules

### 6.1 Trust ordering

When sources conflict, prefer:
1. current brochure or MITC
2. current product page
3. current FAQ
4. archived previous source with explicit date

### 6.2 Confidence rules

Only auto-draft when:
- a value is explicit in text
- the page context clearly belongs to that card
- the field is not guessed from generic bank-wide text

Examples:
- `5% on groceries` is valid
- `bank-wide reward program` is not enough
- `annual fee waived on spends of 50,000` is valid
- `reward benefits worth 3,400 annually` should be treated as marketing unless the component values are also present

### 6.3 Conflict rules

If a card page and brochure disagree:
- mark as conflict
- do not overwrite the live card
- require operator review

If a newer page is a pure campaign or offer page:
- do not use it to replace permanent product economics unless the issuer clearly indicates a product revision

---

## 7. Operational Plan

### Phase 1 - Make crawling complete
- finish browser fallback
- add PDF extraction
- add source page role coverage
- record extracted text for every supported format

### Phase 2 - Add structured drafts
- build field extraction per source type
- emit `card_source_drafts`
- expose draft review in the console

### Phase 3 - Promote to catalogue
- add typed review actions for draft approval
- on approval, update `card_products` and child rule tables
- write provenance and change log rows

### Phase 4 - Expand coverage
- add all known issuer cards from the current source registry
- add missing variants / cobrands
- prioritize the banks with the most active product refreshes

### Phase 5 - Add drift detection
- compare current snapshots with prior snapshots
- alert on reward/rule changes
- keep a manual review queue for uncertain diffs

---

## 8. Best-Fit Backend Architecture

Recommended architecture:

1. **Source registry**
   - manual admin-approved list of issuer pages and documents

2. **Fetcher**
   - static HTML fetch
   - browser fallback
   - PDF fetch

3. **Normalizer**
   - text extraction
   - boilerplate stripping
   - PDF text extraction
   - content hashing

4. **Extractor**
   - deterministic field parsers first
   - LLM only as a reviewer aid for ambiguous diffs

5. **Draft store**
   - evidence-backed proposed structured values

6. **Human review**
   - approve / reject / edit drafts

7. **Catalogue writer**
   - typed updates to `card_products` and child tables

This is the safest pattern because it separates:
- crawling
- extraction
- review
- publication

---

## 9. Why This Is Better Than A Pure Scrape-And-Write Approach

Because card data is noisy:
- product pages are marketing-heavy
- brochures are more precise but harder to parse
- terms pages carry exceptions
- older pages can lag behind current economics

A direct write from HTML into live catalogue tables would be too risky.

The review-gated draft model gives you:
- provenance
- auditability
- conflict handling
- rollback safety
- less chance of publishing bad rewards data

---

## 10. Practical Recommendation

If the objective is “collect all card data from free sources”:

1. seed the catalogue from CardAdvisor’s open dataset
2. normalize it into your schema and store provenance per row
3. use issuer pages, brochures, MITC, and FAQs to verify and refresh high-value fields
4. crawl third-party Indian card pages as corroboration and coverage backfill
5. add browser and PDF support for issuer sources that are JS-heavy or brochure-driven
6. write to DB in a draft/staging state first, then promote when freshness/corroboration rules pass
7. use archived history and diffing to catch changes over time

I would **not** recommend relying on third-party comparison sites as the only source of truth. But I **would** recommend using them as a major part of the ingestion graph in India, because CardAdvisor and similar catalogues already encode the hard part: card normalization, reward rows, and change tracking.

---

## 11. Open Questions

Before implementing, confirm:
- Is the target market India-only, or should this support international cards too?
- Do you want only official issuer sources, or should we allow third-party comparison sites as backup evidence?
- Should scraped data stay review-only until an admin approves it, or do you want any fields to auto-publish when confidence is high?
