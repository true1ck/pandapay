# Performance implementation status

Updated 1 November 2026 on `codex/ios-shortcuts-prototype`.

| Packet | Owner | Status | Evidence |
| --- | --- | --- | --- |
| P0 baseline and trace | Lead/QA | in progress | Existing evidence is historical; current authenticated process-cold run is still required |
| P1 network policies | Network agent | implemented-unverified | `app/test/data/authenticated_http_client_test.dart`: 9 focused tests passed; targeted analyzer and formatting passed. Integrated Flutter invocation in this Windows checkout produced no output and was stopped, so release verification remains open |
| P2 bounded jobs/SMS/outbox | Jobs agent + lead integration | implemented-unverified | Scheduler/scanner focused tests: 13 passed; provider startup capture uses one bounded slice plus zero-delay continuations; intake sync is capped at 8 x 50 ready rows and schedules a guarded continuation. Provider analyzer passed; controller/device regression remains open |
| P3 opt-in transaction paging | Lead + API-client agent | implemented-unverified | API paging: 6/6 tests passed; client `TransactionPage` seam: 8/8 focused tests passed and analyzer clean of errors. Legacy full-response callers remain unchanged; store/refresh adoption and route/device verification are still open |
| P4 local page coverage/refresh owner | Pending lead integration | not started | Depends on P3 contract and snapshot semantics |
| P5 incremental sync | Pending | not started | Depends on P4 and sync payload review |
| P6 DB worker isolate | Pending architecture approval | not started | Requires direct SQLite consumer inventory and worker seam |
| P7 Activity/Spending projections | Activity + Spending agents | implemented-unverified | Activity projection cache memoizes grouping/totals/rows; 23 Activity tests passed. Spending tag/category projection resolves each visible row once; 43 Spending screen tests plus 3 projection tests passed. Broader Spending list virtualization remains open |

This is an implementation ledger, not a release sign-off. A packet becomes `verified` only after its focused tests complete and the integrated regression/device evidence is recorded. Unrelated dirty SMS/AI/recurring/subscription work remains outside this ledger and must not be staged with performance packets.
