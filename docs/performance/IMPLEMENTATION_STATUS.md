# Performance implementation status

Updated 1 November 2026 on `codex/ios-shortcuts-prototype`.

| Packet | Owner | Status | Evidence |
| --- | --- | --- | --- |
| P0 baseline and trace | Lead/QA | in progress | Existing evidence is historical; current authenticated process-cold run is still required |
| P1 network policies | Network agent | implemented-unverified | `app/test/data/authenticated_http_client_test.dart`: 9 focused tests passed; targeted analyzer and formatting passed. Integrated Flutter invocation in this Windows checkout produced no output and was stopped, so release verification remains open |
| P2 bounded jobs/SMS/outbox | Jobs agent + lead integration | implemented-unverified | Scheduler/scanner focused tests: 13 passed; provider startup capture now uses one bounded slice plus zero-delay continuations. Integrated provider analyzer/device evidence remains open |
| P3 opt-in transaction paging | Lead | implemented-unverified | `api/test/transaction_paging.test.js`: 6/6 passed; `node --check` passed. Route integration still needs API suite and local route verification |
| P4 local page coverage/refresh owner | Pending lead integration | not started | Depends on P3 contract and snapshot semantics |
| P5 incremental sync | Pending | not started | Depends on P4 and sync payload review |
| P6 DB worker isolate | Pending architecture approval | not started | Requires direct SQLite consumer inventory and worker seam |
| P7 Activity/Spending projections | Activity agent | implemented-unverified | Activity projection cache now memoizes grouping, totals, and row metadata per immutable account/filter snapshot; 23 Activity screen + projection tests passed. Spending remains audit-only |

This is an implementation ledger, not a release sign-off. A packet becomes `verified` only after its focused tests complete and the integrated regression/device evidence is recorded. Unrelated dirty SMS/AI/recurring/subscription work remains outside this ledger and must not be staged with performance packets.
