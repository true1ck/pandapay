# CCR-001. Sync context for phone wiring and provisional rules

Status. Approved by the orchestrator on 3 November 2026. The owner authorized implementation of the remaining plan. The additions supply data already stored for the authenticated account and preserve the existing required response shape.

The frozen sync response contains events and ledger, but omits their immutable source facts and update clocks. Another device cannot reconstruct Activity, bills or instrument evidence from that response. WP-14's merge rule also needs server update times. WP-10 requires delivery of a provisional rule, while the frozen AI result carries only its identifiers.

Requested additive changes to the sync response follow.

- Optional `facts`, an array of contract facts with evidence empty and raw instrument tokens removed by the server.
- Optional `updatedAt`, with `instruments`, `events` and `ledger` maps from entity ID to UTC update time.
- Optional `aiResults[].rule`, a Rule using the existing rule-bundle definition.

The existing required fields and entity shapes remain valid. The server cursor gains an opaque fact component. Source facts use their immutable creation time for paging.

Phone storage also needs account-scoped sync metadata and daily rule counters. Add those tables in a new local schema version. Keep the old table available for upgrade compatibility and avoid attributing unscoped old counters to an account.

Affected packages are WP-01 conformance, WP-08 sync, WP-10 AI delivery, WP-12 correction delivery, WP-13 verification and WP-14 phone merge. Required checks include Dart/Node agreement, old response compatibility, strict invalid-clock rejection, source-fact privacy, account isolation and persisted pull cursor tests.
