# WP-14 shared capture integration

The orchestrator is implementing the phone wiring requested by the owner. The shared intake's new branch accepts a prepared account-scoped v2 pipeline. The capture branch retains the safety gate and stable source key, preserves explicit false-transaction preferences, and uses one savepoint for local capture, projection, outbox and source decisions.

Background callers use deferred v2 capture so only foreground processing interprets messages. The shared provider/lifecycle integration must pass the prepared pipeline when the build flag is on, and stop the legacy upload and AI status loop in that mode.

The existing source-decision table has no pipeline_version column. V2 decisions use its existing policy_version value `v2`, with bundle_version recorded separately. This local representation is explicit, and does not change a frozen wire shape. Replay checks use that policy marker.
