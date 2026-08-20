# AD-3 candidate scrape sources (research only — nothing enabled)

This is a shortlist of candidate official bank pages for future scraping, produced
for the product owner to review. **Nothing here is legal clearance.** Every row
inserted into the `sources` table has `tos_reviewed = false` and `is_enabled = false`,
and the DB's `enabled_requires_tos_review` CHECK constraint would reject any attempt
to enable a row before a human has actually read that site's terms of use and flipped
`tos_reviewed = true`.

`robots.txt` status is recorded below because it's a useful operational signal (it
tells us whether the site's own crawler policy would object to an automated fetch of
this path), but it is explicitly **not** a substitute for reading the site's terms of
service. Robots.txt governs crawler/indexing behavior; it says nothing about a site's
actual legal terms on scraping or reuse of its financial-product data.

| Issuer | Candidate URL | What we'd scrape | robots.txt status |
|---|---|---|---|
| HDFC Bank | https://www.hdfcbank.com/personal/pay/cards/credit-cards | Credit card listing/features page | Unclear — Cloudflare returned HTTP 403 "Access denied" for an automated fetch of `/robots.txt` itself; could not determine allow/disallow. |
| ICICI Bank | https://www.icicibank.com/personal-banking/cards/credit-card | Credit card listing/features page | Allowed — `robots.txt` has scoped `Disallow` rules (`/nri-banking/...`, `/lite/*`, `/campaigns/`, file-type globs, etc.); this path is not covered. |
| SBI Card | https://www.sbicard.com/en/personal/credit-cards.page | Credit card listing page | Allowed — `Allow: /*`; only `Disallow: /en/webform/*`, which doesn't match. |
| Axis Bank | https://www.axisbank.com/personal/cards/credit-card | Credit card listing/features page | Allowed — `Allow: /` for `User-agent: *`; only `/Sitefinity/` is disallowed. |
| Kotak Mahindra Bank | https://www.kotak.com/en/personal-banking/cards/credit-cards.html | Credit card listing/features page | Allowed — `Allow: /` for `User-agent: *`. |
| Yes Bank | https://www.yesbank.in/personal-banking/yes-premia/credit-cards | Credit card listing/features page | Unclear — `robots.txt` fetch failed to return a response (connection/timeout) at research time; could not determine allow/disallow. |
| IDFC FIRST Bank | https://www.idfcfirstbank.com/credit-card | Credit card listing/features page | Allowed — `User-agent: *` / `Disallow:` (empty) = allow all. |
| IndusInd Bank | https://www.indusind.com/in/en/personal/cards/credit-card.html | Credit card listing/features page | Allowed — `Allow: /` for `User-agent: *`; specific `Disallow` entries are unrelated (search results, error404, archived account pages, a handful of old PDFs). |
| AU Small Finance Bank | https://www.aubank.in/personal/cards/credit-cards | Credit card listing/features page | **Disallowed** — `robots.txt` is `User-agent: * / Disallow: /` (entire site blocked for crawlers). Strong signal against scraping; even if ToS review later permitted it, this would need explicit discussion given the blanket disallow. |
| Standard Chartered | https://www.sc.com/in/credit-cards/ | Credit card listing/features page | Allowed — `robots.txt` (at `sc.com/in`) disallows specific paths (`_document/`, `employee-banking`, `interact/`, `edm/`, etc.); this path isn't among them. |
| RBL Bank | https://www.rblbank.com/personal-banking/cards/credit-cards | Credit card listing/features page | Allowed — standard Drupal `robots.txt`, no blanket `Disallow` for `User-agent: *`; the credit-cards path isn't excluded in the visible rules. |
| American Express | https://www.americanexpress.com/en-in/credit-cards/ | Credit card listing/features page (India) | Allowed — `robots.txt` disallows `/*/apply/`, `/*/logout`, `/us/rwd/`; none match the India credit-cards listing path. |

## Additional candidate sources — domains only, robots.txt NOT checked

The 12 rows above had their `robots.txt` checked in an earlier session. This
batch adds the remaining issuers from `CREDIT_CARD_ISSUERS_INDIA.md` with
their real official domains — that part is stable public fact (bank
company domains), independent of any web tool. **What it deliberately does
not include is a robots.txt check or any claim about page content**,
because a later session found this environment's live web-fetch tools
sitting behind a sandboxed/mocked network (official domains silently
redirecting to look-alike hosts, inconsistent content on repeat fetches —
see `CARDS_BY_ISSUER_INDIA.md`'s reliability warning). Repeating that check
here would just produce fabricated-looking robots.txt findings, which is
worse than leaving the column blank. Confidence on each domain itself is
noted; the exact credit-card-listing path is a best guess and may need
correcting once someone reaches the real site.

None of these are `sources` table rows yet. Before inserting: (1) confirm
the domain and page path resolve to what's expected, from a trusted
network — not this session's fetch tools, (2) check robots.txt for real,
(3) run the same human ToS-review process as the original 12.

| Issuer | Candidate URL (best guess, unverified) | Domain confidence |
|---|---|---|
| Bank of Baroda (BOBCARD) | https://www.bobcard.co.in/credit-cards | High — bobcard.co.in is BoB's known card-issuing subsidiary domain |
| Punjab National Bank | https://www.pnbindia.in/credit-card.html | High |
| Canara Bank | https://canarabank.com/user_pages/Credit-Cards | High |
| Union Bank of India | https://www.unionbankofindia.co.in/english/credit-card.aspx | High |
| Bank of India | https://bankofindia.co.in/credit-card | Medium — domain confident, exact path a guess |
| Indian Bank | https://www.indianbank.in/personal-banking/credit-card/ | Medium |
| Central Bank of India | https://www.centralbankofindia.co.in/en/credit-card | Medium |
| Indian Overseas Bank | https://www.iob.in/Credit_Card | Medium |
| UCO Bank | https://www.ucobank.com/credit-card | High |
| Punjab & Sind Bank | https://www.punjabandsindbank.co.in/en/credit-card/ | Medium |
| Federal Bank | https://www.federalbank.co.in/credit-cards | High |
| South Indian Bank | https://www.southindianbank.com/content/credit-cards/70/108 | Medium — domain confident, exact path a guess |
| IDBI Bank | https://www.idbibank.in/credit-cards.aspx | High |
| Bandhan Bank | https://www.bandhanbank.com/personal/cards/credit-card | High |
| CSB Bank | https://www.csb.co.in/credit-card | Medium |
| DCB Bank | https://www.dcbbank.com/personal/cards/credit-card | High |
| Tamilnad Mercantile Bank | https://www.tmb.in/credit-card | Medium |
| Karnataka Bank | https://karnatakabank.com/personal/cards/credit-card | High |
| City Union Bank | https://www.cityunionbank.com/personal-credit-card | Medium |
| Equitas Small Finance Bank | https://www.equitasbank.com/credit-card | High |
| Ujjivan Small Finance Bank | https://www.ujjivansfb.in/personal-banking/cards/credit-card | High |
| HSBC India | https://www.hsbc.co.in/credit-cards/ | High |
| DBS Bank India | https://www.dbs.com/in/treasures/cards/credit-cards | Medium — DBS India's site structure has changed repeatedly; verify |
| OneCard (FPL Technologies) | https://www.getonecard.app | High |
| Slice | https://sliceit.com | High |
| Bajaj Finserv | https://www.bajajfinserv.in/cards | Medium — co-brand program winding down, may not be worth pursuing as a source |
| LazyPay (PayU) | https://www.lazypay.in | High |

Not listed as sources: **Deutsche Bank** (sold its India credit card book
to IndusInd Bank — no longer an active issuer) and **Citibank** (fully
migrated to Axis Bank as of July 2024) — for both, use the existing Axis
Bank / IndusInd Bank rows above instead of adding a dead-issuer source.

## Next step (for the product owner, not this agent)

For each row above that isn't AU Small Finance Bank: read that issuer's actual terms
of use / website terms (not just robots.txt) and decide, one source at a time, whether
scraping is permitted. Only then set `sources.tos_reviewed = true` for that specific
row — and only after that can `is_enabled` be set to true (enforced by the
`enabled_requires_tos_review` CHECK constraint). AU Small Finance Bank's blanket
`Disallow: /` is a strong enough signal that it probably shouldn't be pursued at all
without separate legal sign-off, independent of the ToS question.

Use `db/scripts/review_source.py` to record that decision once you've made it — it
doesn't decide anything for you (it requires `--confirm-tos-read` and a `--note`
explaining what you read and concluded), it just turns the flip into an attributed,
audited action instead of a hand-edit:

```
export DATABASE_URL=postgresql://app_user:...@host:5432/pandapay   # app_user, not postgres/scraper_role
python db/scripts/review_source.py list
python db/scripts/review_source.py review \
    --source "ICICI Bank" --admin-email you@pandapay.example \
    --tos-url https://www.icicibank.com/terms-and-conditions \
    --note "Read site ToS 2026-08-12: ..." \
    --confirm-tos-read --enable
```

All 12 rows already exist in the local `sources` table (`kind = 'bank_official'`),
each with `tos_reviewed = false`, `is_enabled = false`. No page content was fetched or
downloaded from any of these sites — only `robots.txt` was checked.
