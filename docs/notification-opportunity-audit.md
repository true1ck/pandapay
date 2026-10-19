# PandaPay notification opportunity audit

**Purpose:** inventory user-facing notification opportunities across the current app and show the appropriate delivery owner and implementation state. This is a source-code audit, not a claim that every provider is configured in production. Reviewed 18 October 2026.

## How to read the delivery column

- **On-device** means the Flutter app observes the condition and may show a local OS notification. It generally needs the app process to run and its data to be current.
- **Server event** means the API or a scheduled server job should detect the event. The API can write the inbox and, when explicitly requested, ask FCM/Novu to push it.
- **In-app only** means a screen, badge, banner, or inbox item; it should not interrupt with an OS banner by default.
- **Hybrid** means detection/state is on-device, while the durable inbox is stored by the API; remote push is a separate capability.

“Implemented” describes code in this repository. It does not guarantee provider credentials, OS permissions, APNs configuration, or deployment setup.

## User notification opportunities

| Area / event | Trigger and useful message | Recommended channel / owner | Current implementation and status | Notes / remaining work |
|---|---|---|---|---|
| Nearby merchant offer | User enters a known merchant area: “You’re near …; use card … for …” | On-device local notification; location/geofence | **Implemented**: opt-in background monitor matches nearby published merchants; notification gate applies category, mute, quiet hours and daily cap. | Requires permissions and app monitoring; force-stop/reboot stops it until app is reopened. No server geofence. |
| Card reward cap near / reached | At 80% and 100% of cap: warn that bonus earn is nearly exhausted or exhausted | Hybrid (on-device detection + server inbox); FCM deferred | **Implemented on-device/in-app inbox** through notification trigger runner. | Evaluated on app foreground/resume and after transaction-affecting sync, not continuously in background. |
| Card reward milestone near / complete | At 80% and 100% spend threshold, explain remaining spend or reward unlocked | Hybrid; FCM deferred | **Implemented on-device/in-app inbox**. | Same runtime limitation; milestone data needs to be current. |
| Annual fee waiver progress | At 90% progress, remind of qualifying spend and period deadline | Hybrid; FCM deferred | **Implemented on-device/in-app inbox**. | No reminder at a configurable lead time before the period closes. |
| Card payment due | Within 5 days, and due today, for payments needing attention | Hybrid; server reminder recommended | **Implemented on-device/in-app inbox** using the Payments Due provider. | App must run to evaluate; no server schedule or independent push. Current screen also displays due information. |
| Points expiring | Nearest dated points expiry within 30 days | Hybrid; server reminder recommended | **Implemented on-device/in-app inbox**. | Only nearest expiry is surfaced; no server schedule and no follow-up cadence. |
| Monthly report ready | Once a non-empty monthly report is available | Hybrid; server event recommended for reliable delivery | **Implemented on-device/in-app inbox**, preference defaults off. | Trigger runs when app lifecycle/sync invokes it. No scheduled month-end server job; report readiness may be noticed late. |
| Transactions need review | When unmatched/imported transactions await user review | Hybrid; on-device today | **Implemented on-device/in-app inbox**; deduped by current queue count. | A count increase can notify again; count decrease/which transactions resolved are not tracked as individual event transitions. |
| Budget running ahead of pace | When budget spend is ahead of elapsed-period pace | Hybrid; server event recommended | **Implemented on-device/in-app inbox**; separate preference and period-level dedupe. | Only checked when app runs; threshold is the existing `isOffPace` rule. |
| Budget exceeded | When spend exceeds configured budget | Hybrid; server event recommended | **Implemented on-device/in-app inbox**; separate preference and period-level dedupe. | Same lifecycle limitation. Consider avoiding a second alert if pace warning already fired unless user opts into both (currently separate category preferences). |
| Card added successfully | After explicit add-card action | In-app inbox only | **Implemented**: writes `card_added` inbox entry. | No OS banner by design; migration/schema currently permits `card_added`. |
| Streak reached / streak milestone | When logging streak advances or reaches a milestone | In-app inbox or optional local | **Partially present in schema/API contract only**; no current producer found in app code. | Decide if meaningful and define milestone/dedupe rules before implementation. |
| Transaction successfully imported | Confirmation after SMS/email/statement/manual import | In-app UI feedback; optional digest | **No notification producer found** (normal import flows show their own UI state). | Avoid one banner per transaction; if added, use a batch summary or only alert on import completion/errors. |
| Import failed / bank message could not be parsed | Actionable review item, sync failure, or rejected statement/email | In-app status / needs-review; server notification only for persistent service failures | **Partial**: needs-review notification exists; ingestion/parser error queues exist server-side. No user push for import service outage/retry exhaustion found. | Add explicit recoverable sync/import status first; notify only when user action is needed. |
| Duplicate transaction / reconciliation changed transaction | Tell user when an imported transaction was merged, corrected, or needs confirmation | In-app activity/review surface | **No notification producer found.** | Usually better represented inline in Activity/Needs Review; reserve notification for material correction needing action. |
| Card statement available / statement imported | Let user know a statement was processed or needs matching | In-app import status; optional server push for completion | **No notification producer found.** Statement ingest exists, but no matching user notification flow found. | Candidate once import status is reliably persisted per user. |
| Subscription upcoming / changed | Upcoming recurring payment or newly detected recurring merchant | In-app Insights; optional local/server reminder | **No notification producer found.** Recurring series are detected and displayed, but there is no reminder trigger. | Need confidence threshold, next-date quality, and controls to mute/cancel false positives. |
| Autopay / mandate failed or changed | Payment failure, mandate pause/cancel, or amount change from bank data | Server event if supported by source data; otherwise in-app import signal | **Not implemented as a PandaPay notification.** Parser recognizes mandate/subscription evidence, but no notification producer found. | Source coverage varies; avoid claiming delivery where bank message is unavailable. |
| Credit utilization / card limit threshold | Card utilization crosses user-set threshold or is critically high | Hybrid; local for timely SMS-derived updates, server for reliable cross-device | **No notification producer found**; utilization is shown in Insights. | User-defined threshold and alert frequency would be needed. |
| Unusual spend / large transaction | High-value or out-of-pattern purchase | On-device for SMS/local-first data; server only if event is canonical and timely | **No notification producer found.** | Requires user thresholds or transparent anomaly logic; likely opt-in due sensitivity/noise. |
| Reward opportunity / better card suggestion | User is at merchant and another owned card earns more | On-device, opt-in location event | **Partial**: nearby alerts exist, reward context infrastructure exists, but current audited monitor alerts for matching merchant presence; verify whether the message includes a personalized best-card recommendation before treating this as complete. | Product roadmap describes recommendation-style geofence alert; current background-alert doc describes merchant alert. Align actual copy/logic with promise. |
| Security/account events (new sign-in/device, password/reset, account changes) | Security-sensitive event or account recovery | Server-owned; email/push as appropriate | **No PandaPay notification flow found in audited app/API notification code.** Authentication endpoints exist. | Security notices should not depend on app lifecycle; define which events are available from auth provider and delivery channel. |
| Service incident / maintenance | Outage or planned maintenance affecting sync/import/payments insights | Server-owned admin broadcast to FCM; in-app status page | **Broadcast infrastructure implemented**, but no in-app incident/status surface found. | Admin-only `POST /admin/notifications/broadcast`; target-all push capability. No user segmentation/targeting evident. |
| Provider self-test | User requests a test delivery | Server push to registered device | **Implemented**: Settings test action → authenticated API → notification provider. | Tests provider acceptance/device setup; not a business notification trigger. |
| Notification read/unread and inbox badge | Keep a durable, reviewable history | Server-backed inbox + in-app UI | **Implemented**: inbox rows, dedupe/upsert, read actions, unread count. | Inbox history is separate from evidence that an OS banner or FCM delivery was displayed. |

## Delivery architecture and implementation inventory

| Capability | Current state | What that means |
|---|---|---|
| Durable inbox | **Implemented** (API route + `notifications` table + app inbox) | App-triggered events are recorded through the authenticated API; read state and dedupe are stored server-side. |
| Local OS notifications | **Implemented** through `flutter_local_notifications` and `NotificationGate` | Used for app-observed triggers and foreground remote messages. Preferences, quiet hours and daily cap are enforced by the gate. |
| FCM token registration | **Implemented** (Firebase Messaging + `/notification-devices`) | Token is registered to the signed-in user; refresh/retry handling exists. Actual push requires valid deployment/provider configuration and OS permission. |
| Remote push for ordinary app trigger | **Not default / opt-in at API boundary** | `/notifications` supports `sendRemote`, but the app's current `recordAppNotification` path only records inbox entries; notification trigger gate shows local OS alert. No automatic duplicate remote push. |
| Remote push self-test | **Implemented** | Authenticated user can test their own registered devices. |
| Admin broadcast push | **Implemented** | Authenticated admin can broadcast through provider to registered subscribers. |
| Server-side event scheduler | **Not found for user notification triggers** | No general job/worker evaluating bills, expiry, budgets, reports, review queue, or card caps and sending user pushes. Any existing cron around non-notification data does not establish this capability. |
| Category preference controls | **Implemented** | Location, caps, milestones, fee waivers, bills, expiry, monthly report, needs review, budget warning and exceeded are configurable. Defaults are defined in migration/API/app model. |
| Quiet hours and daily cap | **Implemented client-side gate** | Suppresses app-presented alerts. The API notification write path checks category preference but does not enforce quiet hours/daily cap. Remote pushes not originating from the gate may bypass these controls. |
| Per-merchant mute | **Implemented** | Persisted API mute list is checked by the gate for merchant-scoped alerts. |
| Deep links from notification tap | **Partial** | Inbox model and remote payload carry deep links; each producer must supply a valid route and foreground/background tap handling should be verified per notification class. |

## Recommended implementation backlog

1. **P0 — Choose an event ownership model for dependable reminders.** Add server-side scheduled evaluation for bill due, points expiry, monthly report, budget pace/overage, fee-waiver deadlines, and pending review, or explicitly keep them best-effort app-open alerts. Avoid two independent producers for the same category; use shared dedupe keys.
2. **P0 — Make remote delivery preference-aware and policy-consistent.** Current app gate applies quiet hours/daily cap before local delivery, but direct remote sends can bypass these checks. Centralize dispatch policy server-side for any future scheduled `sendRemote` use; ensure local and remote do not double-banner.
3. **P1 — Add deep links for existing triggers.** Set routes to Payments Due, points expiry, budgets, fee waivers, monthly report, and Needs Review, then verify cold-start and warm-start tap handling.
4. **P1 — Add event transition/dedupe semantics.** Track budget threshold crossings, review-queue arrivals, payment status changes, and import completion rather than relying only on a current count/state snapshot.
5. **P1 — Decide subscription, utilization, large-spend, and security event policy.** These are product opportunities rather than presently promised behavior; define consent, thresholds, suppression, and source-data guarantees before building them.
6. **P2 — Add operational visibility.** Record provider delivery outcomes and last successful scheduled sweep, and alert operators on persistent failure. Provider acceptance alone does not confirm display on a device.

## Key source references

- App trigger definitions: `app/lib/features/notifications/notification_triggers.dart`
- Shared local gate and policy: `app/lib/features/notifications/notification_gate.dart`
- FCM registration and foreground handling: `app/lib/features/notifications/push_notification_service.dart`
- Background merchant monitor: `app/lib/features/geofence/geofence_monitor_service.dart`
- User preferences schema: `db/supabase/migrations/0019_notification_preferences.sql`, `0040_budgets_instruments_recurring.sql`
- Inbox schema: `db/supabase/migrations/0024_notification_inbox.sql`, `0041_notification_budget_categories.sql`
- API inbox and admin broadcast: `api/src/index.js` (`POST /notifications`, `POST /admin/notifications/broadcast`)
- Existing integration notes: `docs/notifications-integration.md`, `docs/background-merchant-alerts.md`, `NOTIFICATION_DEPLOYMENT.md`
