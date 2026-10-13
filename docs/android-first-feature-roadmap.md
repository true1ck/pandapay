# PandaPay Android-First Feature Roadmap

**Planning date:** 13 October 2026  
**Scope:** Android and backend first. iPhone/Siri implementation is intentionally deferred.

## 1. Executive recommendation

The requested capabilities are feasible, but they should be delivered in layers:

1. Finish and connect the functionality that already exists in the app.
2. Add offline-first capture tools that do not require a paid provider.
3. Add controlled voice and AI query experiences over PandaPay's own structured data.
4. Add background location prompts only after the privacy, battery, and Android permission flow is reliable.
5. Treat live lounge availability and booking as a provider integration, not as a locally inferred result.

The first release should not make location or AI responsible for creating financial records automatically. It should suggest a merchant or trip and ask the user to confirm the amount and card.

## 2. Current codebase inventory

| Requested capability | Current state | Existing entry point | Recommendation |
|---|---|---|---|
| Trip mode | Partial: Travel Mode exists and changes reward ranking | `app/lib/features/tools/travel_mode_screen.dart` | Extend into a real trip workspace with dates and linked expenses |
| EMI calculator | Present: EMI Advisor and shared domain calculator | `app/lib/features/tools/emi_advisor_screen.dart`, `packages/pandapay_domain/lib/src/engine/calculators.dart` | Improve the inputs and comparison output; do not create a second calculator |
| Lounge access | Present: quota and manually logged visits | `app/lib/features/insights/lounge_access_screen.dart` | Add eligibility explanation, airport/provider link, and optional availability check |
| Card/receipt capture | Card OCR exists; receipt capture does not appear to be a complete flow | `app/lib/features/scan/`, `app/lib/features/onboarding/` | Reuse the OCR boundary and add receipt extraction with confirmation |
| Location prompts | Nearby merchant and geofence infrastructure exists | `app/lib/features/geofence/` | Stabilize opt-in prompts and keep them suggestion-only |
| Voice input | No complete expense voice workflow found | New feature | Add Android voice-to-draft first |
| AI expense questions | No complete natural-language query layer found | New feature | Start with deterministic query intents, then add AI parsing |
| Siri/iPhone | Not in current scope | — | Defer |

## 3. Feature plans

### A. Trip mode and trip expense tracking

**User goal:** “Show me what I spent on this trip and how much I spent on flights, hotels, food, and transport.”

#### User experience

- Tools → **Trips** → Create trip.
- Fields: trip name, destination, start date, end date, optional notes.
- Trip screen shows total spend, reward earned, category totals, card totals, and uncategorised items.
- Transactions can be added to a trip from Activity, receipt capture, SMS review, or a voice draft.
- A trip can be closed without deleting its transactions.
- AI questions can be scoped to one trip or all trips.

#### Data model

Prefer a separate `trips` table and a nullable `trip_id` on transactions rather than copying transactions:

- `trips`: owner, name, destination, start/end dates, status, created/updated timestamps.
- `transactions.trip_id`: nullable foreign key; removing a trip assignment must not delete the transaction.
- Optional later table for trip participants or shared expenses; not needed for the first version.

#### Matching rules

- Default suggestions use date range, destination/merchant location, travel category, and explicit user selection.
- SMS/card data remains the source of amount and transaction identity.
- Location alone must never invent an amount or mark a transaction as paid.

### B. EMI calculator and advisor

The domain already has `adviseEmi()` and an EMI Advisor screen. The next pass should make the output complete:

- Principal amount, tenure, interest rate, processing fee, GST, and total payable.
- Monthly EMI and total interest/fees.
- Rewards forfeited or earned by paying in full versus converting to EMI.
- A clear verdict: “EMI costs ₹X more”, “EMI is approximately neutral”, or “verify issuer offer”.
- Save/share a calculation only if the user asks; calculations should work offline.

This is a low-risk, high-value feature because the arithmetic is local and does not need a bank or lender API.

### C. Lounge access tracker and availability

The app already has E6 lounge tracking, `card_benefits`, `lounge_usage`, quota windows, and a **Log visit** action. Extend the existing flow rather than adding another lounge screen.

#### Add to each lounge benefit

- Domestic/international label.
- Network/program name.
- Visits used, visits remaining, reset date, and guest rules.
- Eligibility explanation: card/network/boarding-pass conditions and source freshness.
- **Check availability** action.
- **Open booking / Scan QR** action when a provider URL or QR payload is available.
- Manual “I used this lounge” logging remains available.

#### Where it should appear

1. Card detail → Benefits → Lounge benefit: primary contextual action.
2. Limits & perks → Lounge: cross-card comparison and quota tracker.
3. Travel Mode: show the eligible cards for the selected airport.

#### What can work without a paid integration

- Catalogue-based eligibility and quota display.
- Manual usage tracking.
- Airport/provider directory stored in the catalogue.
- Opening the provider's web booking page or QR/deep link.

#### What needs provider access

Live capacity, real-time booking confirmation, price, and provider-side eligibility require a provider API or partner credentials. The app must not claim “available” based only on the card catalogue or a static QR image.

### D. Voice mode input

Start with Android voice-to-draft, not a conversational agent that can silently modify data.

Example commands:

- “Add ₹500 at Indian Oil to my Mumbai trip.”
- “How much did I spend on flights this year?”
- “Show my dining spend last month.”

Flow:

1. User taps the microphone.
2. Android speech recognition produces text.
3. PandaPay extracts a structured draft: amount, merchant, category, date, card, and trip.
4. The app shows the draft and asks for confirmation.
5. Only confirmed drafts enter the normal transaction/outbox pipeline.

The first parser should be deterministic and support a small set of commands. AI can improve parsing later, but the final transaction must still use the same validation and duplicate checks as SMS/manual imports.

### E. Android assistant/Gemini-style access

Without implementing iPhone/Siri, Android can still expose useful entry points:

- App shortcuts for “Add expense”, “Scan receipt”, “Trips”, and “Ask PandaPay”.
- A share target for receipt screenshots and bills.
- Voice shortcut that opens PandaPay with a prefilled query or draft.
- Android home-screen widget for “Ask”, “Add”, and “Best card”.

Direct third-party assistant conversations depend on the assistant platform and its current app-action/extension support. The safe first milestone is to make PandaPay launchable with a structured intent; the app remains responsible for authentication, data access, confirmation, and response rendering.

### F. Bill/photo/screenshot capture

#### User flow

- Activity or Add Expense → **Scan bill/screenshot**.
- Capture a receipt, import an image, or share an image into PandaPay.
- Extract merchant, amount, date, tax/fee, payment method, and visible reference number.
- Show a review form with confidence indicators.
- User confirms or edits before saving.
- Run duplicate detection against SMS, email, and existing manual entries.

#### Android implementation

Use on-device document scanning and text recognition first. Google ML Kit's document scanner supports cropping, rotation, filters, and JPEG/PDF results; it runs through Google Play services and does not require PandaPay to request camera permission for the scanner flow. Text recognition can then extract receipt fields. These services reduce upload and privacy risk, though the app must handle devices without the required Google Play services.

References:

- [ML Kit document scanner](https://developers.google.com/ml-kit/vision/doc-scanner)
- [ML Kit text recognition for Android](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)

Do not send raw receipt images to the backend by default. Store them locally or delete them after extraction unless the user explicitly enables backup.

### G. AI questions over expense data

The examples are practical:

- “How much did I spend on trips this year?”
- “How much did I spend on flights this year?”
- “What did I spend on dining in Mumbai last month?”
- “Which card earned the most on travel?”

#### Recommended architecture

1. Convert the user question into a typed query intent.
2. Validate the intent against an allowlisted set of fields, date ranges, categories, merchants, trips, and cards.
3. Execute a deterministic local/API aggregation.
4. Give the result and a short explanation of the included transactions.

The AI should not calculate totals from raw text or invent missing transactions. For privacy, start with local deterministic queries; later, an AI parser may receive only the question plus schema metadata, not raw SMS, card numbers, or full receipt images.

### H. Location-based expense prompts

There are two useful levels:

#### Level 1 — foreground nearby suggestions

- User taps “Nearby merchants”.
- App reads the current location once.
- It finds nearby restaurants, fuel stations, hotels, airports, or transport points.
- User selects a merchant and creates/links an expense.

This is the safest first version and fits the existing nearby merchant flow.

#### Level 2 — opt-in background prompts

- User explicitly enables location reminders.
- Geofences are limited to relevant saved/known places.
- A notification asks: “Did you spend at this restaurant?”
- The user confirms the merchant and enters or attaches the amount.

Location cannot reliably determine the amount paid, whether payment occurred, or whether a cab ride happened. SMS, receipt, notification, or user confirmation must remain the financial evidence.

The Android implementation must explain background location, battery impact, notification permission, and the ability to disable the feature. It must also avoid high-frequency continuous tracking when a small geofence or foreground lookup is enough.

## 4. Delivery phases excluding iPhone

### Phase 0 — foundation and safety

- Define trip, receipt draft, voice draft, and query-intent models.
- Reuse the existing transaction ingestion, duplicate detection, category editing, reward recalculation, offline cache, and outbox.
- Add analytics only for feature health, not raw SMS or receipt content.
- Add feature flags so incomplete features cannot affect the stable home/activity flows.

### Phase 1 — free offline-first tools

- Trips: create, assign transactions, summary, filters.
- EMI calculator improvements.
- Lounge tracker improvements using existing catalogue and manual logging.
- Receipt/screenshot capture with local OCR and confirmation.

### Phase 2 — voice and Android entry points

- Voice-to-draft for add expense.
- Voice queries for a small deterministic command set.
- Share target, app shortcuts, and home-screen quick actions.

### Phase 3 — location assistance

- Foreground nearby merchant suggestions.
- Opt-in background geofence prompts.
- Quiet hours, notification categories, deduplication, and battery safeguards.

### Phase 4 — richer AI and provider integrations

- Natural-language query expansion.
- Trip auto-suggestions from dates, categories, and confirmed location evidence.
- Lounge provider API/partner integration if credentials become available.
- Booking handoff and confirmation reconciliation.

### Deferred

- iPhone compatibility and Siri-specific integration.
- Automatic expense creation from location alone.
- Unconfirmed live lounge availability claims.
- Autonomous AI “learning” that changes categories or rewards without user-visible correction history.

## 5. Acceptance criteria

### Data correctness

- Every new expense passes the existing validation, deduplication, category, and reward pipeline.
- Offline-created drafts synchronize once, without duplicate transactions.
- Editing a category, card, amount, or trip recomputes derived reward state.
- AI and location suggestions never create a financial transaction without confirmation.

### User trust

- Every inferred field is editable before save.
- The UI distinguishes confirmed, estimated, and suggested values.
- Receipt and location permissions are optional and reversible.
- Provider availability is shown as “not checked”, “provider check”, or “confirmed by provider”, never guessed.

### Reliability

- Home and Activity remain usable from local cache when the backend is unavailable.
- New features fail closed and do not block login, SMS ingestion, notifications, or existing reward calculations.
- Each feature has loading, empty, offline, permission-denied, and provider-error states.

## 6. Priority recommendation

Build in this order:

1. Trips and EMI polish.
2. Lounge tracker completion using existing local data.
3. Receipt/screenshot capture.
4. Voice-to-draft and Android shortcuts.
5. Foreground location suggestions.
6. Background location prompts.
7. AI query layer.
8. Live lounge provider integration.

This order delivers useful value without making the stable transaction pipeline depend on a paid API, continuous location access, or an AI service.

