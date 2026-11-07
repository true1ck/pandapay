# Wave 4 brief (7 Nov 2026): find every card the live catalogue is missing

This is a listing pass, not a drafting pass. Do not write overlay files, do not run `build.mjs`, do not touch any database or server,
do not commit, do not publish. Read `WAVE2_BRIEF.md` for the source rules, the no-circumvention rule, the untrusted-content rule and the browser-tab rule; they apply here.
Scratch space: `/private/tmp/claude-501/-Users-chandresh-kerkar--claude-spares-spare-Si0wXE/cc7f2487-f8c8-475c-9a2f-f9ee818cedea/scratchpad/wave4/<your-id>/` (create it). Use `python3 -I`.

## Input

`/private/tmp/claude-501/-Users-chandresh-kerkar--claude-spares-spare-Si0wXE/cc7f2487-f8c8-475c-9a2f-f9ee818cedea/scratchpad/sweep/live_by_issuer.json`
holds the cards already live in the app, grouped by `issuer_slug` (slug, name, network, annual fee). Some issuers appear under two slugs (for example `kotak` and
`kotak-mahindra-bank`, `sbi` and `state-bank-of-india`, `ujjivan-sfb` and `ujjivan-small-finance-bank`); read both. Slugs and names in it come from earlier automated runs and may be mis-cased or mislabeled.
Also read `WAVE2_BRIEF.md`'s list of cards already researched in this folder: every `drafts/*.json` in the repo folder is a card we already hold as a draft or published;
read `card_product.slug` and `card_product.name` from them and treat those cards as known.

## Task, per issuer you are assigned

1. Find the issuer's own current credit-card listing (the official site, plus the issuer's own co-brand pages and its schedule of charges / MITC / Key Fact Statement, which often name every variant).
   Record the URL and the date you read it.
2. List every credit card the issuer currently offers or services: name, product-page URL, and its status as the issuer states it:
   `sold` (apply now), `invite_only`, `existing_customers_only`, `closed_to_new_applications`, `unknown`. Include co-brand and partner cards the issuer itself lists. Include variants that are separate fee tiers or networks
   when the issuer sells them as separate products (for example a RuPay and a Visa version with different fees), and say they are variants.
3. Match each against the live catalogue and the known drafts. A match is the same product, not the same words.
4. Output the cards that are NOT in the live catalogue and NOT a known draft: these are the missing cards.
5. Also output live cards the issuer no longer lists (`stale_live`) with the evidence. Do not judge them; report.
6. Do not research fees or rewards. Give just enough to identify the product and its availability, with the issuer URL that shows it.

## Hand back

`wave4/<your-id>.json` in the repo folder, shaped as
`{"agent": "<id>", "issuers": [{"issuer": "<name>", "listing_url", "read_on": "2026-11-07", "offered_count": n, "matched_live": [slugs], "matched_drafts": [slugs],
  "missing": [{"name", "product_url", "status", "variant_of": "<name or null>", "partner": "<name or null>", "evidence": "<what the issuer page says>"}],
  "stale_live": [{"slug", "evidence"}], "notes": "<anything odd, such as a site that refused access>"}]}`
and a final message of at most 150 words: per issuer, offered / missing / stale counts, and any issuer you could not read and why.
