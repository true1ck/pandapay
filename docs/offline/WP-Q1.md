# Offline-first: manual device checklist

Automated coverage: `app/test/offline_e2e/` (scenarios a-s against a fake server that goes offline/online) and the
per-package tests. This list is what only a real phone with a backend can prove. Use a **profile** build on a real
Android phone (`flutter build apk --profile --flavor <flavor>`) and run `scripts/perf_smoke_android.sh` once.

Airplane mode: swipe down, tap Airplane mode. "Captive" = Wi-Fi on but the server unreachable (e.g. point the build at a
black-hole API URL, or block the server in the router).

Pass = the "Expect" column, no crash, no duplicate rows after reconnect, and the top strip count returns to nothing.

| # | Do | Expect |
|---|---|---|
| 1 | Install fresh, airplane mode ON, open the app | Welcome screen renders in the Outfit font, strip says `Offline · showing saved data`, no spinner stuck, no crash |
| 2 | Sign in online, open every tab, then airplane mode ON and kill + reopen the app | Home, Activity, Cards, Insights open from saved data, you stay signed in |
| 3 | Offline: add an expense (quick add), add another with a receipt photo | Both appear instantly; strip says `Offline · 2 changes waiting to sync` |
| 4 | Reconnect | Strip shows `Syncing…` then disappears; each expense exists once on the server (check web/console); receipt still attached |
| 5 | Offline: edit a transaction category, note, payment method; bulk-change 3 rows; ignore one | Changes show immediately; after reconnect they are on the server and a pull-to-refresh does NOT revert them |
| 6 | Offline: add a card, then log a transaction on it, edit its nickname | Card shows `Saving…`; after reconnect one card on the server, the transaction attached to it |
| 7 | Offline: create a budget, mark a bill paid, hide a subscription | Visible at once, survive an app restart, one copy on the server after reconnect |
| 8 | Offline: change profile name, revoke SMS reading consent | Name shows; SMS reading stops; after reconnect exactly one consent audit entry |
| 9 | Offline: Split — create a group and add an expense | Group shows as `Waiting to sync`; after reconnect it commits, no rejection |
| 10 | Receive a bank SMS while offline (real SMS or a test SMS) | Parsed on the phone; uploads within about a minute of reconnect |
| 11 | Offline: wait for a bill due-date reminder time | Reminder fires with the app closed (inexact: may be minutes late); survives a reboot |
| 12 | Offline: sign out with queued changes | Dialog says you are offline and names the unsent changes; Stay signed in keeps them |
| 13 | Captive Wi-Fi | Screens show saved data within ~1 s; strip says `Can't reach PandaPay` within ~10 s; writes queue |
| 14 | Phone clock set +1 day, edit something, fix the clock, edit again, sync | The later edit wins everywhere |
| 15 | Second phone: sign in to the same account | Transactions, cards, budgets, bills appear; (after WP-S7/C17) bill-to-card assignments, bank balances, subscription choices appear too |
| 16 | Leave the app offline for 2+ days with queued work, then reconnect | Token refreshes, queued work replays, nothing lost |
| 17 | Force the session to be rejected (revoke the device in the web console) | App asks to sign in again; local data and queued work are kept; same user signing in resumes them |
