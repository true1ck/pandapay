# Wave 5 research brief (15 Nov 2026): the 113 on-sale cards missing from the catalogue

Read `WAVE2_BRIEF.md` and `WAVE3_BRIEF.md` first (same folder). Everything in them still applies: paths, the helpers in
`lib.mjs`, `node build.mjs <slug>`, the hard rules, file ownership, `python3 -I`, branch `dev` only (the old briefs say
`latest-dev`; today's checkout is on `dev`), **no commits, no pushes, no database, no server, nothing published**.

Differences from the earlier waves:

- **Scratch space** (outside the repo): `/private/tmp/claude-501/-Users-chandresh_kerkar--claude-spares-spare-y8gZOE/6dce288f-23bd-44a9-9d01-1ec4078c6e69/scratchpad/wave5/<your-id>/`. Create it. One file per download.
- **Date**: today is 2026-11-15. `prov()` in `lib.mjs` hard-codes `fetched_on: '2026-11-07'`; pass `extra: { fetched_on: '2026-11-15' }` so the record carries the real date.
- **Your overlay file** is new and yours alone: `cards/w5<letter>.mjs` (for example `cards/w5a.mjs`), exporting `export const cards = { '<slug>': overlay, ... }` like the existing ones. Start from `cards/bandhan.mjs` or `cards/secured.mjs`: these cards have no earlier base record, so the overlay has to carry the full universal structure (the builder starts from a blank template).
- **Your assignment** is `wave5/assign-<letter>.json`: each row has the card name, the issuer's product page, the status evidence from the 7 Nov sweep, and `variant_of` / `partner` when known. `wave5/live_by_issuer.json` lists the cards already live, by `issuer_slug`.
- **Issuer slug**: reuse the exact `issuer_slug` of the live catalogue when the issuer is already in `live_by_issuer.json` (for example `icici-bank`, `hdfc`, `axis-bank`, `canara-bank`, `bobcard`, `kotak-mahindra-bank`, `idfc-first-bank`, `indusind`). For an issuer not there, use a short lower-case hyphen slug of the bank's own name (`union-bank-of-india`, `indian-bank`, `idbi-bank`, `dcb-bank`, `utkarsh-small-finance-bank`, `unity-small-finance-bank`, `esaf-small-finance-bank`, `south-indian-bank`, `city-union-bank`, `tamilnad-mercantile-bank`, `dhanlaxmi-bank`, `jammu-and-kashmir-bank`, `saraswat-co-operative-bank`). The importer creates a missing issuer from this slug.
- **Slugs**: issuer first, as before (`union-bank-of-india-nexteria`). Do not reuse a live slug; if the card is already live under another name, record it as `already_live` with the live slug.

## Order of work

1. Consumer cards first (personal, co-brand, travel, fuel, lifestyle, youth), then secured / fixed-deposit-backed personal cards.
2. Business, corporate, purchase, fleet, government, defence and other programme cards last. Draft one only if the issuer publishes numeric fees and a numeric earn rate for it; otherwise record it as `held` with the reason. Do not spend more than a short look on a business card that clearly publishes nothing.
3. A "variant" (`variant_of` set) is its own card only when the issuer gives it different fees or rewards; otherwise record it as `variant_of_<slug>` and add a note to the parent if the parent is yours.

## What "complete enough to publish" means

Exactly the four points in `WAVE3_BRIEF.md`: network known, fees and waiver stated, earn rule with every accelerator/exclusion/cap and its period, point value only if the issuer states it, nothing inferred. A card that fails a point is still worth drafting, but mark it `still_blocked` with the single specific question a person could act on.

## What to hand back

1. Your overlay file, every card in it passing `node build.mjs <your slugs>` (never run `build.mjs` bare).
2. `wave5/<your-id>.json` (id is `W5A` ... `W5E`), shaped as:
   `{"agent": "<id>", "cards": [{"name", "slug": "<slug or null>", "status": "complete|still_blocked|held|not_sold|already_live|variant|unreachable", "network": "<value or null>", "network_evidence": "<document or page>", "reason": "<one line>", "sources": ["url"], "still_missing": ["..."]}]}`.
   Every one of your assigned cards appears exactly once.
3. A final message of at most 150 words: counts per status, anything surprising, anything that needs a person.
