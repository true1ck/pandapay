# PandaPay - Implementation Plan: Location-Aware Card Recommendation

**Goal:** when a user opens PandaPay at a known place, show the best card from their wallet for that place immediately.

This document captures the behavior we discussed:
- the app does **not** need card numbers, CVV, expiry, PIN, or last 4 digits
- the app only needs the user’s owned cards at the issuer/product level
- recommendation is based on the user’s wallet plus the current merchant or merchant category
- the current place can come from a scan, a known merchant location, or geofence proximity

---

## 1. User Contract

When a user has cards like HDFC Millennia, Axis Ace, and Kotak cards in their wallet:
- PandaPay should detect that the user is at a merchant or merchant category
- PandaPay should rank only the cards already in that wallet
- PandaPay should show the best card for the current place
- if the merchant is unknown, the app should fall back to category selection or scan-based identification

Examples:
- petrol pump -> show the best fuel card
- grocery store -> show the best grocery card
- online merchant -> show the best card for the merchant/category context

---

## 2. Current State In The App

The current code already supports parts of this flow:
- wallet-based recommendation ranking exists
- category-based ranking exists
- scan-based merchant/category ranking exists
- nearby-merchant lookup exists
- background geofence monitoring exists

What is already true in the codebase:
- recommendation uses the user’s owned wallet cards, not card numbers
- the engine ranks by merchant/category context when that context is available
- the nearby merchants screen can show the best card for a known merchant category

Current gap:
- the background notification tells the user to open PandaPay, but it does not yet surface the exact best card directly in the notification itself
- if location cannot be resolved to a known merchant/category, the app cannot guess the right card with confidence

---

## 3. Data Rules

The recommendation system should store only:
- issuer name
- product name
- network
- wallet membership
- card rules and source metadata

It should not store:
- PAN
- CVV
- expiry
- PIN
- last 4 digits

This is sufficient for:
- ranking the user’s owned cards
- showing the right recommendation at the right place
- keeping the app privacy-preserving

---

## 4. Required Backend Inputs

To support place-aware recommendations, the backend needs:
- a reliable card catalogue with rewards, caps, fees, and benefits
- merchant/category mapping for known places
- nearby merchant lookup by location
- geofence-friendly merchant records

Free-source strategy for card data:
1. structured open datasets first, especially CardAdvisor for India
2. official issuer pages and brochures when needed
3. third-party sources only as backup or corroboration

---

## 5. Recommendation Flow

### 5.1 Known place
1. app detects location or scan context
2. app identifies merchant or merchant category
3. app loads the user’s wallet
4. recommendation engine ranks the owned cards
5. app shows the best card first, with the reason

### 5.2 Unknown place
1. app cannot confidently infer merchant/category
2. app asks the user to pick a category or scan a QR
3. app ranks using that category or merchant context

### 5.3 Background proximity
1. geofence sees a known merchant nearby
2. app sends a notification
3. tapping the notification opens the app to the recommendation view

---

## 6. Implementation Notes

The ranking behavior should stay simple:
- use the user’s owned cards only
- score each card against the current merchant/category
- respect reward rates, caps, milestones, forex, fuel, and overrides
- display the top recommendation and a short explanation

The product should stay honest:
- if the place is known, show a direct recommendation
- if the place is not known, say so
- never pretend to know more than the data supports

---

## 7. Success Criteria

This is working well when:
- a user with HDFC Millennia, Axis Ace, and Kotak cards opens PandaPay at a petrol pump
- PandaPay identifies the location or category
- PandaPay shows the best petrol/fuel card from the wallet
- the user does not need to enter card numbers or sensitive card data
- the behavior is consistent across scan, nearby merchant, and Home surfaces

---

## 8. Next Follow-Up

If we continue this track, the next useful changes are:
- make the Home context line show the best card, not just the nearby merchant
- make the background notification more direct when the merchant/category is known
- keep the fallback path for unknown locations
- keep the data model wallet-only and issuer/product-level
## Implementation update

- Shared ranking now lives in `app/lib/data/place_recommendation.dart`.
- Foreground place screens and background geofence notifications both use the same card selection helper.
- Merchant display names are passed through when present, so a merchant-specific override can win over a broader category override for the same place.
- Recommended next verification step is a real-device GPS/notification pass, since the local test runner was slow to complete in this session.
## Implementation update

- Shared ranking now lives in `app/lib/data/place_recommendation.dart`.
- Foreground place screens and background geofence notifications both use the same shared card selection helper.
- Merchant display names are passed through when present, so a merchant-specific override can win over a broader category override for the same place.
- Notification copy is now generated from a pure helper, which makes the geofence message testable without a plugin or live GPS stream.
- Recommended next verification step is a real-device GPS/notification pass, since the local test runner was slow to complete in this session.
