# Master into dev — 26 October 2026

Merged `origin/master` at `520dc4b` into the security/import dev branch at `5625593`. The merge retains both branches' features; it does not deploy or accept a production release. [Local verification](../artifacts/master-merge-2026-10-26/verification.json).

The Gemini worker conflict retains dev's safe error logging plus master's SMS fact validation/repair imports. The notification preview retains portable paths, output argument and multi-density/logo previews, using master's white icon tint. Both conflicted files parse; the preview runs.

Both branches already committed different `20261026130000` migration filenames. The exact two-file pair is recorded in the repository's existing prefix exception manifest; neither filename was renamed and no SQL was edited for this resolution. The custom migration runner identifies history by filename plus checksum. Unknown siblings still fail the strict prefix policy.

## Required before deployment

Master changed the contents of `20261025230000_expand_gemini_daily_capacity.sql`. The prior dev checksum and incoming master checksum differ, as recorded in verification. A synthetic history check confirms the existing runner refuses the older checksum and accepts a matching master checksum without any database call. No checksum bypass, ledger adoption or live repair was added. Verify the intended database's ledger on a protected clone and reconcile historical SQL/forward migration provenance before deploying. Merging source does not resolve an already-applied historical checksum difference. Master's new migration also changes the provider-capacity RPC signatures; API/worker/database rollout compatibility still requires review.

Master's updated AI retry/fact-repair, review/investment/bill flows and removal of daily AI caps are retained. Real provider quotas/cost and release acceptance remain separate from these unit tests. Prior dated security evidence keeps its original candidate; it is not relabeled for the merged source.

## Local checks

- Full app: 2,032 tests pass; analysis exits 0 with no errors/warnings and 94 informational lints.
- API: 1,189 pass, two existing skips; auth: 356 pass; database tools: 229 pass.
- Deployment: 23 tests pass; example production Compose and four changed YAML files parse; deployment shell syntax passes.
- All 160 API/auth JavaScript source files parse; the resolved notification preview runs.
- Strict release review remains `release_ready:false` (exit 2). No live database, feature activation, provider send or deployment occurred.
