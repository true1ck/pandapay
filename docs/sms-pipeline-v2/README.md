# SMS pipeline v2: implementation plan

Source of truth: the "PandaPay SMS Classification: Gaps, Fixes and Plan" doc
(https://claude.ai/artifact/Rqc2CUSBaJwKXhwHW2t1zt). These files are a copy for agents that cannot open the doc.
The orchestrator re-exports them whenever the doc changes. Diagrams appear only in the doc.

Read in this order:

1. `overview.md`: findings, decisions, target architecture, answers to the owner's questions
2. `playbook.md`: rules every agent follows, and how the orchestrator coordinates
3. `contracts.md`: the shared data contracts, rule bundle JSON, APIs and storage
4. `work-packages/WP-XX.md`: your work package (`work-packages.md` holds the index and all packages in one file)
5. `test-and-release.md`: test layers, accuracy gates, release checklist, kill switches

Other folders:

- `seed/probe_cases.json`: the 35 synthetic probe messages from the review, with expected outcomes. WP-00 converts them into golden cases.
- `requests/`, `handoff/`: created by agents as described in the playbook.
