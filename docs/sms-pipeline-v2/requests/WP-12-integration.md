# WP-12 integration decisions

The local orchestrator authorized private admin route manifest and registrar edits, backup coverage classification and explicit user replacement in EventStore. Public SMS administration stays behind the established private admin API.

- Rich DecisionTrace details stay local. The frozen request permits only the compact version/rule/stage trace.
- The frozen request has no template hash or sender brand field. A consenting client supplies sender brand/hash/shifted time in the free-form corrected._template object. redactedTemplate contains a digit-free skeleton produced after WP-00 redaction. The server independently hashes that skeleton and strips the metadata from stored corrected values.
- Without shared-learning consent the request and server row hold corrected:{} and the compact trace. Original corrected amounts, dates, merchant names and account references stay local.
- A redacted skeleton has no concrete amount or mask. A code-fix golden example requires explicit synthetic body and expectations reviewed together. The server returns redacted_expectation_required when those are absent. This avoids inventing a passing case with expectations copied from original personal values. The current frozen admin decision request provides no way to attach that reviewed example, so the admin authoring flow remains a follow-up before the WP-12 completion gate.
- Explicit user corrections can remove wrong event legs. The normal EventStore upsert remains append-only. fromUser:true now replaces the complete leg set and its stable anchor must remain first.
- The main phone runtime must drain CorrectionsSync after FactsUpload and call applyStatuses from its owner-scoped pull transaction. Root owns those WP-14 integration call sites.

The orchestrator also approved the stable-anchor index in the ledger snapshot and affected-refund reprojection, plus exact user-confirmed leg replacement in server storage. Tests cover all three boundaries. The original source fact stays the first original leg when a user fact replaces the monetary evidence.

The golden CLI currently has no --only option. The skill runs the existing complete harness and directs the agent to the exported case's report entry. A future harness filter can make this narrower.

The package syntax checkpoint found a pre-existing generated asset mismatch in api/sms_v2_assets/contracts/sms/v2/api/sync.response.schema.json. The orchestrator will regenerate the copied contracts when integrating the sync contract changes.

The orchestrator approved an additive private PUT /admin/sms/v2/corrections/:caseId/example endpoint. It accepts only source:'synthetic', body, observedAt and expect, requires learning.publish and fresh MFA, locks the owner-authorized case, and audits a content digest. The existing decision request stays frozen. WP-11 can prepare a reviewed synthetic example before sending code_fix.
