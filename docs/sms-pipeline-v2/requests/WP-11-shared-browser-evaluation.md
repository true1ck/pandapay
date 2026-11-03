# WP-11 integration exceptions

Approved by the orchestrator during implementation on 2026-11-04.

## Shared golden evaluator

The CLI originally owned pure evaluation models, adapters, scoring, matching, gates, and reporting. Browser execution must use those exact implementations. They now live under `packages/pandapay_domain/lib/src/sms_v2/evaluation/`, exported by `sms_v2_evaluation.dart`. CLI files forward to the shared code and retain all file-system loading and command behavior. No browser library imports `dart:io`; no dependency or frozen schema changed. The shared hash uses the existing canonical JSON and crypto implementations. Full corpus parity and a Node hash vector test verify the extraction.

## Console session transport

`AdminApi.smsV2Request` is a bounded GET/PUT/POST helper for `/admin/sms/v2/` and reuses the existing private protocol, browser CSRF and native bearer headers. The feature API never constructs a separate unauthenticated HTTP client. Browser/native transport tests verify these headers and sanitized errors.

## Read metadata and build inventory

Private rule list/detail read models add source/change/example metadata and 30-day daily metrics (commit a2d2d9e). Bundle history adds a summary of publish counts/metrics. These are additive private responses, not frozen phone contracts. The generated admin route inventories are refreshed to include the reviewed synthetic correction-example route from WP-12. CI regenerates the deterministic golden asset before console analysis and rejects stale copies.

## Category correction publication

The core console commit only opens fact-rule drafts through the fact-rule editor. Category scaffolds stay visibly reviewable and do not publish an extraction rule. A separate additive integration implements reviewed category-rule draft/candidate/publication using the existing category contract and bundle signing, as approved by the orchestrator. It must preserve private capability checks, fresh MFA, audit, and candidate-bound golden gates. Reserved migration timestamp: 20261112180000 (160000 and 170000 belong to WP-12 consent and WP-16 supersede).

Implemented category integration touches: `api/src/sms_v2/category_admin_route.js`, the existing rule store and bundle builder, private registrar/manifest and generated copies, a new private RLS table in migration `20261112180000_sms_v2_category_drafts.sql`, and full-schema test rehearsal. The store preserves immutable draft revisions. The builder accepts per-cohort reports so every signed bundle keeps the report for its own exact content. Category rules have no contract ID/version fields; private draft ID/revision are stored outside the frozen rule body. Reviewed rules use the contract's `shared` source, which the domain category resolver actually applies.

New private endpoints: GET `/admin/sms/v2/category-rules`, PUT `/admin/sms/v2/category-rules/:id/draft` with a CategoryRule object, GET `/admin/sms/v2/category-rules/:id/candidate?revision=N`, POST `/admin/sms/v2/category-rules/:id/publish` with `{revision,reason,goldenReports:{testers,pct5,pct25,all}}`. Reads use `learning.read`; writes use `learning.publish` and fresh MFA. All routes retain the v2 feature guard. Publication changes shared category parts only, after all four exact candidate bundles pass. No extraction version or cohort row is changed.
