# RuPay-credit-on-UPI scan-to-pay

_Plan + implementation, 2026-08-29. After scanning (or picking) a UPI QR, hand the
payment to a specific installed UPI app with the VPA and amount pre-filled, and — on
Android — read back the real transaction status. RuPay credit cards are the only cards
that can pay a UPI QR, so they lead the suggestion list; other networks stay visible but
greyed, exactly as before._

---

## Goal (user's words, condensed)

> Scan at a shop that only takes QR (no card machine). Enter the amount. See the best
> RuPay card I own. Tap it → pick which UPI app to open (list every time, no sticky
> default — my cards live in different apps). Land in that app with everything filled →
> enter UPI PIN → done. No re-scan.

## What already existed

- `UpiQrScannerScreen` → `parseUpiQrString` → `ParsedUpiQr` (`pa/pn/mc/am`).
- `ScanResultScreen` ranks the wallet with `TxnRail.upiQr`; the engine already excludes
  non-`isUpiLinkable` cards with "Not usable via UPI — swipe this instead."
- `_payWith` built `upi://pay?…` and called `launchUrl` — the OS chose the app, no
  status came back. `PaymentSentScreen` then asked the user to confirm manually.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Custom Kotlin `MethodChannel`, no third-party UPI plugin** | `upi_pay` is discontinued; the others are thinly maintained. The payment surface of a payments app must stay small and auditable. ~150 lines in `MainActivity`. |
| 2 | **List all installed UPI apps every time; no "remember default"** | A cardholder keeps each card in whichever app they linked it to, and which card PandaPay picks changes shop to shop — a sticky default would send the next payment to the wrong app. |
| 3 | **No-MCC QR + user owns a UPI-linkable RuPay card → show it** (filtered to those cards) with a "Is this a business payment?" confirm before hand-off | Small shops often use a QR with no merchant category code, which the old P2P heuristic treated as a personal transfer and hid every card. RuPay-credit-on-UPI is merchant-only, so the confirm keeps it honest. |
| 4 | **Android success status → auto-log the spend** and jump to the "Logged" screen (acceptance prompt still shown) | The UPI app already told us it went through; re-asking "did you pay?" is asking the user to confirm a fact we have. |
| 5 | **iOS: plain-scheme fallback** | iOS can't target a specific UPI app or read a response. `installedApps()` returns `[]` there and the old `launchUrl` path runs. |

## Changes

### Domain — `packages/pandapay_domain/lib/src/upi/upi_qr.dart`
- `ParsedUpiQr` now also carries `tr, tn, mode, orgid, sign` (NPCI merchant fields),
  parsed verbatim from the QR.
- `buildUpiPayUri` gained optional `mc, tr, tn, mode, orgid, sign`, appended after `cu`
  in a fixed order, emitted only when set. A plain personal QR still produces the exact
  same 4-param string. This stops a verified-merchant QR from degrading to an
  "unverified payee" prompt in the UPI app.

### App — `app/lib/data/upi_payment_service.dart` (new)
- `UpiPaymentService` abstraction + `MethodChannelUpiPaymentService` over
  `app.pandapay/upi`.
- `installedApps()` → `List<UpiApp>` (name + package + PNG icon); `[]` on
  `MissingPluginException`/`PlatformException` (iOS, tests).
- `pay({upiUri, packageName})` → `UpiPaymentResult` mapping the NPCI `Status` string to
  `success / failure / submitted / cancelled`. Unknown ⇒ `submitted` (the honest
  default).
- `newTransactionRef()` → `PP<ts><rand>` for the `tr` when the QR lacked one.
- `upiPaymentServiceProvider` in `app/lib/app/providers.dart` (overridden in tests).

### Android
- `MainActivity.kt`: hosts the channel. `getInstalledUpiApps` = `queryIntentActivities`
  for `upi://pay`; `pay` = explicit `Intent(ACTION_VIEW).setPackage(pkg)` +
  `startActivityForResult`; `onActivityResult` parses the `response` extra.
- `AndroidManifest.xml`: `<queries>` entry for the `upi` VIEW intent (Android 11+ hides
  packages otherwise). `QUERY_ALL_PACKAGES` deliberately **not** used.

### iOS
- `Info.plist`: `LSApplicationQueriesSchemes` = `upi, tez, phonepe, paytmmp, credpay,
  bhim` (best-effort; iOS still degrades to the scheme launch).

### App UI
- `upi_app_picker_sheet.dart` (new): modal bottom sheet, icon + name list, returns the
  chosen `UpiApp` (or null). No default checkbox — see decision 2.
- `scan_result_screen.dart`:
  - No-MCC branch: if the wallet has a UPI-linkable RuPay card, filter the list to those
    and show an explainer banner instead of the P2P notice; otherwise keep the notice.
  - `_payWith`: business-payment confirm (no-MCC only) → build URI with merchant fields
    + synth `tr` → `installedApps()` → picker → `pay()` → route on status
    (`success` auto-logs, `submitted` manual-confirms, `failure` snackbars, `cancelled`
    silent). Empty app list ⇒ `_legacyLaunch` (old `launchUrl` + copy-VPA fallback).
  - `_ScanResultCard`: small "RuPay credit card — pays through any UPI app" line on
    eligible cards.
- `payment_sent_screen.dart`: `autoLog` flag — logs on `initState` via a post-frame
  callback; body wrapped in a scroll view so the auto-log + acceptance-prompt state
  can't overflow on a short device.

## Tests

- `upi_qr_test.dart`: merchant-field parse + `buildUpiPayUri` ordering.
- `upi_payment_service_test.dart`: channel decode, status mapping, missing-plugin ⇒ `[]`.
- `scan_result_screen_test.dart`: picker shown on Pay + prefilled intent + success lands
  on the sent screen; no-MCC RuPay list vs. P2P notice; business-payment gate.
- All existing scan / domain / widget suites pass unchanged.

## Device-test fixes (2026-08-30)

First real-device run (prod APK, Amazon Pay only installed) surfaced two things:

1. **Only Amazon Pay showed in the picker** — PhonePe/GPay/Paytm stayed hidden. The
   scheme-only `<queries><intent>` didn't match their manifest filters the way runtime
   resolution does. Fix: `AndroidManifest.xml` now also lists ~40 major UPI apps by
   `<package>` name (PhonePe, GPay, Paytm, BHIM, CRED, slice, Tata Neu, Mobikwik, bank
   apps, …), plus a host-qualified `upi://pay` intent for the long tail. Still no
   `QUERY_ALL_PACKAGES`.
2. **₹0 hand-off bounced** ("minimum ₹1 required" from the UPI app). The QR carried no
   `am` and the user didn't fill an Amount field that was easy to miss. Iterated twice
   on feedback:
   - v1: a modal "Enter the amount" — reverted, looked off-theme / interruptive.
   - v2: a standalone "Amount to pay" field at the top with inline red validation —
     rejected, felt detached from the "₹0.00" the user was looking at on the card.
   - **Final: the amount is entered on the hero card itself** (`_OnCardAmountField`), in
     place of the reward figure — a large `₹ ____` line that turns red when Pay is
     tapped empty, with the cashback resolving live right below it ("₹20.00 back").
     `amountEntryCardId` = the best owned card; the standalone field is gone. Non-hero
     cards keep their plain ₹ figure. Empty wallet shows no amount field (nothing to pay
     until a card is added).
   - Follow-up fix: `_amount` was a mirrored `Money` field that could drift from the
     controller text (field showed a number, reward stuck on "enter an amount"). It's
     now a **getter derived straight from `_amountController`**, with a controller
     listener driving rebuilds — one source of truth. A separate `amountEntered` flag
     (not `expectedValue > 0`) decides prompt-vs-reward, so a card that genuinely earns
     ₹0 on the spend still shows ₹0.00, not the prompt.
3. **Empty wallet showed "Pay with [a card you don't own]".** With no cards the screen
   ranks the whole catalogue (existing behaviour, mirrors Home) — but then offered a
   hand-off that can't complete. ui-spec B3 has no rule for this; B1 (Home) says "No
   cards → CTA to add one", and product-plan §4.1's principle is that an unusable QR
   recommendation is trust-death. Fix: when a ranked card isn't in the wallet,
   `_ScanResultCard` shows **"Add this card"** (opens the Wallet picker pre-filtered to
   that card, adds it server- or local-side, invalidates `userCardsProvider`) instead
   of "Pay with" / "Always use" / "Wasn't accepted", plus a one-line banner. Adding any
   card flips the rows back to the normal owned-card actions.

## Not done / follow-ups

- **Device testing.** Enumeration, targeted launch and the status callback can only be
  verified on a real Android phone with UPI apps installed — CI can't cover it. Manual
  checklist: (1) 2+ UPI apps show with icons; (2) chosen app opens with VPA+amount
  filled; (3) completing a payment returns `success` and auto-logs; (4) pressing back
  in the UPI app returns `cancelled`/`submitted` and does **not** log.
- Fixed-amount QRs (`am` present) are pre-filled but not locked — the UPI app enforces.
- No `sign` verification client-side; we only pass it through.
- Tap-to-pay / petrol-pump card-only acceptance stays out of scope (informational copy).
