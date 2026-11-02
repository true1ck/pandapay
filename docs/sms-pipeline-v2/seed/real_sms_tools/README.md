# Real SMS tools (seed for WP-00)

Scripts used on 2026-11-03 to measure today's pipeline on the owner's 12 months of iPhone SMS
(read from the Mac Messages archive with Full Disk Access). They contain no message data.

1. `python3 -I extract_messages.py ~/Library/Messages/chat.db <private>/sms_12m.jsonl 365`
   reads only letter-based sender IDs (bank and service headers), strips the iOS filter tag
   such as `(smsft_fi)` into `iosFilter`, and writes a 600-permission JSONL.
2. `node run_server.js <repo>/api <in.jsonl> <server_out.jsonl>` runs today's server parser.
3. `./run_device.sh <repo> <in.jsonl> <device_out.jsonl>` runs today's phone parser through a
   temporary flutter test that it deletes afterwards.
4. `python3 -I analyze.py <in.jsonl> <outdir> <server_out> <device_out>` groups templates and
   families and writes a redacted report; `targeted.py <dir>` runs the per-problem checks.

Never write outputs inside the repo except `tools/sms_golden/private/` (git-ignored by WP-00).
