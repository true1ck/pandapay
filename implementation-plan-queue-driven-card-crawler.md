# PandaPay - Implementation Plan: Queue-Driven Card Crawler

**Status: Implemented via migration 0038 and new python modules in `pandapay_scraper/`.**

**Goal:** turn the India card inventory into a queue of crawl jobs that fetch each card's source pages, extract structured facts, and write normalized drafts into the staging queue before any live publication.

**This plan is the missing execution layer behind the existing scraping work.**

The current repo already has:
- a broad card inventory in `scraper/CARDS_BY_ISSUER_INDIA.md` and `scraper/ALL_CARDS_LIST.md`
- a source registry in `sources` and `source_pages`
- a page snapshot / change-detection crawler in `scraper/pandapay_scraper/run.py`
- a structured import path that writes draft rows into `card_source_drafts`

What is not yet fully specified is the queue itself:
- how card targets are created from the inventory
- how source URLs are attached to each card
- how crawl jobs move from pending to fetched to extracted to drafted
- how drafts get promoted into the canonical catalogue

This plan fills that gap.

---

## 1. Scope

### In scope
- India card coverage only
- card-product facts, not user card data
- structured facts such as:
  - issuer
  - card name
  - network
  - annual fee
  - joining fee
  - reward rates
  - caps
  - fee waivers
  - milestone rules
  - forex markup
  - fuel surcharge rules
  - lounge / travel / benefit metadata
  - source freshness and provenance

### Out of scope
- PAN / CVV / expiry / PIN / last-4
- user-owned card ingestion
- merchant location data
- transaction parsing
- partner-click attribution

---

## 2. What the inventory files mean

### `scraper/CARDS_BY_ISSUER_INDIA.md`
- Source inventory by issuer
- Best used as a queue seed
- Not authoritative truth
- Good for discovering coverage gaps and aliases

### `scraper/ALL_CARDS_LIST.md`
- Broader target inventory
- Useful for variant coverage and long-tail cards
- Also not authoritative truth
- Useful for completeness checks and future crawl expansion

### How they should be used
- Treat both files as a **target registry**
- Do not treat them as live catalogue data
- Every listed card should eventually map to:
  - one canonical card target
  - one or more source URLs
  - one or more crawl jobs
  - one or more draft rows

---

## 3. Proposed queue model

### 3.1 Card target registry

Add a logical target layer for cards, separate from the live catalogue:

- `card_targets`
  - `id`
  - `issuer_name`
  - `card_name`
  - `card_key`
  - `aliases` JSON
  - `status` (`pending`, `mapped`, `crawlable`, `drafted`, `published`, `retired`)
  - `coverage_priority`
  - `notes`
  - `created_at`
  - `updated_at`

Purpose:
- represent the universe of cards to collect
- allow multiple source URLs to point at the same card target
- keep the target list independent from the live catalogue schema

### 3.2 Crawl job queue

Add a job table for work items:

- `card_crawl_jobs`
  - `id`
  - `card_target_id`
  - `source_id`
  - `source_page_id`
  - `job_type` (`discover`, `fetch`, `extract`, `normalize`, `promote`)
  - `priority`
  - `state` (`queued`, `running`, `succeeded`, `failed`, `skipped`)
  - `attempts`
  - `next_run_at`
  - `last_error`
  - `payload` JSON
  - `created_at`
  - `updated_at`

Purpose:
- make the crawler resumable
- allow retries and backoff
- allow multiple jobs per card
- keep crawl, extraction, and promotion separate

### 3.3 Draft queue

Reuse `card_source_drafts` as the normalized staging queue.

This table should hold:
- source identity
- source priority
- source class / license
- source URLs
- raw or extracted text
- normalized fields
- confidence
- evidence
- provenance

This is the queue item the reviewer sees.

---

## 4. Job flow

### 4.1 Seed

Input:
- `scraper/CARDS_BY_ISSUER_INDIA.md`
- `scraper/ALL_CARDS_LIST.md`
- `scraper/CANDIDATE_SOURCES.md`

Output:
- `card_targets`
- source mappings for each target
- initial `card_crawl_jobs`

Rules:
- one card can map to multiple source URLs
- source priority should prefer:
  1. issuer product page
  2. brochure / PDF
  3. MITC / T&C
  4. FAQ / offers page
  5. structured third-party dataset
- CardAdvisor and similar structured datasets seed coverage, but do not replace issuer verification

### 4.2 Discover

Given a card target:
- resolve candidate source URLs
- attach the card target to known issuer pages
- create crawl jobs for each source page

Discovery sources:
- manual registry rows in `sources` / `source_pages`
- structured third-party datasets
- issuer card listing pages
- brochure landing pages

### 4.3 Fetch

For each crawl job:
- static HTTP fetch first
- if the page is thin or JS-dependent, use browser fallback
- if the source is a PDF, extract text from the PDF first
- store raw content and hashes
- skip unchanged content when the page hash is stable

### 4.4 Extract

From fetched content:
- extract candidate card facts
- normalize them into a consistent structure
- attach evidence snippets
- compute field-level confidence

### 4.5 Normalize

Convert extracted facts into:
- `card_source_drafts`
- optionally a delta for live catalogue promotion later

Normalization should preserve:
- original source payload
- current normalized fields
- provenance
- source freshness

### 4.6 Review and promote

Promotion should be explicit, not automatic by default.

Promotion rule:
- move a draft to `ready` when the extractor has enough confidence and provenance
- move to `promoted` only when the field is verified or corroborated enough to publish
- write into live tables only through typed updates

---

## 5. Database shape

### 5.1 Keep the normalized live catalogue

Do not flatten every scraped field into a giant wide table.

Live tables already support the core shape:
- `card_products`
- `reward_rules`
- `cap_rules`
- `milestone_rules`
- `fee_waiver_rules`
- `card_benefits`
- `forex_rules`
- `fuel_surcharge_rules`
- `billing_cycle_rules`
- `redemption_options`

### 5.2 Add provenance, not arbitrary width

The schema should support:
- source URLs
- source class
- source license
- verification timestamp
- raw excerpt / evidence
- source priority
- provenance JSON

This is better than adding a new column for every possible scraper field.

### 5.3 Use JSON for long-tail evidence

Keep these flexible in JSON:
- excerpt lists
- upstream aliases
- source ranking notes
- structured third-party metadata
- crawl metadata
- promotion notes

Use normal columns for fields that drive ranking or filtering.

---

## 6. Extraction strategy

### 6.1 Deterministic first

Prefer:
- CSS selector hints
- regex
- structured HTML tables
- brochure text patterns

### 6.2 JS fallback second

Use browser rendering only when:
- the static page is too thin
- the page hides key content behind scripts
- the source is known to be JS-heavy

### 6.3 PDF ingestion

Use PDF parsing for:
- brochures
- membership kits
- MITC / T&C documents

### 6.4 LLM last

Use the LLM only when:
- the field is ambiguous
- deterministic parsing fails
- the result still needs a human review surface

---

## 7. Source-ranking policy

For a given card target, prefer:
1. issuer product page
2. issuer brochure / PDF
3. issuer MITC / T&C
4. issuer FAQ / rewards page
5. structured third-party dataset
6. other third-party corroboration

For financial fields:
- annual fee
- reward rate
- cap
- exclusion
- milestone
- forex markup

Require corroboration before promotion whenever possible.

---

## 8. Operational behavior

### 8.1 Scheduling
- Queue jobs are retried with backoff
- Newly published or newly changed pages get higher priority
- High-coverage issuers are processed first

### 8.2 Deduplication
- If the content hash is unchanged, do not create redundant drafts
- If the card key already exists for the same source, update the draft instead of duplicating it

### 8.3 Drift detection
- Compare current crawl output to the last published version
- Surface diffs into the review queue
- Avoid silent overwrites

---

## 9. Recommended implementation phases

### Phase 1
- create card target registry
- seed it from `CARDS_BY_ISSUER_INDIA.md` and `ALL_CARDS_LIST.md`
- create crawl job queue

### Phase 2
- map card targets to source URLs
- link sources to source pages
- generate fetch jobs

### Phase 3
- implement fetch/extract/normalize loop
- write normalized rows to `card_source_drafts`

### Phase 4
- implement promotion worker into `card_products` and child rule tables
- write provenance into live tables

### Phase 5
- add browser fallback
- add PDF ingestion
- add issuer-specific templates

### Phase 6
- add recurring refresh and drift handling
- add stale-data alerts

---

## 10. Definition of done

The queue-driven crawler is done when:
- every target card can be queued
- every queued job can fetch at least one source page
- structured fields are normalized into drafts
- drafts preserve source evidence and provenance
- approved drafts can promote into live tables
- stale or changed facts re-enter the queue cleanly
- the app can consume the updated live catalogue without manual patching

---

## 11. Why this is the right next step

This design is better than a simple scrape-and-write system because:
- the card inventory is large and changes often
- the same card can have multiple source types
- some pages are HTML, some are PDF, some are JS-heavy
- structured drafts let us inspect and correct data before publication
- the queue gives us retry, priority, and backoff control

The inventory lists are already enough to seed this system.
What they do not yet provide is the execution model.
This plan supplies that model.
