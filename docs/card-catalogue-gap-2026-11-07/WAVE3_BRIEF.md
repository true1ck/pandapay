# Wave 3 research brief (7 Nov 2026): finish the unfinished cards

Read `WAVE2_BRIEF.md` first (same folder). Everything in it still applies: paths, helpers, `node build.mjs <slug>`, hard rules,
file ownership, scratch space (use `scratchpad/wave3/<your-id>/`, create it), `python3 -I`, branch `latest-dev` only, no commits, no database, no server.

Goal of this wave: every card you own ends up either **complete enough to publish** or with a **named reason it cannot be**.
39 cards are unfinished. Their gaps came out of `REVIEW.md` and the wave 2 hand-backs (`wave2/*.json` list every unresolved question per card).

## What "complete enough to publish" means

1. Network known: Visa, Mastercard, RuPay, Amex or Diners, or two networks issued (use `dualNetwork`). A database rule refuses to publish a single-network card whose network is unknown.
   Network evidence accepted, in this order: the issuer's own page or document stating it; the card art on the issuer's own product or apply page (read the image itself,
   open the image URL in your own browser tab and look for the network mark; say in the provenance that it is card art); the network owner's own page listing the card
   (visa.co.in, mastercard.co.in, npci.org.in offers or card-finder pages); lounge, offer and dispute clauses in the issuer's T&C that name the network. Not accepted: comparison sites,
   forums, inference from MCC footnotes, a popup that is shared across several cards (the "Visa Cardholders" popup on AU pages is shared and proves nothing).
2. Fees stated, with the waiver condition. Earn rule: base rate and every accelerator, exclusion and cap the issuer states, each with its period.
3. For a card that earns points: the rupee value of one point only if an issuer document states it for that card. If the issuer states none, leave it null and
   say so in an open question. Do not use another card's value, a conversion example from a general clause, or a "reasonable baseline".
4. Nothing inferred as a fact. A cap period, reward unit, or effective date the document does not state stays an open question, not a guess.
   Where a document conflicts with the issuer's page, say which one is newer and which you used.

## What to hand back

1. Edits in the overlay entries you own (small Edit calls; re-read the lines right before each edit). Rebuild with `node build.mjs <slug>`; it must validate.
2. `wave3/<your-id>.json` in the repo folder (create the folder), shaped as
   `{"agent": "<id>", "cards": [{"slug", "status": "complete|still_blocked", "network": "<value or null>", "network_evidence": "<document or page>", "changes": ["<field: before -> after, evidence>"], "still_missing": ["..."]}]}`.
   `complete` means all four points above hold. `still_blocked` needs a specific reason a person could act on.
3. A final message of at most 150 words: how many complete, how many still blocked and why, anything surprising.
