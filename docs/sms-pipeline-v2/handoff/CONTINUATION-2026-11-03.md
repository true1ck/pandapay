# SMS pipeline v2 continuation — 3 November 2026

Documentation review checkpoint. Implementation is paused at the owner's request while the existing plan and handoffs are reconciled. This note records the design rationale, verified state and execution sequence; it does not replace or amend the frozen contracts or the exported plan.

## Sources and authority

Read together:

- `../README.md`, `../overview.md`, `../playbook.md`, `../contracts.md`, `../test-and-release.md`.
- The work-package index and all individual specifications, WP-00 through WP-17.
- All existing handoffs: WP-00, WP-01, WP-02, WP-03a–03d, WP-04, WP-05, WP-07, WP-08 and WP-09.
- All six existing requests under `../requests/`.

The exported v2 plan is the implementation source. Older SMS plans describe the system being replaced and supply format inventories; they do not override this plan. The work-package index records integration status. Handoffs explain implementation decisions and limitations, but do not silently change a contract.

## Design rationale to preserve

Capture, safety checks, stable source keys and durable intake remain. The middle of the pipeline changes because isolated message parsing cannot identify a bank debit and a card receipt as one payment.

The flow is:

1. Capture and safety gate on the phone.
2. One pure-Dart rule engine extracts typed facts from a versioned bundle.
3. The instrument registry resolves the user's account, card, wallet or broker.
4. The linker joins facts into stable real-world events.
5. One category resolver categorises spending with user choices first.
6. One ledger projector owns money movement, totals and counts.
7. Existing screens and rewards keep their existing input types through adapters.
8. The phone uploads compact facts and changes in batches; the server validates, stores and syncs them without parsing SMS text.

A fact says what a message states; it does not decide whether something is spending. A hold is not a debit. A card-bill payment and an own transfer are not spending. A second notice is not another payment. Money uses integer paise and points use whole points. Uncertainty goes to review.

Amazon Pay is the explicit exception to ordinary wallet accounting: its top-up counts as an Amazon purchase in `online`; its balance-payment notices do not count again. For wallets with complete purchase SMS visibility, the top-up is a transfer and each wallet purchase is spending.

Corrections have two lanes: admin-reviewed data rules reach phones without a release; engine or linking fixes need a failing golden case and a code release. AI drafts rules per redacted template; it does not publish shared rules or receive original SMS values. User-confirmed decisions take precedence.

## Verified integration state

Local integration branch: `sms-v2/main`, HEAD `064b548` when reviewed. Its worktree was clean. Nothing was pushed during this continuation.

| Work | Integration status |
| --- | --- |
| WP-00 golden harness and WP-01 contracts | Merged; contracts recorded frozen on 3 November |
| WP-02 engine and WP-03a–03d rule sources | Merged |
| WP-04 instruments and WP-07 categories | Merged |
| WP-05 linker | Merged (`d4a4cf7`) |
| WP-08 ingestion | Merged (`08c5a2f`) |
| WP-09 rule service | Merged (`cb05c0b`) |
| WP-06 ledger and projections | Not started in the index; interrupted worktree has no saved changes |
| WP-10–WP-17 | Not started in the index |

The interrupted bank and wallet fix worktrees also had no saved changes. The earlier Codex handoff worktree has been advanced to the integration HEAD. Its branch is `codex/sms-v2-wp04-07-08`; that name reflects the original request, not completed new work.

The shipped baseline is still the empty version-0 placeholder. Having rule source files merged does not mean a production-ready baseline has been built, signed, imported and shipped.

## Work saved before the documentation pause

An uncommitted rule-fix patch is isolated in the Codex handoff worktree. It is not merged into `sms-v2/main`:

- Finance hand-off keywords such as IPO and ASBA use whole-word regex guards instead of rejecting those strings inside merchant names.
- A GPAY sender and a Google Pay paid-notice rule emit a merchant and UPI reference without inventing an instrument. The sender uses the frozen enum's `other` value; `upi_app` is not in that enum.
- Regression tests reproduce the merchant-keyword and missing-notice failures.
- The linker golden test no longer exempts the duplicate-notice scenario.
- `WP-05-dup-notice-rules.md` has a local resolution note.

Checks actually run on this patch:

| Check | Result |
| --- | --- |
| New regressions plus linker golden test | 4 pass |
| Full domain suite | 989 pass, 0 fail |
| Rules lint | Clean |
| Golden linker scenarios | 8/8 expected pairs, 14/14 event scenarios, zero duplicate money legs |

These are linker and domain results, not an official ledger double-count score or a completed M1 gate. No ledger, phone-wiring or production change was made. Full app suites, API/database checks, regex parity and the complete golden CLI gate were not rerun for this patch before the pause.

## Existing decisions and integration details

Preserve the owner's accepted WP-08 decisions:

- Read `X-Sms-Sync-Has-More: 1|0`; the frozen response body has no `hasMore` field. Keep the optional contract request on record.
- Send history uploads with `?backfill=true`; do not add an undeclared body field. Backfill must not apply card rewards state.

Other handoff requirements:

- WP-14 must construct `RuleLinkContext` using recent facts, resolved instrument ids, open events and stored known events. Complete single-leg events can gain a later matching leg; context cannot contain only newly captured facts.
- `user_confirmed` events are protected. Event legs only grow. Replaying an input must not duplicate facts, evidence counts, ledger entries or rewards.
- Strip iOS filter tags before the existing contact-name/safety checks, retain the raw sender for the shared normaliser, and preserve `iosFilter` on the message. Test all five documented tag forms.
- Instrument ambiguity and rejection use `resolveDetailed`; the frozen `resolve` interface cannot return a review value. Limit history remains local metadata outside uploaded instrument JSON.
- Use `sms_v2_category.dart` for WP-07's public API. Category ids come from the existing catalogue, not constants. Read only user-confirmed category history.
- Bundle verification is owned by WP-13. WP-14 must not invent an allow-all verifier or accept an unsigned downloaded bundle. Version 0 remains the documented empty baseline exception.
- Follow WP-08's hook interfaces at call time. Refresh `api/sms_v2_assets/` after any approved contract or gates change.
- WP-09 publish needs passing golden evidence for the candidate bundle hash. Its real-database test fixture still needs reconciliation with the fully migrated schema.

## Requests and design questions to resolve deliberately

The request files are historical records; file presence alone does not mean the issue remains open. Code inspection confirms that POINTS parsing and the missing `balance_snapshot.asOf` fallback have already been implemented in the engine. The category fixture typo was already corrected on the integration branch. The no-amount failed-attempt case remains a documented contract/golden-set decision; do not fabricate an amount to satisfy it.

Before implementing the affected paths, reconcile these contract boundaries:

1. **Refund category persistence (WP-06/WP-07).** Refunds flow external → own and must reduce the original category's spending, but the frozen ledger validator forbids `category` when `to` is not external. Linked refunds may derive the category from their purchase. The standalone-refund fallback and persistence across reload/sync need an explicit contract-compatible design or a formal contract change request. Do not write an invalid refund ledger row or hide the issue in an unrecorded cache.
2. **Private provisional-rule delivery (WP-10/WP-14).** WP-10 asks sync to return `{templateHash, rule}`, while the frozen `aiResults` shape permits status and rule identifiers, not a rule body. Decide the delivery mechanism through the contract process before implementing an incompatible response.
3. **Sync freshness (WP-14).** The work package asks for newer-`updated_at` conflict resolution, while entity wire types omit that field. Specify how freshness is carried or tracked before assuming it is in entity JSON.

These are review questions recorded during documentation work, not approved contract changes. The playbook requires a request and an orchestrator decision before altering frozen schemas or signatures.

## Continuation sequence

1. Finish reviewing the isolated rule patch. Run bundle build/examples, regex parity and the golden harness, then integrate only with the required evidence. Keep the old parsers frozen.
2. Implement WP-06 in its own worktree from current `sms-v2/main`, with tests first. Build the projector and central totals, refund netting, transaction projection, namespace-scoped ledger storage, subscriptions/bills/investments/IPO/money-in adapters and guarded totals call sites. Include the specified `TxnEntryKind.refund` and `unknown` handling and exhaustive switches. Wire projector and category stages into the golden harness as an explicit integration task.
3. Run the complete M1 checkpoint. Every expected scenario total and category breakdown must match, official double counts must be zero, and required stages must be available. Keep environmental failures separate from unverified checks; do not label a gate passed when a stage is unavailable.
4. Continue M2 according to dependencies. WP-10, WP-12 and WP-13 are independent lanes after their prerequisites; WP-11 follows its APIs. WP-14 follows its listed M1 inputs and consumes the correction/security interfaces as they land. Complete verified-bundle, correction and provisional-rule integration before claiming the phone path complete.
5. WP-15 adds review/confirmation screens after phone wiring and corrections. WP-16 handles resumable replay, preserving user edits and manual rows, with a dry-run report. WP-17 cutover waits for every package, release gates, owner-reviewed migration and the tester period.

## Working discipline and release boundary

Continue the existing work-package workflow: isolated worktree, owned paths and listed touch points, failing tests first, focused checks during development, full suites at checkpoints, an evidence-based handoff and index update, then local integration in dependency order. Record deviations and requests rather than silently extending a package.

Keep all new app paths behind `SMS_PIPELINE_V2` and server routes behind the disabled-by-default flag until the planned rollout. Leave Gmail/email/IMAP and both card-discovery engines untouched. Do not edit applied migrations or generated files by hand; do not upgrade dependencies outside authorised touch points. Use synthetic or reviewed redacted fixtures only.

No push, deployment, production flag change, release or legacy deletion is part of this documentation checkpoint. The plan ships one user-facing release after its gates; an internal merge is not a release.

## Local integration and accuracy checkpoint

The owner designated `codex/sms-v2-wp14` as the integration line. Both it and `sms-v2/main` point to `b59d5bd`. The previous tip `01bd0a8` is preserved at `sms-v2/main-claude-backup`. An ancestry check confirmed that `ddd5e13`, `58d00ed` and `01bd0a8` are absent from the integration line.

The accuracy worktree is on `codex/sms-v2-real-accuracy`. From `tools/sms_rules_cli`, this command validated 1,505 examples across 724 rules, 27 ignore rules and 147 senders.

```sh
dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --created-at 2026-11-04T00:00:00Z --out /tmp/pandapay-real-sms.a1N9hk/baseline.json
```

The repository extractor attempted a read-only connection to the local Messages archive. SQLite could not open it and a direct file open confirmed macOS denied access with `Operation not permitted`. No corpus was extracted. Family accuracy, double counts and review rate remain unmeasured. The subsequent signing, import, correction, device and cutover checkpoints wait on this ordered accuracy step.

### First real-corpus baseline

After Full Disk Access was granted, the same read-only extractor retained 5,196 messages across 298 sender headers. The private evaluation directory is `/tmp/pandapay-real-sms.a1N9hk`. From `tools/sms_rules_cli`, the commands were:

```sh
p=/tmp/pandapay-real-sms.a1N9hk
dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --bundle-version 0 --created-at 2026-11-04T00:00:00Z --out "$p/baseline-v0.json"
dart --packages=.dart_tool/package_config.json "$p/probe.dart" "$p/baseline-v0.json" "$p/sms.jsonl" "$p/misses.jsonl"
dart run bin/sms_rules.dart redact --in "$p/misses.jsonl" --out "$p/redacted-misses.jsonl"
dart run bin/sms_rules.dart cluster --in "$p/redacted-misses.jsonl" --out "$p/miss-templates.json"
```

The engine matched 1,273, ignored 1,460 and returned unknown for 2,463 (47.4%). The unknowns clustered into 886 templates, with 640 covering 90% of unknown messages. These are engine outcomes. Accuracy requires reviewed expected readings. The phone review rate and double counts require running the full pipeline and checking event linkage. The family gate remains open.

### Wallet accuracy pass 1

The synthetic Zomato Money success notice first returned unknown under the baseline probe. The new sender-scoped rule emits the posted debit and the separate remaining balance. Its negative example covers unsuccessful payment.

From `tools/sms_rules_cli`, repeat the first baseline build command with output `"$p/candidate-v0.json"`. It passes 1,507 examples for 725 rules. Run the same probe against that candidate, first using `"$p/zomato-synthetic.jsonl"` and then `"$p/sms.jsonl"`. The synthetic case now matches. On the same 5,196 messages, matches rose from 1,273 to 1,344 and unknowns fell from 2,463 to 2,392. The 1,460 ignores were unchanged. These are extraction outcomes. Family accuracy, review routing and double counts remain open.

### Wallet accuracy pass 2

A synthetic PhonePe collect request failed the expected ignored outcome before the change and passed afterward. The sender-scoped service rule requires wording that makes the debit conditional on approval. It emits no movement.

From the CLI directory, rerun the baseline build with output `"$p/phonepe-service-v0.json"` and run `dart --packages=.dart_tool/package_config.json "$p/probe.dart" "$p/phonepe-service-v0.json" "$p/sms.jsonl" "$p/phonepe-service-misses.jsonl"`. Build validation passed 1,507 examples with 725 rules and 28 ignore rules. On the same corpus, 72 unknowns became ignores. Totals are 1,344 matched, 1,532 ignored and 2,320 unknown (44.65%). Accuracy and end-to-end accounting gates remain open.

### ICICI Info credit formats

The synthetic colon-delimited NEFT credit returned unknown before the fix and matched after it. Existing ICICI Info credit rules for NEFT, IMPS and RTGS accept the colon form while retaining their existing direction, salary classification and balance handling.

From the CLI directory, run the baseline build with output `"$p/icici-v0.json"`. It passed 1,508 examples. Run the probe with that bundle against `"$p/icici-synthetic.jsonl"` and then `"$p/sms.jsonl"`. The corpus now has 1,359 matches, 1,532 ignores and 2,305 unknowns. The 15 additional matches are extraction outcomes. The labeled accuracy and full-pipeline gates remain open.
