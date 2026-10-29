# Selected receive-range prototype V2

The user now prefers to create one Shortcut manually on iPhone. No further Shortcut UI automation is required. The signed file is an optional reusable artifact; the original `PANDAPAY DATE RANGE BACKFILL.shortcut` is unchanged.

- `PANDAPAY SELECTED RANGE V2.shortcut`: separately named signed importable workflow. Mac import was accepted and date/count/repeat/output links inspected. iPhone action resolution/runtime remains unverified.
- `PANDAPAY SELECTED RANGE V2.wflow`: readable action definition, without personal signing metadata or private messages.
- `verification.json`: build, installation and synthetic test evidence, with workspace and wrapper paths.
- Rebuild: `python3 app/tool/build_ios_history_range_shortcut.py --output artifacts/ios-history-range-v2 --sign`. Apple signing sends the action definition to Apple for validation. No third-party signing service is involved.

The installed app is **PandaPay History Probe**, bundle `app.pandapay.iosimportprobe`. Its four new V2 actions were extracted successfully by Xcode. The optional Sender as person value may be left blank for the first test; missing sender and parsing inference are reported explicitly.

For the manual recipe and exact source mappings, see `docs/ios-shortcuts-prototype-plan-2026-10-27.md`. Start the recipe from the app's **Fetch selected receive range** button; a request-less manual Shortcut run fails deliberately.

The remaining physical test is: September Fetch → explicit handoff completion and found count → inspect an original September receive timestamp separately from the current import timestamp → repeat and confirm zero new canonical rows while matches remain visible. Empty results mean no imported matches, not no spending. Search completeness and iOS runtime reliability remain unverified. The user will perform the real-message run themselves.
