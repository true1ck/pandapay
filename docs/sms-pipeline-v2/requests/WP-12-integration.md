# WP-12 integration decisions

The local orchestrator authorized private admin route manifest and registrar edits, backup coverage classification and explicit user replacement in EventStore. Public SMS administration stays behind the established private admin API.

- Rich DecisionTrace details stay local. The frozen request permits only the compact version/rule/stage trace.
- The frozen request has no template hash or sender brand field. A consenting client supplies sender brand/hash/shifted time in the free-form corrected._template object. redactedTemplate contains a digit-free skeleton produced after WP-00 redaction. The server independently hashes that skeleton and strips the metadata from stored corrected values.
- Without shared-learning consent the request and server row hold corrected:{} and the compact trace. Original corrected amounts, dates, merchant names and account references stay local.
- A redacted skeleton has no concrete amount or mask. A code-fix golden example requires explicit synthetic body and expectations reviewed together. The server returns redacted_expectation_required when those are absent. This avoids inventing a passing case with expectations copied from original personal values. The current frozen admin decision request provides no way to attach that reviewed example, so the admin authoring flow remains a follow-up before the WP-12 completion gate.
- Explicit user corrections can remove wrong event legs. The normal EventStore upsert remains append-only. fromUser:true now replaces the complete leg set and its stable anchor must remain first.
- The main phone runtime must drain CorrectionsSync after FactsUpload and call applyStatuses from its owner-scoped pull transaction. Root owns those WP-14 integration call sites.
