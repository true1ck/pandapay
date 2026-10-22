# SMS intelligence: technique research and final architecture decision

**Date:** 22 October 2026  
**Scope:** SMS relevance filtering, field extraction, automatic shared learning, bills/due dates/balances/mandates/subscriptions, and long-running reliability in PandaPay. This is an architecture decision based on the current repository and cited primary research; it is not a measured accuracy claim about PandaPay's user messages. The authoritative handoff is [SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md](SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md); additional implementation detail remains in [SMS_AUTONOMOUS_LEARNING_AND_CANONICAL_FACTS_PLAN.md](SMS_AUTONOMOUS_LEARNING_AND_CANONICAL_FACTS_PLAN.md).

## Decision

Build a **hybrid selective pipeline**:

1. Keep hard device safety gates and one durable, versioned source decision per SMS.
2. Use narrow, typed issuer templates and existing deterministic parsers for common formats. Automatically synthesize candidate templates from consent-eligible corrected examples, but allow only a restricted grammar and independent evaluation before activation.
3. Use separate calibrated relevance, family, and field/entity scores to choose **accept, abstain, or ignore**. Hard validation and user overrides have precedence over scores. Do not add a trained device model until it beats the current rules on held-out, time-separated data.
4. Queue Gemini only for plausible financial messages unresolved by deterministic logic. Request structured proposals; validate values, roles, evidence, and identity independently. Gemini is not a source of ground truth or an automatically trusted global rule.
5. Persist validated, versioned typed facts once and derive Activity, balances, bills, due dates, mandates, and subscription series from those facts. Subscription recurrence is learned from several source facts, not a single SMS label.
6. Run a durable learning worker that collects reliable labels, generates/evaluates candidates, shadow-runs, deploys to stable small cohorts, expands only with evidence, and rolls back automatically. Admin involvement is exceptional.

This architecture is the best fit for the existing code because the app already has local parsing, typed facts, Gemini queue, Needs Review, and versioned rule bundles. It adds the missing learning evidence, decision policy, and release controls without replacing login scanning, inbox checkpoints, source-key receipts, or current product flows.

## Evidence and what it means here

| Primary source | Relevant finding | PandaPay inference |
| --- | --- | --- |
| [On-device SMS extraction study](https://arxiv.org/abs/2002.02755) | Organizes SMS by class, then applies entity parsers; addresses SMS variation and device constraints. | Separate relevance/family decisions from value extraction. Its specific LSTM/CNN is not automatically the best model for this app. |
| [Regular expression learning for extraction](https://aclanthology.org/D08-1003/) and [FlashExtract](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/pldi14-flashextract.pdf) | Extraction programs can be induced from examples inside a constrained language. | Candidate generation from confirmed examples is feasible; constrain the language and test against counterexamples. This is a design inference, not a claim that either paper's implementation is present here. |
| [Snorkel weak supervision](https://arxiv.org/abs/1711.10160) | Heuristic labeling functions can provide training signals, but their accuracy/correlation must be modeled. | Existing rules, Gemini suggestions, and reconciled history can help find candidates; do not treat several correlated weak signals as independent proof. |
| [Calibration study](https://proceedings.mlr.press/v70/guo17a.html) and [selective classification](https://papers.neurips.cc/paper_files/paper/2017/hash/4a8423d5e91fda00bb7e46540e2b0cf1-Abstract.html) | Confidence can be miscalibrated; rejecting uncertain predictions trades automation coverage for lower accepted error. | Use measured family/field thresholds and an abstain route. A raw Gemini score or global 80% threshold is not a probability of correctness. |
| [Dataset-shift uncertainty study](https://arxiv.org/abs/1906.02530) and [concept drift survey](https://doi.org/10.1145/2523813) | Reliability and calibration can worsen as the input distribution changes. | New sender templates, wording, locale, or promotion styles require drift checks, recalibration, and a fallback path. |
| [Active learning survey](https://minds.wisconsin.edu/handle/1793/60660) | Selecting informative uncertain cases can reduce labeling work; uncertainty-only samples may be unrepresentative. | Reuse Needs Review corrections, but also audit a small, consent-eligible stratified sample of automatically accepted and ignored decisions. Otherwise the filter's own misses are invisible. |
| [Gemini structured-output documentation](https://ai.google.dev/gemini-api/docs/structured-output) | Schema-conformant JSON still needs application-level value validation. | Validate amount/date roles, posted versus pending, evidence, entity binding, and conflicts before a fact or candidate can affect the app. |
| [Google RE2 documentation](https://github.com/google/re2) | A restricted regular-expression engine can provide bounded matching time; features such as look-around and backreferences are excluded. | Prefer a typed token/slot DSL or a deliberately restricted cross-platform regex subset. Current JS/Dart regex length/nesting checks are not a proof of safe execution. |
| [Google SRE canary guidance](https://sre.google/workbook/canarying-releases/) | Small rollouts and observable comparisons reduce bad-release impact and make rollback practical. | Learned rules should shadow-run, enter stable cohorts, and auto-rollback on defined regressions. |

## Alternatives evaluated

| Technique | Positive side | Negative side in this app | Decision |
| --- | --- | --- | --- |
| Hand-authored regex/rules only | Fast, cheap, explainable, offline, predictable. | Endless manual work; misses new issuer wording; broad patterns create false matches. | Keep as trusted baseline and fallback, not the whole learning system. |
| Automatically generated unrestricted regex | Can cover repeating templates quickly. | Overmatching, runtime hazards, JS/Dart differences, difficult field-role semantics. | Do not distribute arbitrary generated regex. Generate a restricted typed template or tightly bounded subset. |
| Small scored device classifier for every SMS | Cheap after training; helps handle wording variations and triage. | Needs representative labels; may silently reject rare financial alerts; calibration drifts. | Add only after a shadow benchmark proves improvement. Never make it the sole discard authority. |
| Gemini for every SMS | Handles unfamiliar text and varied phrasing; little template authoring. | Cost, latency, quotas, offline failure, privacy exposure, occasional semantic errors, and no durable learned local capability by itself. | Use only as queued fallback for plausible financial candidates. |
| Weak/self-supervised training from model and rule outputs | Generates many candidate labels quickly. | Correlated errors create a self-reinforcing loop; lack of true negatives makes claimed gains unreliable. | Use for discovery and prioritization, not release proof. |
| Full online fine-tuning of a large model after each correction | Could learn broad language variation eventually. | Few reliable labels, difficult rollback/explanation, infrastructure cost, feedback loops, and high risk of harming old formats. | Defer until a large independent labeled corpus shows incremental benefit over the hybrid pipeline. |
| Typed template synthesis + calibrated abstention + Gemini fallback | Reuses the present app, improves common formats offline, validates exact extracted fields, contains regressions. | More engineering: example store, evaluator, lineage, cohort rollout. Some rare formats will continue to review. | **Recommended**. |

## Why five users do not prove a rule is safe

The present `sms_learning_candidates` query considers five distinct users enough to *surface* a recurring issue. It is not enough to *publish* a global automatic write or discard rule. Under an idealized independent Bernoulli model, if zero mistakes are seen in `n` independent examples, the one-sided 95% upper error bound is `1 - 0.05^(1/n)`. Five error-free examples still allow an upper error bound near **45%**. To put that bound below **0.5%** needs about **598** independent error-free examples; below **0.1%** needs about **2,995**. Correlated copies of one issuer template make the effective sample smaller. These numbers are calculated from the binomial model, consistent with [NIST's discussion of confidence bounds](https://nvlpubs.nist.gov/nistpubs/Legacy/IR/nistir6129.pdf); they do not guarantee future performance under wording drift.

Therefore use *risk-tiered automation*: a small cluster may create a candidate, improve Gemini prompting, or prefill Needs Review. It must not silently become a broad noise filter or an automatic posted-money rule. Narrow, deterministic rules with strong semantic invariants can progress sooner than broad classifiers, but still need historical negatives, cross-user/time holdout, and shadow/canary evidence. An evidence-starved candidate waits; the current pipeline continues.

## Exact inference stages

### Stage A — on-device safety and relevance

1. Hard vetoes for OTP/PIN/CVV/password/verification content, invalid or oversized body, and user-specific ignore. Do not store or send sensitive raw text. These gates do not use a learned probability.
2. Extract non-sensitive evidence features: sender family, completed versus conditional wording, negation, amount context, bill/due/balance/mandate anchors, promotion language, and exact template match. Keep completed financial events even when an offer is appended.
3. Compute distinct, calibrated scores for `useful_financial`, `pure_noise`, and any likely fact families. Only high-confidence *pure noise* is discarded with a minimal local decision receipt. Any plausible financial ambiguity remains durable and goes to deterministic extraction/server fallback.
4. Store decision, reason codes, policy/rule/model version, and source identity atomically with intake/checkpoint progress. Do not require network or Gemini for first-install scanning.

### Stage B — extraction and fact validation

Run all applicable family extractors, not one exclusive SMS category. A debit with a printed balance can emit movement and balance facts. A bill notice can emit total and minimum obligations plus printed dates. Separate posted amount, proposed amount, outstanding, limit, and available balance. Require typed fields and role/lifecycle checks. Entity matching uses independent card/account evidence; last four digits alone do not identify an account. If only one field is uncertain, retain safe facts and review that field rather than discarding the entire SMS.

Gemini can produce structured *proposals* when rules fail. Validate exact item IDs, schema, evidence spans, date order, amount signs and roles, entity conflicts, and hard-negative cues. On timeout/429/quota/malformed output, keep the durable item and use retry or Needs Review. Do not count the Gemini output as a confirmed learning label.

### Stage C — shared facts and cross-message reducers

Store one canonical source with versioned fact interpretations, provenance, overrides, and receipts. Product reducers subscribe to accepted facts. Balance is an observation at a timestamp; bill due date belongs to a statement/cycle; posted payments can settle obligations; mandate lifecycle is separate from charged money. Subscription detection groups repeated posted charges and obligations by resolved provider/payment instrument, tolerates amount/date variation, and uses mandate evidence as a hint. It must abstain on one-off repeats or ambiguous merchant identities. A parser update may supersede a machine fact, but cannot overwrite a user correction or create a second transaction.

### Stage D — long-running automatic learning

1. Ingest explicit corrections, dismissals, missed-financial reports, and independently reconciled outcomes under the current contribution preference. Keep baseline prediction, true/weak label source, typed spans/expected values, issuer/template fingerprint, and consent/deletion lineage. Restricted encrypted examples or redacted structural forms must still permit exact field-value evaluation; a sender fingerprint plus changed-field name is insufficient.
2. Cluster by issuer **and wording structure**, then synthesize a narrow typed template from multiple examples. Use Gemini only to propose anchors/slots where deterministic synthesis fails; compile through a limited DSL. Generate counterfactual amounts/dates/account suffixes and hard negatives, then test exact captures and downstream fact roles in both JS and Dart.
3. Evaluate on frozen, independent groups split by user, template, and time. Include existing accepted formats, promotions with bank words, real transaction with offer footer, OTP, EMI pitches, failed/pending, refund/reversal, bill versus payment, balance versus credit limit, and subscription false-series examples. Compare to the **current production baseline**, not to zero. Track precision, recall, review burden, exact field accuracy, entity accuracy, and financial projection deltas.
4. Run shadow on live eligible traffic without changing facts. If evidence is sufficient, assign stable cohorts and expand only after predeclared sample/time and error bounds. Repeated dashboard peeking should use a fixed evaluation schedule or an appropriate sequential method; ordinary repeated fixed-sample p-values are not valid for unrestricted stopping ([always-valid inference research](https://arxiv.org/abs/1512.04922)). Critical invariant breaches stop immediately regardless of sample size.
5. Publish a signed/checksummed compatible bundle automatically via a narrowly privileged worker. Monitor each rule and cohort. Automatically pause/roll back a rule when verified corrections, false discards, invalid facts, duplicate money events, or downstream projection errors exceed their gate. Keep previous bundles, user overrides, and immutable evaluation history.

### First user to later users: exact behavior

| Situation | First user | Later user with comparable wording |
| --- | --- | --- |
| Clear OTP/security or strongly evidenced pure promotion | Device filters immediately; keep only permitted minimal decision metadata. | Same safety/built-in rules apply immediately. |
| Plausible financial SMS, existing rule confidently extracts valid facts | Facts feed the relevant product views; no review. | Approved downloaded rule does the same offline. |
| Unknown/ambiguous SMS | Durable candidate → server rules → Gemini if eligible → existing Needs Review if still uncertain or conflicting. User can confirm/edit or mark it not financial; their decision is authoritative for that source. | A single earlier correction may improve a *suggestion* or narrow user-specific memory but does not authorize a silent shared discard/write. After independent examples and evaluation pass, a shared versioned rule auto-resolves or auto-filters the matching template. |
| Gemini unavailable, quota reached, or invalid response | Keep the candidate durable; retry within bounds and surface actionable uncertainty in Needs Review. | Cached device rules still work; no dependency on Gemini for known formats. |

The review decision should be captured once with source key, exact corrected fact/field or `not_financial` label, rule/model version, and consent status. It must not create a duplicate transaction or be overwritten by a later Gemini result. For a reviewed promotion, the originating user can immediately suppress that known source/template under a narrow personal rule; a different user is protected by the normal candidate/evaluation gate. This prevents one mistaken dismissal from hiding another person's genuine bank alert. Reuse the existing Needs Review page and actions; any missing typed correction affordance is an incremental extension, not a UI redesign.

## Failure modes and controls

| Failure mode | Why it matters | Required control |
| --- | --- | --- |
| False promotion discard | Financial SMS never reaches parser or review. | Very conservative ignore, mixed-footer corpus, sampled audit of ignored receipts, selective replay when a filter version changes. |
| False posted transaction | Corrupts spending, reports, rewards, and card balances. | Posted-event wording + amount/role/entity checks, stricter acceptance gate, existing dedupe/receipts, projection delta tests. |
| Wrong bill date or amount | Misleads due reminders and auto-pay planning. | Field-specific confidence, cycle binding, printed date evidence, review on conflict, manual override priority. |
| False subscription series | Treats ordinary repeat shopping as a commitment. | Multi-source evidence, provider/instrument resolution, cadence tolerance with negative examples, status-specific confidence. |
| Overfit learned rule | Matches near copies but harms other users/issuers. | Narrow sender/template scope, grouped holdout, historical negatives, shadow, canary, rollback. |
| Self-reinforcing labels | Model decisions become their own training truth. | Provenance-weighted labels; Gemini/rules are weak labels only; include independent user/reconciliation evidence and stratified audits. |
| No feedback on ignored SMS | Silent false negatives are invisible. | Existing-review correction plus consent-eligible audit of negative receipts; no blanket historical re-upload. |
| Drift in wording or sender IDs | Yesterday's calibration stops applying. | Versioned metrics by issuer/template/time, out-of-scope abstention, periodic recalibration, rollback. |
| Unsafe or incompatible learned pattern | Slow regex or different JS/Dart captures. | Restricted grammar, bounded input/work, cross-platform corpus, invalid bundle leaves cached fallback active. |
| Offline/quota/worker crash | Backlog, duplicate processing, or lost SMS. | Durable intake/jobs, source-key idempotency, recoverable leases, bounded retries, cached device rules, review fallback. |
| Cross-user data leakage | One user's account details reach another. | Consent, redaction/encryption, RLS, strict learning-store access, shared bundles contain only generic anchors/typed slots. |

## Practical implementation order and proof

**First:** finish the one-decision/typed-fact spine and a labeled baseline corpus. Verify the exact current paths for first install, future listener, inbox cursor, offline recovery, source-key deduplication, and each product reducer. Preserve old-client adapters. This eliminates repeated extraction and gives the evaluator a stable truth table.

**Second:** add outcome/learning examples and a scorer in shadow only. Start with interpretable evidence and calibrate family/field gates. Benchmark a small learned model against the same corpus; deploy it only if it lowers missed-financial/review burden without violating protected errors. Do not choose logistic regression, a tree, or a neural model from theory alone when PandaPay has not measured its labeled distribution.

**Third:** add restricted template synthesis and a reproducible evaluator. Publish **review suggestions** first, then safe non-money facts, then posted-money and ignore rules only after their stricter gates pass. This is an inference from the different costs of each error class.

**Fourth:** add autonomous shadow/canary/promotion/rollback and cohort-aware rule download. Test database access as `app_user`, worker crash/restart, account isolation, JS/Dart parity, invalid bundle recovery, and duplicate deliveries. Run a physical-device **update** build against the intended API URL before declaring app-level completion.

**Continuous operation:** schedule label ingestion, candidate generation, drift/evaluation, shadow metrics, canary checks, and rollback as durable jobs. Keep minimum evidence and maximum time/queue limits per state. If no labels arrive, a candidate remains pending; time passing alone never makes it safe. Expose evidence and state in the existing admin monitoring area without requiring routine approvals or a UI redesign.

## Go/no-go definition

Go only when the candidate yields a measured improvement against the active version on independent data, has zero protected-corpus critical regressions, meets a predeclared error bound appropriate to the action, maintains existing product projections and overrides, and survives shadow/canary monitoring. When a bound cannot be estimated because the dataset is too small or biased, use Gemini/Needs Review or retain the prior rule. This is the closest defensible implementation of “improve continuously without turning negative”; no method can promise perfection on every unseen SMS.
