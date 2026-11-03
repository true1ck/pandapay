---
name: sms-fix-case
description: Use when fixing an SMS classification correction case marked Code fix in the admin console.
---

Read docs/sms-pipeline-v2/playbook.md and the case's owning work-package handoff.

1. Export the decided synthetic case with `node api/scripts/export_sms_v2_case.js <caseId>`. The command reads SMS_ADMIN_BASE_URL and SMS_ADMIN_TOKEN and creates tools/sms_golden/cases/_corrections/<caseId>.json. Review the output for synthetic data before committing it.
2. Run `cd tools/sms_rules_cli && dart run bin/sms_rules.dart golden --bundle <signedBundle> --profile none` and inspect the exported case in the report. Confirm a failure at the recorded stage. If the case cannot reproduce the issue, correct its synthetic input and expectations using the admin trace before editing implementation.
3. Route by stage. Gate belongs to ignore rules, extraction to rule JSON or engine transforms, instrument to the registry, linking to link rules or the linker, category to category rules or the resolver, and sync to the phone sync code or facts route.
4. Prefer a rule or data fix when it expresses the behavior. Keep issuer-specific knowledge in rule data.
5. Make the smallest change that fixes the failing case. Keep original personal SMS text out of code, tests, logs and the conversation.
6. Run the playbook checks and the complete golden harness against its committed baseline. Review every metric regression before proceeding.
7. Describe the case ID, stage, root cause, resulting behavior and test evidence in the local review or pull request.

The export command requires an existing code-fix decision with a reviewed synthetic example. A skeleton-only case needs that example and its expectations before it can become an executable golden case.
