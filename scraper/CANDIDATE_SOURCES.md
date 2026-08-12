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
