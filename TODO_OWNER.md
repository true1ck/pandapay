# What's left — owner action required

Code implementation is complete (34 chunks, all pushed to `origin/master`). Everything
below needs YOU specifically — none of it can be done by writing more code.

## 1. AD-3 — clear real scrape sources

12 candidate bank card-page URLs are already shortlisted, with robots.txt checked, in
`scraper/CANDIDATE_SOURCES.md`. All sit in the `sources` DB table disabled
(`tos_reviewed=false`, `is_enabled=false`). Robots.txt is NOT legal clearance — it only
governs crawlers, not scraping/reuse rights.

**To do:** for each source you want live, read that bank's actual terms of use yourself
(or have someone with authority to make that call review it), then run:

```sql
UPDATE sources SET tos_reviewed = true, is_enabled = true WHERE name = '<issuer name>';
```

one source at a time, only after a real review. Nothing has been scraped from any of
these sites.

## 2. AD-4.3 — enable real LLM extraction

The integration is fully built and key-gated (`scraper/pandapay_scraper/llm_extraction.py`).
With no key, behavior is unchanged from the existing heuristic extractor.

**To do:**
1. Get a real Anthropic API key (console.anthropic.com).
2. Add it to `scraper/.env` (already gitignored — never commit it):
   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```
3. Optionally set `EXTRACTION_MODE=llm` or `heuristic` in the same file to force a mode
   (default `auto` uses the key if present).

No code change needed after that — it activates automatically.

## 3. UA-4 — verify camera/QR card scan on a real device

Built in `app/lib/features/scan/`. Plugin wiring (`mobile_scanner`,
`google_mlkit_text_recognition`) has never run against real camera hardware.

**To do:** run the app on a real phone or simulator with camera access, open the "Scan a
QR/barcode instead" flow from Add Card, and confirm the camera permission prompt and scan
flow actually work. Report back any bugs.

## 4. UA-5.3 — verify SMS import on a real Android device

Built in `app/lib/features/sms_import/`. The `RECEIVE_SMS` listener and permission prompt
have never run on a real device (parsing logic itself is already unit-tested and verified).

**To do:** run the app on a real Android phone, grant SMS permission, and confirm incoming
bank SMS actually get picked up and parsed. Report back any bugs.

## 5. UA-8 — verify geofencing + home-screen widget on real devices

Built in `app/lib/features/geofence/` and `app/lib/features/home_widget/`. Native widget
rendering (Android `BestCardWidgetProvider.kt`, iOS `BestCardWidget.swift`) and background
location have never run on real hardware. The iOS widget extension was deliberately left
unwired into the Xcode project (avoided hand-editing `project.pbxproj` blind) — it needs a
real Xcode session to add as a proper widget extension target.

**To do:** run on a real device/simulator, test the "nearby merchants" foreground location
flow, and — separately — get the iOS widget extension properly added via Xcode before it
can be tested at all. Report back any bugs.

---

Once any of these are resolved, come back and I'll pick up from there.
