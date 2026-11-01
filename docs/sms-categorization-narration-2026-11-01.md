# SMS categorization: fifteen-minute guided narration

Companion to the [HTML guide](sms-categorization-pipeline-2026-11-01.html). This concise walkthrough follows the overview, detailed diagram and all 18 reference sections. The complete technical reference remains unchanged; exact fields, rules, tables and source links stay available on the page.

Use the chapter selector to show the matching visual. Download the [plain-text script](sms-categorization-narration-2026-11-01.txt) for your narration tool, or use optional browser read-aloud. Chapters are short so you can pause and look more closely. This explains the original source-audit snapshot dated 1 November 2026, rather than re-auditing later code changes.

## 01. First glance: the whole system
<!-- target: overview -->
**On screen:** Start with the high-level overview. Follow its top row, three branches, result and learning loop.

### Narration

Start with the overview. The system turns an SMS into useful financial information through five broad actions: receive, filter, understand, resolve and learn.

The app receives the sender, message body and original time. It excludes sensitive or irrelevant input, checks source identity, and tries to understand the message locally.

Then it takes the applicable path. Transactions normally go through server parsing and category resolution. Bills, balances and similar information can travel as structured facts. Eligible unresolved financial messages can enter AI fallback.

The result may be a record, a review item or a supported dismissal. Your corrections influence future decisions. Private rules can help immediately; shared improvements need evidence and approval.

These branches are alternatives. Every message does not pass through AI.

## 02. Follow the detailed diagram
<!-- target: detailed-pipeline -->
**On screen:** Look at the full-detail diagram and its three lanes.

### Narration

The detailed diagram expands that overview. The top blocks cover acquisition, filtering, identity and local parsing.

Lane A sends raw financial text to the server for transaction import. Lane B sends typed facts, normally without the raw body. Lane C handles eligible unresolved messages through AI, validation and device review.

At every arrow, ask what data crosses the boundary and what has actually been confirmed. A local provisional transaction, an AI suggestion and a canonical server transaction are different records.

The bottom separates private correction, shared category learning and shared parser learning.

## 03. Separate the decisions
<!-- target: section-1 -->
**On screen:** Section 1, the decision table.

### Narration

Categorization contains several decisions. Is the message relevant? What financial event does it describe? What does each amount mean? Which card or account is involved? Which spending category applies? Should the result be filed or reviewed?

These decisions can fail independently. A correct amount with a wrong category differs from a transfer incorrectly counted as spending.

AI confidence is not a universal accuracy score. A successful deterministic import can receive an inferred category without any AI second opinion.

## 04. Follow the data contracts
<!-- target: section-2 -->
**On screen:** Section 2, the contract-level flow.

### Narration

A data contract defines what each block receives and returns. Input starts as sender, body and time. Parsing adds facts, reason codes and version information. Raw upload, structured facts and AI jobs carry different representations.

Do not equate a saved observation with a confirmed payment. Ask what is evidence, what is a proposal and what has reached the ledger.

## 05. Understand the inputs
<!-- target: section-3 -->
**On screen:** Section 3, message example and supporting data.

### Narration

The common message contains sender, body and original receipt time. Account namespace is separate. Inbox or spool identifiers track acquisition progress, rather than replacing financial source identity.

Messages can arrive through Android inbox or live delivery, iOS acquisition adapters, or backup import. These routes feed shared financial logic.

Other inputs include saved cards, profile name, built-in grammar, downloaded rules and personal corrections. The server additionally uses merchant records, MCC mapping, user history and custom categories.

Missing sender can require local review. A convincing body alone does not establish verified institutional sender evidence.

## 06. Understand the early gates
<!-- target: section-4 -->
**On screen:** Section 4, filtering order and rejection outcomes.

### Narration

Early gates reject malformed or oversized input, security credentials, supported personal or promotional senders and known noise. Financial indicators and special cases then identify useful candidates.

A narrowly recognized safety advisory on a genuine financial alert can be treated differently from a real OTP. That exception does not authorize storing credentials.

Rejected input may stop before the capture store or leave only a minimal decision. Local-ignore can also mean recognized non-spend information that still produces facts.

If a useful message is rejected here, later parsing and AI cannot rescue it. Test the gate first.

## 07. Understand identity and duplicates
<!-- target: section-5 -->
**On screen:** Section 5, identity formula and done-state table.

### Narration

The active source key hashes account identity, normalized sender and normalized body. Receipt time is excluded so broadcast and inbox copies of one arrival do not count twice.

The tradeoff is that genuinely separate identical messages can collapse into one source. A repeated-occurrence marker records uncertainty without creating another transaction.

Done has several meanings. Inbox progress, final local decision, acknowledged upload, completed AI job and server transaction are distinct milestones.

A parser upgrade can permit re-evaluation on reacquisition. It does not automatically rewind the entire inbox or rewrite every old category.

## 08. Follow local parsing
<!-- target: section-6 -->
**On screen:** Section 6, financial distinctions and local dispositions.

### Narration

Local parsing combines ordered safety checks, specialized branches, approved downloaded rules and built-in grammar. Experimental shadow rules are compared separately; eligible apply-mode candidates can replace the baseline.

The parser separates charges, due amounts, minimum payments, balances and mandate ceilings. It also extracts parties, suffixes, instruments and dates.

A bill due is not a purchase. A mandate ceiling is not payment. Salary, transfers, investments, refunds and failed attempts need different treatment. A merchant receipt must not duplicate its bank alert.

Local routing can save provisional transactions, observations or commitments, acknowledge supported non-spend input, or retain review. Local parse confidence is not independently verified category certainty.

## 09. Compare category precedence
<!-- target: section-7 -->
**On screen:** Section 7, local, server and AI precedence.

### Narration

This section explains why a category can change after syncing.

Local built-in transactions prefer personal corrections, then supported financial-semantic overrides, shared category rules and the merchant catalogue. Shared rules require the matching merchant, institutional sender, context and family.

The server has another order: explicit choices, eligible personal merchant rules and private categories, then published VPA evidence, MCC, non-Other user history, database rules, built-in hints and fallbacks such as Other.

AI filing applies the latest private local correction before the AI category. It does not run that complete server resolver.

These rule stores are separate. Normal background upload does not automatically turn the phone's inferred category into an explicit server override. Earlier incorrect history or an unrelated brand in the body can also influence inference. Trace the winning tier, not just the final label.

## 10. Follow server import and facts
<!-- target: section-8 -->
**On screen:** Section 8, result outcomes and amount roles.

### Narration

The server parses raw transaction messages again, using specialized logic, active configured patterns and fallbacks. Card resolution requires compatible evidence; uncertain purchases can remain cardless.

The common writer handles duplicate identity and observations. Only eligible active card spending affects card state. Backfill protects current-period counters from historical imports.

Imported or duplicate results reconcile provisional records. Eligible unparsed messages can enter review and AI. Errors retain retryable intake.

The facts route validates separate roles such as posted, due-total, minimum, outstanding and ceiling. It applies saved overrides and supported projections. A projection is not automatically a transaction insert, and unconfirmed AI facts are not authoritative specialist evidence.

## 11. Understand when AI runs
<!-- target: section-9 -->
**On screen:** Section 9, eligibility and worker settings.

### Narration

AI normally handles eligible unresolved financial input retained for review. It does not automatically inspect every successfully imported category.

Job acceptance depends on rollout flags and worker configuration. The queue reuses the profile-and-source job. It refuses supported sensitive input and redacts identifiers before provider use.

The model receives instructions, examples, redacted text and original receipt metadata. It returns a topic and tracking decision, plus supported facts. Topic differs from spending category.

The prompt requests at most one primary actionable fact. Multiple independent movements should remain reviewable. The worker settings table contains exact batch, timeout, lease and capacity defaults.

## 12. Understand AI validation and confidence
<!-- target: section-10 -->
**On screen:** Section 10, normalization, repair, formula and routing.

### Narration

Code first normalizes supported fields. It then checks schema, amounts, party identity, suffixes, references, completion and time evidence. It tries to distinguish a charge from other amounts and to prevent receipt duplication.

Relevant validation errors can trigger one corrective AI request. This is not a second independent reviewer, and plausible wrong results that pass validation do not trigger repair. The API repeats validation, and the device rechecks before filing.

The score combines twenty-five percent model confidence, thirty-five percent evidence, twenty-five percent completeness and fifteen percent disambiguation. These components do not independently prove business-category truth.

Positive auto-filing requires at least zero point eight five, exactly one complete eligible actionable fact, and no server review-required flag. Weak, empty, incomplete or multiple actionable results stay in review.

A valid explicit negative decision follows a different route and can dismiss without that positive threshold.

AI facts stored on the server and an AI-filed local transaction still do not equal a canonical server spend.

## 13. Distinguish rechecks from retries
<!-- target: section-11 -->
**On screen:** Section 11, trigger table.

### Narration

Polling reads the existing job; it does not call AI again. Upload retry resumes durable outbox work. Provider retry reuses the job after transient failure. Invalid output can trigger the single repair pass.

Failed jobs normally remain reviewable rather than restarting on every open. Explicit retry has specific eligibility conditions.

Rule refresh is not blanket historical recategorization. User undo and saved overrides must survive replay. Account checks prevent applying one user's response to another account.

## 14. Understand correction and learning
<!-- target: section-12 -->
**On screen:** Section 12, the three learning mechanisms.

### Narration

A personal category correction can help the next matching local capture immediately. Contextual rules use merchant, sender and normalized wording. Preference-only dismissal differs from a factual false-transaction correction.

Server overrides protect corrected facts against base replay. Creating a separate future server merchant rule needs its own valid source transaction.

Shared learning is consented where applicable and distinguishes user corrections from AI proposals. Unreviewed AI output must not count as user confirmation.

Shared category rules need scoped evidence, at least ten supporting users, ninety percent agreement and separate approval.

Parser learning compiles anonymized templates and checks independent holdout examples, hard negatives and statistical limits. Candidates progress through shadow, limited, expanded and active stages. Approvals and canary gates control delivery. The worker cannot publish global bundles by itself.

## 15. Follow the worked example
<!-- target: section-13 -->
**On screen:** Section 13, switch between Correct charge, Limit used as charge and Different category.

### Narration

The sample SMS says four hundred and ninety-nine rupees were spent at Swiggy. It also mentions an available limit of forty-five thousand rupees.

The normal transaction path can parse, categorize and save this without AI. In the AI example, the correct complete fact scores zero point nine nine five.

Now select Limit used as charge. The proposed charge becomes forty-five thousand. The executed JavaScript probe still passes schema and evidence checks and requests no review. Available-limit wording escaped the amount-role exclusion.

Select Different category. The allowed Groceries label also passes, because merchant grounding does not prove business category.

These are synthetic code results, not live model responses. They demonstrate that high confidence and one repair pass do not catch every mistake. The separate mandate example reinforces that an authorized ceiling is not a payment.

## 16. Recognize failure patterns
<!-- target: section-14 -->
**On screen:** Section 14, failure-mode table.

### Narration

Common patterns include wrong categories bypassing AI, local and server rules disagreeing, earlier history reinforcing a mistake and footer brands influencing a weak merchant match.

Other risks include an early false rejection, a wrong AI negative, repeated-message identity collisions and local-only AI records being mistaken for server transactions.

These are source-supported risks, not diagnoses of every reported incident. Also check acquisition quality: missing sender, truncated body or wrong time can break otherwise correct downstream logic.

## 17. Investigate one mistake
<!-- target: section-15 -->
**On screen:** Section 15, diagnostic checklist.

### Narration

Start with expected versus actual behavior and a safe reproduction. Test triage first, then source identity and the saved observation.

Trace category rules in their actual order. Establish whether AI ran. If it did, inspect the tracking decision, extracted fields, scores and review flag separately.

Identify which record is local, provisional or server-owned. Check corrections and locks. Add a regression case at the boundary that failed rather than changing unrelated parts of the pipeline.

## 18. Prioritize improvements
<!-- target: section-16 -->
**On screen:** Section 16, suggestions.

### Narration

The highest-impact improvements are explainable field-level decision traces, consistent category precedence, separate category uncertainty, stronger negative-decision checks, closing the reproduced amount-role gap and proving AI-to-ledger persistence.

Further work should constrain inference to real merchant evidence, distinguish reviewed from inferred history, make pattern competition explicit and support controlled replay without erasing user choices.

Measure errors by family and origin. An extra model is not the first solution when the actual problem is evidence, rule disagreement or persistence.

## 19. Know the verification limits
<!-- target: section-17 -->
**On screen:** Section 17, audit scope.

### Narration

The original audit passed three hundred and thirteen focused API tests and selected Flutter suites. Its separate probe still exposed an uncovered validation gap.

Source inspection, tests, physical-device acquisition and deployed runtime behavior are different evidence. No live provider call, production write or deployment was performed by that documentation audit.

## 20. Repeat the learning path
<!-- target: section-18 -->
**On screen:** Section 18, source links, then return to the overview.

### Narration

Use the source map when you need exact implementation details. Learn in three passes: explain the overview, trace one message through the detailed diagram, then inspect the winning rule and saved state.

For every case, answer four questions: what entered, what decision won, why it won and where the result was stored. The full reference remains available whenever you need more detail.
