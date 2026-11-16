# PandaPay AI service architecture and rollout

## Scope

Deploy SMS rule generation as a separate project. PandaPay's worker sends a redacted SMS layout to the service and receives a candidate classification by slot. The first release uses Gemini and covers SMS rule drafting. OpenAI and other workflows follow as separate changes after evaluation.

| Component | Responsibility |
| --- | --- |
| PandaPay app and API | Local parsing, manual review, consent, redaction and template intake |
| PandaPay worker and PostgreSQL | Dedupe by template hash, job leases, retry, capacity reservations, result validation and storage |
| PandaPay AI | Private HTTP endpoint, versioned prompt, Gemini credentials and generation, response normalization |

The worker reuses the current matcher, validator and lease-bound result write. The service has no database credentials, user sessions, publication permissions or durable request storage. Its deployment can scale separately from PandaPay. The queue, worker and validation continue to use PandaPay resources.

## Accepted architecture

The owner confirmed the isolated project on 16 November 2026. PandaPay AI lives at `C:/Users/sujay/CKProjects/PandaPay-AI` with its own Git history, runtime, container and release configuration. The first implementation supports SMS rule drafts through a private authenticated API. The worker opts into this transport through deployment settings. Existing installations continue until their settings are updated. The service can be promoted and rolled back independently.

Reuse the existing Gemini credentials from the PandaPay `.env` or the server secret store. The service supports the existing Gemini key configuration and worker model/output settings. Give the isolated API its own random service bearer token. Provision these through the runtime environment. Provider credentials belong in the isolated service deployment, and the worker needs the service URL and bearer token. The legacy key can stay staged only when a direct-path rollback is intended. An existing GitHub Gemini secret can repopulate the PandaPay host `.env` during deployment, so coordinate that secret when completing a credential transfer.

The supported existing names are `GEMINI_API_KEY`, `GEMINI_FALLBACK_API_KEY`, `GEMINI_API_KEYS`, `SMS_V2_AI_MODEL` and `SMS_V2_AI_MAX_OUTPUT_TOKENS`. Repeated keys are deduplicated. Available keys rotate, and explicit quota failures can try another available key within the same 20-second deadline. Network timeouts and unusable paid output return control to the worker. Model fallback is explicit because a model change also changes validation provenance, capacity and price assumptions.

Existing draft failures remain observable through the stored failure code and attempt metadata. A queue outage, rejected candidate and unresolved destination card require their respective retry, validation and review paths. The isolated service preserves these outcomes through the API contract.

## Request and security boundary

`POST /v1/sms-rule-drafts` accepts `{senderBrand, redactedBody}` over authenticated HTTPS. The response carries `answer`, `model` and usage counters. PandaPay builds and validates the rule from the answer. Both sides use a request ID for diagnostics. The service constructs the prompt and owns model selection. Optional SMS wording, images, user IDs, and arbitrary prompts are outside the contract.

- Use private ingress, TLS, a scoped high-entropy service token and a dedicated Gemini credential in the host secret store. Keep Gemini and its egress allowlist with the service. Permit PostgreSQL access through PandaPay's existing restricted worker role.
- Check shape, size and obvious data leaks at both boundaries. Redacted layouts can still contain free text. Review the current data handling and the actual provider project's terms before processing live samples. Keep request/model bodies and credentials out of logs. [Gemini API terms](https://aistudio.google.com/docs/terms)
- Treat model output as untrusted. PandaPay retains its existing semantic and matcher checks, consent checks and lease fencing. Shared publication remains governed by the existing rule path. A `ready` draft can already reach consenting submitters as a provisional rule, so switching the production worker affects users even before shared publication.
- The app continues local parsing and manual review through a provider outage. Retryable transport, authentication/configuration and quota failures return the job to the queue with backoff. A schema rejection or unusable model answer follows the draft failure path. An HTTP request ID correlates attempts. A timed-out upstream call may still have run and incurred cost.

## Rollout and rollback

1. Verify the actual production worker configuration, lease recovery, backlog age, and recent failure codes using read-only operations. Record baseline draft acceptance and parsing quality. Keep the new service opt-in.
2. Deploy the standalone service to isolated staging. Supply a pinned Gemini model, output cap and service token. On the worker set `SMS_V2_AI_SERVICE_URL` and `SMS_V2_AI_SERVICE_TOKEN` in the protected host `.env`, or supply the corresponding GitHub deployment secrets. The production Compose service reads this pair from that file. Empty deployment inputs preserve host values. Match the configured model and output cap across both deployments and set input/output prices, quota and budget for that model. When promoting a prompt revision, set `SMS_V2_AI_SERVICE_PROMPT_VERSION` (a GitHub deployment variable or host value) to the revision served by the deployment. The worker sends these preconditions before the service makes a paid call. Review the worker's conservative prompt token reservation against each new standalone prompt revision.
3. Run the two suites and the cross-project verification. With isolated profiles and a fixed redacted corpus, compare candidate validation rate and category/fact accuracy with the existing worker. Verify consent revocation and rejection of a late result, queue recovery after service loss, manual review, and a privately delivered provisional draft. Use synthetic layouts for connectivity probes and any future admin preview. A preview should use the same schema and validation with a sandboxed result that cannot publish or sync to a user.
4. Measure request failures and latency, upstream quota, invalid drafts, oldest queued item, attempts, and spend. Confirm readiness distinguishes service startup from a successful upstream call. Use queue age and service error rate together to identify interruptions. Derive alert thresholds from the staging and current production baselines.
5. Enable production only after the quality, data handling and outage checks. Monitor the initial queue drain with the normal worker pacing and budget. If results regress, pause drafting with the existing setting and roll back the AI image. For an explicit return to the legacy path, remove both service settings, verify its model and key, and disable optional wording before resuming. The two modes use the same queue and require no data migration.

Run `node --test scripts/verify_pandapay_ai.cjs` from the PandaPay checkout with the separate `PandaPay-AI` checkout next to it. Set `PANDAPAY_AI_PROJECT_DIR` if it lives elsewhere. This test uses the real worker and HTTP service with a synthetic model response and an in-memory queue. Use staging for PostgreSQL, live-provider and signed-in app verification.

## Later work

Evaluate OpenAI on the same synthetic and redacted fixture set, including false-positive financial classifications, latency, cost and handling of malformed output. Keep rollout and provider choice explicit until its privacy terms and quality are verified. A provider fallback, an admin preview UI and workflows with image inputs each need their own acceptance tests.

## Implementation verification on 16 November 2026

| Check | Result |
| --- | --- |
| Standalone service suite | 14 passed, including independent startup, existing configuration aliases and key rotation/cooldown |
| Full PandaPay API suite | 2,537 passed, 41 skipped, four existing TODO cases |
| SMS worker and contract suite | 279 passed, 73 database/environment-gated skips |
| Real Gemini through standalone HTTP API and PandaPay validator | Synthetic layout accepted with existing `.env` key and `gemini-3.1-flash-lite`, 1,261 reported tokens |
| Cross-project outage and recovery test | Passed through real local HTTP with simulated upstream and in-memory queue |
| Deployment boundaries and container defaults | Eight tests passed, deployment YAML and shell syntax parsed |
| PostgreSQL remote-service regressions | Added outage/recovery, consent revocation and stale-lease tests to the existing disposable cluster suite; runtime unavailable locally |
| Container execution | Docker Desktop started, Linux engine pipe remained unavailable; standalone CI builds and exercises image |
| Production cutover | Requires chosen service host, runtime secrets, TLS/ingress and staging checks |

The synthetic live-provider test establishes request/response compatibility for one example. Candidate accuracy across real SMS formats is assessed with the staging fixture corpus. A timeout can still consume provider tokens, and the service does not promise exactly-once billing.
