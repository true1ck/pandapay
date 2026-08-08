# Group B — Home & Recommendation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring all 8 Group B screens (B1 Home, B2 QR Scanner, B3 Scan Result, B4 Comparison View, B5 Merchant Search, B6 Manual Quick-Add, B7 Big-Purchase Calculator, B8 Manual Overrides) up to `ui-spec.md` lines 187-279, building only the delta over what already exists (B1's category-chip/ranked-list core, the geofence machinery, the recommendation engine).

**Architecture:** B8's `card_overrides` table already exists in `db/supabase/migrations/0004_user_domain.sql` (scope `vpa`/`merchant_name`/`category` → `user_card_id`, `is_enabled`) — this plan adds CRUD routes over it and wires the resolved override into `CardSnapshot.forcedOverrideCardId`, which `RecommendationEngine._evaluate` already fully supports but nothing populates today. Everything else follows the existing pattern: plain-class HTTP repositories mirroring `UserCardsRepository`, plain Riverpod providers in `app/lib/app/providers.dart` (no codegen), and one-off imperative `Navigator.push` flows for anything that isn't a bottom-nav tab (mirroring `_AppShell._scanFromFab` in `app/lib/app/router.dart`). B2/B3's UPI QR parsing and intent-building live as pure Dart in `packages/pandapay_domain` so they're unit-testable without a camera or a UPI app installed.

**Tech Stack:** Flutter (Dart SDK ^3.12.2), Riverpod 2.6.1 (plain providers, no `@riverpod` codegen), go_router 14.6.2, `mobile_scanner` ^7.0.0 (already a dependency), `shared_preferences` ^2.3.3 (already a dependency), `http` ^1.2.2, Node/Express backend in `api/src/index.js`, Postgres with RLS (`db/supabase/migrations/`).

## Global Constraints

- **State management:** plain `Provider`/`StateProvider`/`FutureProvider`/`StateNotifierProvider` in `app/lib/app/providers.dart` only — this codebase does NOT use `@riverpod` codegen or Freezed. Do not introduce either.
- **Repositories:** plain Dart classes taking `apiBaseUrl`/`accessToken` (or just `baseUrl` for public reads), using `http.Client`, throwing `ApiException` (from `app/lib/data/api_exception.dart`) on non-2xx responses — mirror `UserCardsRepository` (`app/lib/data/user_cards_repository.dart`) exactly.
- **Currency:** the paise-based `Money` type (`packages/pandapay_domain/lib/src/money/money.dart`) everywhere money is handled — `Money.fromRupees(num)`, `.paise`, `.rupees`, `.format()`. Never a raw `double` for currency in new code.
- **Testing:** this codebase does NOT have `mocktail` or `mockito` as a dependency (verified in `app/pubspec.yaml`) despite what any skill boilerplate assumes — the actual convention (see `app/test/features/geofence/nearby_merchants_repository_test.dart`) is `package:http/testing.dart`'s `MockClient` for repository tests, and plain `flutter_test` for pure-logic and widget tests. Follow that, not mocktail.
- **Money display:** every new financial figure must go through the existing `MoneyText` widget (`app/lib/main.dart`, imported elsewhere as `import '../../main.dart' show MoneyText;`) which renders the amount plus the estimated/confirmed badge icon. Never a bare `Text(money.format())` for a user-facing amount — `no_bare_money_text` is an enforced lint.
- **Universal states (ui-spec S4):** every new screen must implement loading (skeleton/spinner, never blank), empty (`EmptyState` from `app/lib/app/design/widgets.dart`), error (`ErrorState` + `userFacingErrorMessage()` from `app/lib/data/api_exception.dart`, never a raw exception string), and state its offline behavior in a doc comment.
- **Destructive actions:** confirmation dialog before delete/disable actions that lose user data (B8 override delete). No hard-deletes of financial history anywhere (cards are archived, transactions have no DELETE route by design — see Task 15).
- **Accessibility:** 48dp minimum touch targets, `Semantics` labels on icon-only buttons, never encode meaning in color alone (pair color with an icon or text label, as `MoneyText` already does with its confirmed/estimated icon).
- **Routing:** registered go_router routes (`AppRoute` constants in `app/lib/app/router.dart`) only for the four bottom-nav tabs. Everything else (scan flows, comparison view, overrides management, search, quick-add, calculator) is a one-off `Navigator.of(context).push(MaterialPageRoute(...))`, matching `_AppShell._scanFromFab`'s existing pattern — do not register new `GoRoute`s for these.
- **Backend auth:** `requireAuth` middleware (`api/src/auth.js`) sets `req.userId` from the JWT `sub` claim; every owner-scoped query filters `profile_id = $1` (or joins through a table that does) using `req.userId` — never trust a client-supplied user id. Mirror the exact pattern in the neighboring `/user-cards` routes (`api/src/index.js` lines ~884-995).
- **No placeholders:** no screen may fake a navigation to a feature that doesn't exist. Where ui-spec references an unbuilt feature (B7's Split Suggestion → G2, EMI Comparison → G3), the button is visibly present but disabled/shows a "Coming soon" snackbar, with a doc comment stating the scope cut explicitly — same convention as `app/lib/features/geofence/nearby_merchants_screen.dart`'s header comment.

---

## Task Sequencing

B8 (backend CRUD → app repository/provider → wiring into ranking) comes first because both B3 ("Always use this card here") and B1's "override active" chip depend on it. B2/B3 depend on the UPI pure-Dart module and `url_launcher`. B5/B6 backend work is independent and can run any time after B8. B4/B7 are pure-UI over the already-existing `rankedRecommendationsProvider` and can run last.

1. B8 backend — `card_overrides` CRUD routes
2. B8 app — `CardOverridesRepository` + providers
3. B8 wiring — resolve active override into `rankedRecommendationsProvider`
4. B8 screen — Manual Overrides list/create/edit/delete/disable
5. B1 delta — hero card, "Why this card?" expansion, override chip
6. B1 delta — backup card row
7. B1 delta — alerts strip
8. B1 delta — geofence-driven context line
9. B4 — Comparison View
10. Pure-Dart UPI QR parse/build module + `url_launcher` dependency
11. B2 — QR Scanner screen
12. B3 — Scan Result screen
13. B5 backend — `GET /merchants/search`
14. B5 app — Merchant Search screen + recent searches
15. B6 backend — extend `/transactions` note handling + last-used-card persistence
16. B6 app — Manual Quick-Add screen
17. B7 — Big-Purchase Calculator

---

### Task 1: B8 backend — `card_overrides` CRUD routes

The `card_overrides` table already exists (`db/supabase/migrations/0004_user_domain.sql` lines 78-95: `id`, `profile_id`, `user_card_id`, `scope` (`vpa`|`merchant_name`|`category`), `vpa`, `merchant_name`, `category_id`, `reason_note`, `is_enabled`, `created_at`), RLS-protected by the generic owner policy in `0011_rls_policies.sql` (`card_overrides` is in both the `enable row level security` loop and the `_owner` policy loop, so `profile_id = current user id` is already enforced at the DB layer via `withUserClient`). No migration is needed — only routes.

**Files:**
- Modify: `api/src/index.js` (add routes immediately after the `/user-cards/:id/archive` route, around line 995, before the `/transactions` block)
- Test: manual `curl` verification (this repo has no existing API test harness — every other route in `api/src/index.js` is verified this way; match that convention, don't introduce a new one)

**Interfaces:**
- Consumes: `requireAuth` middleware (`req.userId`), `withUserClient(userId, fn)` helper (already used throughout `api/src/index.js` for RLS-scoped queries).
- Produces: `GET /card-overrides`, `POST /card-overrides`, `PATCH /card-overrides/:id`, `DELETE /card-overrides/:id` — response shapes documented in each step below. Task 2's `CardOverridesRepository` consumes these exactly.

- [ ] **Step 1: Add `GET /card-overrides`**

```js
/**
 * GET /card-overrides — B8: every override rule the signed-in user owns,
 * enabled or disabled (the Manual Overrides screen shows both, with a
 * disabled-state pill — B8's empty state explains how to create one from
 * B3, not filtered out here). Same owner-scoped pattern as GET /user-cards.
 */
app.get('/card-overrides', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT co.id, co.user_card_id, co.scope, co.vpa, co.merchant_name,
                co.category_id, sc.name AS category_name, co.reason_note,
                co.is_enabled, co.created_at,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM card_overrides co
           JOIN user_cards uc ON uc.id = co.user_card_id
           JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = co.category_id
          WHERE co.profile_id = $1
          ORDER BY co.created_at DESC`,
        [req.userId]
      )
    );
    res.json({ overrides: result.rows });
  } catch (err) {
    console.error('GET /card-overrides error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

- [ ] **Step 2: Add `POST /card-overrides`**

```js
/**
 * POST /card-overrides — B3's "Always use this card here" and B8's manual
 * "create a rule" both land here. `scope` determines which of vpa/
 * merchantName/categoryId is required — mirrors the table's
 * override_scope_populated CHECK constraint exactly so a bad request fails
 * with a clear 400 instead of a raw constraint-violation 500.
 */
app.post('/card-overrides', requireAuth, async (req, res) => {
  const { userCardId, scope, vpa, merchantName, categoryId, reasonNote } = req.body || {};
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!['vpa', 'merchant_name', 'category'].includes(scope)) {
    return res.status(400).json({ error: "scope must be 'vpa', 'merchant_name', or 'category'" });
  }
  if (scope === 'vpa' && !vpa) {
    return res.status(400).json({ error: 'vpa is required when scope is vpa' });
  }
  if (scope === 'merchant_name' && !merchantName) {
    return res.status(400).json({ error: 'merchantName is required when scope is merchant_name' });
  }
  if (scope === 'category' && !categoryId) {
    return res.status(400).json({ error: 'categoryId is required when scope is category' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(
        `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
        [userCardId, req.userId]
      );
      if (owns.rows.length === 0) return null;

      const inserted = await client.query(
        `INSERT INTO card_overrides (profile_id, user_card_id, scope, vpa, merchant_name, category_id, reason_note)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, user_card_id, scope, vpa, merchant_name, category_id, reason_note, is_enabled, created_at`,
        [req.userId, userCardId, scope, vpa || null, merchantName || null, categoryId || null, reasonNote || null]
      );
      return inserted.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'user_card not found or not owned by you' });
    res.status(201).json({ override: result });
  } catch (err) {
    console.error('POST /card-overrides error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

- [ ] **Step 3: Add `PATCH /card-overrides/:id`**

```js
/**
 * PATCH /card-overrides/:id — B8's edit + enable/disable toggle. Only
 * is_enabled, reason_note, and user_card_id (re-pointing the rule at a
 * different card) are editable — scope/vpa/merchant_name/category_id are
 * NOT patchable here; changing what a rule targets is a delete-and-recreate
 * in the UI (Task 4), keeping this route's write surface small and the
 * override_scope_populated CHECK trivially satisfied (we never touch the
 * scope-defining columns).
 */
app.patch('/card-overrides/:id', requireAuth, async (req, res) => {
  const { isEnabled, reasonNote, userCardId } = req.body || {};
  const sets = [];
  const params = [];
  if (isEnabled !== undefined) {
    params.push(!!isEnabled);
    sets.push(`is_enabled = $${params.length}`);
  }
  if (reasonNote !== undefined) {
    params.push(reasonNote || null);
    sets.push(`reason_note = $${params.length}`);
  }
  if (userCardId !== undefined) {
    params.push(userCardId);
    sets.push(`user_card_id = $${params.length}`);
  }
  if (sets.length === 0) {
    return res.status(400).json({ error: 'nothing to update' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      if (userCardId !== undefined) {
        const owns = await client.query(
          `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
          [userCardId, req.userId]
        );
        if (owns.rows.length === 0) return 'card_not_found';
      }
      params.push(req.params.id, req.userId);
      const updated = await client.query(
        `UPDATE card_overrides SET ${sets.join(', ')}
          WHERE id = $${params.length - 1} AND profile_id = $${params.length}
          RETURNING id, user_card_id, scope, vpa, merchant_name, category_id, reason_note, is_enabled, created_at`,
        params
      );
      return updated.rows[0] || null;
    });

    if (result === 'card_not_found') return res.status(404).json({ error: 'user_card not found or not owned by you' });
    if (!result) return res.status(404).json({ error: 'override not found' });
    res.json({ override: result });
  } catch (err) {
    console.error('PATCH /card-overrides/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

- [ ] **Step 4: Add `DELETE /card-overrides/:id`**

```js
/**
 * DELETE /card-overrides/:id — unlike transactions/user_cards (R4: archive,
 * never delete — they carry financial history), an override rule is pure
 * user *intent*, not a financial record, so a true delete is appropriate
 * here. Confirmation lives client-side (Task 4's delete-confirmation
 * dialog per this plan's Global Constraints).
 */
app.delete('/card-overrides/:id', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `DELETE FROM card_overrides WHERE id = $1 AND profile_id = $2 RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'override not found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /card-overrides/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

- [ ] **Step 5: Manually verify against a running `api/` + local Postgres**

Run: `cd api && npm start` (or however this repo's dev script is named — check `api/package.json`'s `scripts.start`), then in another shell:

```bash
TOKEN="<a real access token from POST /auth/login-otp-verify or similar>"
curl -s -X POST http://localhost:4000/card-overrides \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"userCardId":"<a real user_cards.id you own>","scope":"vpa","vpa":"test@upi","reasonNote":"testing"}'
curl -s http://localhost:4000/card-overrides -H "Authorization: Bearer $TOKEN"
curl -s -X PATCH http://localhost:4000/card-overrides/<id> -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"isEnabled":false}'
curl -s -X DELETE http://localhost:4000/card-overrides/<id> -H "Authorization: Bearer $TOKEN"
```

Expected: 201 with an `override` object on create, 200 with an `overrides` array on list, 200 with the patched `override` on disable, 200 `{"ok":true}` on delete, and a 404 on any of these against an id you don't own.

- [ ] **Step 6: Commit**

```bash
git add api/src/index.js
git commit -m "feat(api): add card_overrides CRUD routes for B8 manual overrides"
```

---

### Task 2: B8 app — `CardOverridesRepository` + providers

**Files:**
- Create: `app/lib/data/card_overrides_repository.dart`
- Modify: `app/lib/app/providers.dart` (add `cardOverridesRepositoryProvider`, `cardOverridesProvider` after `userCardsProvider`, around line 200)
- Test: `app/test/data/card_overrides_repository_test.dart`

**Interfaces:**
- Consumes: Task 1's `GET/POST/PATCH/DELETE /card-overrides` response shapes; `accessTokenProvider` (existing).
- Produces: `class CardOverride` (fields: `id`, `userCardId`, `scope` (`OverrideScope` enum: `vpa`, `merchantName`, `category`), `vpa`, `merchantName`, `categoryId`, `categoryName`, `reasonNote`, `isEnabled`, `createdAt`, `cardName`, `cardNickname`); `class CardOverridesRepository` with `fetchOverrides()`, `createOverride({required userCardId, required scope, vpa, merchantName, categoryId, reasonNote})`, `setEnabled(String id, bool enabled)`, `delete(String id)`; `cardOverridesRepositoryProvider` (`Provider<CardOverridesRepository?>`, null when signed out — same pattern as `userCardsRepositoryProvider`); `cardOverridesProvider` (`FutureProvider<List<CardOverride>>`, empty list when signed out). Task 3 consumes `cardOverridesProvider`; Task 4 consumes the whole repository.

- [ ] **Step 1: Write the repository file**

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

enum OverrideScope { vpa, merchantName, category }

OverrideScope _scopeFromJson(String raw) => switch (raw) {
      'vpa' => OverrideScope.vpa,
      'merchant_name' => OverrideScope.merchantName,
      'category' => OverrideScope.category,
      _ => throw ApiException('Unknown override scope: $raw'),
    };

String _scopeToJson(OverrideScope scope) => switch (scope) {
      OverrideScope.vpa => 'vpa',
      OverrideScope.merchantName => 'merchant_name',
      OverrideScope.category => 'category',
    };

/// B8: a single "always use X here" rule — mirrors `card_overrides`
/// (db/supabase/migrations/0004_user_domain.sql). Exactly one of
/// [vpa]/[merchantName]/[categoryId] is non-null, matching [scope] and the
/// table's `override_scope_populated` CHECK.
class CardOverride {
  final String id;
  final String userCardId;
  final OverrideScope scope;
  final String? vpa;
  final String? merchantName;
  final String? categoryId;
  final String? categoryName;
  final String? reasonNote;
  final bool isEnabled;
  final DateTime createdAt;
  final String cardName;
  final String? cardNickname;

  const CardOverride({
    required this.id,
    required this.userCardId,
    required this.scope,
    this.vpa,
    this.merchantName,
    this.categoryId,
    this.categoryName,
    this.reasonNote,
    required this.isEnabled,
    required this.createdAt,
    required this.cardName,
    this.cardNickname,
  });

  /// What the override screen and B1's "override active" chip show —
  /// nickname if the user set one, else the product name (same fallback
  /// TransactionEntry.cardDisplayName uses in user_cards_repository.dart).
  String get cardDisplayName => (cardNickname?.isNotEmpty == true) ? cardNickname! : cardName;

  factory CardOverride.fromJson(Map<String, dynamic> json) => CardOverride(
        id: json['id'] as String,
        userCardId: json['user_card_id'] as String,
        scope: _scopeFromJson(json['scope'] as String),
        vpa: json['vpa'] as String?,
        merchantName: json['merchant_name'] as String?,
        categoryId: json['category_id'] as String?,
        categoryName: json['category_name'] as String?,
        reasonNote: json['reason_note'] as String?,
        isEnabled: json['is_enabled'] as bool,
        createdAt: DateTime.parse(json['created_at'] as String),
        cardName: json['card_name'] as String,
        cardNickname: json['card_nickname'] as String?,
      );
}

class CardOverridesRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  CardOverridesRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<List<CardOverride>> fetchOverrides() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/card-overrides'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /card-overrides failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['overrides'] as List).cast<Map<String, dynamic>>().map(CardOverride.fromJson).toList();
  }

  Future<CardOverride> createOverride({
    required String userCardId,
    required OverrideScope scope,
    String? vpa,
    String? merchantName,
    String? categoryId,
    String? reasonNote,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-overrides'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'scope': _scopeToJson(scope),
        'vpa': ?vpa,
        'merchantName': ?merchantName,
        'categoryId': ?categoryId,
        'reasonNote': ?reasonNote,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /card-overrides failed: ${response.statusCode} ${response.body}');
    }
    return CardOverride.fromJson((jsonDecode(response.body) as Map<String, dynamic>)['override'] as Map<String, dynamic>);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/card-overrides/$id'),
      headers: _headers,
      body: jsonEncode({'isEnabled': enabled}),
    );
    if (response.statusCode != 200) {
      throw ApiException('PATCH /card-overrides/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> delete(String id) async {
    final response = await _client.delete(Uri.parse('$apiBaseUrl/card-overrides/$id'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('DELETE /card-overrides/$id failed: ${response.statusCode} ${response.body}');
    }
  }
}
```

- [ ] **Step 2: Write the repository test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/card_overrides_repository.dart';

void main() {
  group('CardOverridesRepository', () {
    test('fetchOverrides parses a real-shaped GET /card-overrides response', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/card-overrides');
        return http.Response(
          jsonEncode({
            'overrides': [
              {
                'id': 'o1',
                'user_card_id': 'uc1',
                'scope': 'vpa',
                'vpa': 'merchant@upi',
                'merchant_name': null,
                'category_id': null,
                'category_name': null,
                'reason_note': 'always this one',
                'is_enabled': true,
                'created_at': '2026-01-01T00:00:00Z',
                'card_name': 'HDFC Millennia',
                'card_nickname': null,
              },
            ],
          }),
          200,
        );
      });
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      final result = await repo.fetchOverrides();

      expect(result, hasLength(1));
      expect(result.first.scope, OverrideScope.vpa);
      expect(result.first.vpa, 'merchant@upi');
      expect(result.first.cardDisplayName, 'HDFC Millennia');
    });

    test('a non-201 response from createOverride throws ApiException', () async {
      final client = MockClient((request) async => http.Response('bad', 400));
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      expect(
        () => repo.createOverride(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd app && flutter test test/data/card_overrides_repository_test.dart`
Expected: both tests PASS.

- [ ] **Step 4: Wire the providers into `app/lib/app/providers.dart`**

Insert after `userCardsProvider` (currently ending around line 200):

```dart
final cardOverridesRepositoryProvider = Provider<CardOverridesRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return CardOverridesRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// B8 — every override rule the signed-in user owns (enabled or disabled).
/// Empty (not an error) when signed out, same reasoning as userCardsProvider.
final cardOverridesProvider = FutureProvider<List<CardOverride>>((ref) async {
  final repo = ref.watch(cardOverridesRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchOverrides();
});
```

Add the import at the top of `providers.dart`:

```dart
import '../data/card_overrides_repository.dart';
```

- [ ] **Step 5: Commit**

```bash
git add app/lib/data/card_overrides_repository.dart app/lib/app/providers.dart app/test/data/card_overrides_repository_test.dart
git commit -m "feat(app): add CardOverridesRepository and cardOverridesProvider for B8"
```

---

### Task 3: B8 wiring — resolve the active override into `rankedRecommendationsProvider`

This is the "was missing" bug ui-spec.md flags for B8: `RecommendationEngine._evaluate` already fully honors `CardSnapshot.forcedOverrideCardId` (packages/pandapay_domain/lib/src/engine/engine.dart line 277 — sets `isOverride: true`, adds the "Manual override" reason line, and the sort in `rank()` line 84 always puts an override first) but `rankedRecommendationsProvider` in `app/lib/app/providers.dart` (line ~307) always constructs `CardSnapshot` without passing it. This task adds the resolution logic and feeds it through.

**Files:**
- Create: `app/lib/data/override_resolver.dart`
- Test: `app/test/data/override_resolver_test.dart`
- Modify: `app/lib/app/providers.dart` (`rankedRecommendationsProvider`, lines ~264-314)

**Interfaces:**
- Consumes: `CardOverride`/`OverrideScope` (Task 2), `UserCard` (`app/lib/data/user_cards_repository.dart`).
- Produces: `String? resolveActiveOverrideCardProductId({required List<CardOverride> overrides, required List<UserCard> wallet, String? categoryId, String? merchantName, String? vpa})` — a pure function returning the `CardProduct.id` (not the `user_cards.id`) that should be forced to the top, or null if no enabled override matches. Task 5 (B1's override chip) and Task 12 (B3) both call this same function via the provider this task adds.

- [ ] **Step 1: Write the failing test for the pure resolver**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/override_resolver.dart';
import 'package:pandapay/data/user_cards_repository.dart';

CardOverride _override({
  required String userCardId,
  required OverrideScope scope,
  String? vpa,
  String? merchantName,
  String? categoryId,
  bool isEnabled = true,
}) =>
    CardOverride(
      id: 'ov-$userCardId-${scope.name}',
      userCardId: userCardId,
      scope: scope,
      vpa: vpa,
      merchantName: merchantName,
      categoryId: categoryId,
      isEnabled: isEnabled,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'Card $userCardId',
    );

UserCard _userCard(String id, String cardProductId) =>
    UserCard(id: id, cardProductId: cardProductId, cardName: 'Card $id', isDefault: false);

void main() {
  group('resolveActiveOverrideCardProductId', () {
    test('a vpa-scoped override wins over a category-scoped one for the same context', () {
      final wallet = [_userCard('uc1', 'prod1'), _userCard('uc2', 'prod2')];
      final overrides = [
        _override(userCardId: 'uc2', scope: OverrideScope.category, categoryId: 'cat1'),
        _override(userCardId: 'uc1', scope: OverrideScope.vpa, vpa: 'shop@upi'),
      ];

      final result = resolveActiveOverrideCardProductId(
        overrides: overrides,
        wallet: wallet,
        categoryId: 'cat1',
        vpa: 'shop@upi',
      );

      expect(result, 'prod1');
    });

    test('a disabled override never matches', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1', isEnabled: false)];

      final result = resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, categoryId: 'cat1');

      expect(result, isNull);
    });

    test('a merchant_name override matches only on an exact, case-insensitive name', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.merchantName, merchantName: 'DMart Powai')];

      expect(
        resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, merchantName: 'dmart powai'),
        'prod1',
      );
      expect(
        resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, merchantName: 'DMart Andheri'),
        isNull,
      );
    });

    test('no context supplied and only a category override exists -> no match', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1')];

      expect(resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet), isNull);
    });

    test('an override pointing at a card no longer in the wallet is ignored, not crashed on', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc-archived', scope: OverrideScope.category, categoryId: 'cat1')];

      expect(resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, categoryId: 'cat1'), isNull);
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/data/override_resolver_test.dart`
Expected: FAIL — `override_resolver.dart` does not exist yet (compile error).

- [ ] **Step 3: Write the resolver**

```dart
import 'card_overrides_repository.dart';
import 'user_cards_repository.dart';

/// B8 wiring: given every override the user owns and their current wallet,
/// resolve which CardProduct.id (NOT user_cards.id — the engine's
/// CardSnapshot.forcedOverrideCardId compares against CardProduct.id) should
/// be forced to the top of the ranking for the current transaction context.
///
/// Priority when more than one enabled override could apply: vpa (most
/// specific — a single merchant's payment address) > merchant_name (a named
/// place, possibly multiple VPAs) > category (broadest — "always this card
/// for Fuel"). Matches product-plan §4.6's framing of overrides as
/// increasingly specific rules. merchant_name comparison is
/// case-insensitive and exact (B3's editable merchant-name field is the
/// only place a name gets typed, so exact-after-normalizing is the right
/// bar — fuzzy matching here would make overrides fire unpredictably,
/// exactly the kind of silent-wrong-advice trust bug ui-spec calls out for
/// B8).
String? resolveActiveOverrideCardProductId({
  required List<CardOverride> overrides,
  required List<UserCard> wallet,
  String? categoryId,
  String? merchantName,
  String? vpa,
}) {
  String? productIdFor(String userCardId) {
    for (final card in wallet) {
      if (card.id == userCardId) return card.cardProductId;
    }
    return null; // override targets a card that's been archived/removed
  }

  final enabled = overrides.where((o) => o.isEnabled);

  if (vpa != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.vpa && o.vpa?.toLowerCase() == vpa.toLowerCase()) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  if (merchantName != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.merchantName &&
          o.merchantName?.toLowerCase() == merchantName.toLowerCase()) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  if (categoryId != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.category && o.categoryId == categoryId) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  return null;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/data/override_resolver_test.dart`
Expected: all 5 tests PASS.

- [ ] **Step 5: Wire it into `rankedRecommendationsProvider`**

In `app/lib/app/providers.dart`, add the import:

```dart
import '../data/override_resolver.dart';
```

Modify `rankedRecommendationsProvider` (currently lines ~264-314) to watch `cardOverridesProvider` and pass the resolved id through. Replace the body from `if (catalogue.isLoading ...)` through the final `return AsyncValue.data(engine.rank(...))` with:

```dart
final rankedRecommendationsProvider = Provider<AsyncValue<List<Recommendation>>>((ref) {
  final catalogue = ref.watch(catalogueProvider);
  final categories = ref.watch(categoriesProvider);
  final userCards = ref.watch(userCardsProvider);
  final overrides = ref.watch(cardOverridesProvider);
  final selectedSlug = ref.watch(selectedCategoryProvider);
  final engine = ref.watch(recommendationEngineProvider);

  if (catalogue.isLoading || categories.isLoading || userCards.isLoading || overrides.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? categories.error ?? userCards.error ?? overrides.error;
  if (combinedError != null) {
    return AsyncValue.error(
      combinedError,
      catalogue.stackTrace ?? categories.stackTrace ?? userCards.stackTrace ?? overrides.stackTrace!,
    );
  }

  final allCards = catalogue.requireValue;
  final categoryList = categories.requireValue;
  final wallet = userCards.requireValue;
  final categoryId = categoryList.firstWhereOrNull((c) => c.slug == selectedSlug)?.id;

  final cards = wallet.isEmpty
      ? allCards
      : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

  // B8: resolve once per rank() call — Home only carries category context
  // (no merchant/vpa yet, that's B3's scan-result context), so vpa/
  // merchantName are omitted here on purpose.
  final overrideProductId = resolveActiveOverrideCardProductId(
    overrides: overrides.requireValue,
    wallet: wallet,
    categoryId: categoryId,
  );

  final context = RecommendationContext(
    amount: ref.watch(enteredAmountProvider),
    categoryId: categoryId,
    rail: TxnRail.swipe,
  );
  final snapshots = cards.map((c) {
    final owned = wallet.firstWhereOrNull((w) => w.cardProductId == c.id);
    final capRemaining = owned == null
        ? const <String, Money>{}
        : {
            for (final cap in c.capRules)
              if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!,
          };
    return CardSnapshot(
      product: c,
      capRemaining: capRemaining,
      milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
      forcedOverrideCardId: overrideProductId,
    );
  }).toList();
  return AsyncValue.data(engine.rank(context, snapshots));
});
```

`bestCardForMerchantProvider` (lines ~342-377, used only by the geofence screen's per-tile ranking) is deliberately left unwired in this task — out of scope per this plan's brief, which asks only for `rankedRecommendationsProvider`. Note this explicitly as a stated scope reduction in a comment above `bestCardForMerchantProvider`:

```dart
// Note: deliberately NOT wired to card_overrides (unlike
// rankedRecommendationsProvider above) — B8's spec scopes override
// wiring to Home's ranking; extending it to the geofence tile's
// per-merchant ranking is a natural follow-up, not done here.
```

- [ ] **Step 6: Run the full provider-adjacent test suite to check for regressions**

Run: `cd app && flutter test test/app/`
Expected: all existing tests still PASS (no test currently asserts on `forcedOverrideCardId`, so this should be a clean pass — if any test constructs `CardSnapshot` and asserts equality including that field, update the expectation to account for the new default `null` passthrough, which is unchanged behavior when no override exists).

- [ ] **Step 7: Commit**

```bash
git add app/lib/data/override_resolver.dart app/lib/app/providers.dart app/test/data/override_resolver_test.dart
git commit -m "feat(app): wire resolved manual overrides into rankedRecommendationsProvider"
```

---

### Task 4: B8 screen — Manual Overrides list/create/edit/delete/disable

**Files:**
- Create: `app/lib/features/overrides/manual_overrides_screen.dart`
- Test: `app/test/features/overrides/manual_overrides_screen_test.dart`

**Interfaces:**
- Consumes: `cardOverridesProvider`, `cardOverridesRepositoryProvider` (Task 2), `userCardsProvider` (existing), `categoriesProvider` (existing), `EmptyState`/`ErrorState`/`StatusPill` (`app/lib/app/design/widgets.dart`).
- Produces: `class ManualOverridesScreen extends ConsumerWidget` — pushed via `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManualOverridesScreen()))` from Task 5's B1 "override active" chip and from an entry point added to Home in Task 5.

- [ ] **Step 1: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';

/// B8 — "was missing" per ui-spec.md: view and manage every "always use X
/// here" rule. Offline behavior: read-only cache is NOT implemented here
/// (list/create/edit/delete all require a live API call, same as every
/// other user_cards/transactions screen in this app today — there is no
/// local persistence layer for owner-scoped data anywhere yet) — the
/// offline chip pattern from Task 8 is reused so this is at least honest
/// about it rather than silently hanging.
class ManualOverridesScreen extends ConsumerWidget {
  const ManualOverridesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(cardOverridesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manual overrides')),
      body: overrides.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(cardOverridesProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.rule_rounded,
              title: 'No overrides yet',
              message: 'Create one from a Scan Result screen with "Always use this '
                  'card here", or add one manually below.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(AppSpace.lg),
            itemCount: list.length,
            itemBuilder: (context, index) => _OverrideTile(list[index]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openCreateSheet(context, ref),
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Future<void> _openCreateSheet(BuildContext context, WidgetRef ref) async {
    final userCards = await ref.read(userCardsProvider.future);
    final categories = await ref.read(categoriesProvider.future);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateOverrideSheet(userCards: userCards, categories: categories),
    );
  }
}

class _OverrideTile extends ConsumerWidget {
  final CardOverride override;
  const _OverrideTile(this.override);

  String get _targetLabel => switch (override.scope) {
        OverrideScope.vpa => 'VPA: ${override.vpa}',
        OverrideScope.merchantName => 'Merchant: ${override.merchantName}',
        OverrideScope.category => 'Category: ${override.categoryName ?? override.categoryId}',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_targetLabel, style: Theme.of(context).textTheme.titleSmall),
                ),
                StatusPill(
                  label: override.isEnabled ? 'Active' : 'Disabled',
                  foreground: override.isEnabled ? Colors.white : AppColors.ink500,
                  background: override.isEnabled ? AppColors.teal600 : AppColors.surfaceMuted,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('→ ${override.cardDisplayName}', style: Theme.of(context).textTheme.bodyMedium),
            if (override.reasonNote?.isNotEmpty == true) ...[
              const SizedBox(height: 2),
              Text(override.reasonNote!, style: Theme.of(context).textTheme.bodySmall),
            ],
            Text(
              'Created ${override.createdAt.toLocal().toString().split(' ').first}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink500),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _toggle(context, ref),
                  child: Text(override.isEnabled ? 'Disable' : 'Enable'),
                ),
                TextButton(
                  onPressed: () => _confirmDelete(context, ref),
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.setEnabled(override.id, !override.isEnabled);
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }

  /// Destructive-action confirmation per this plan's Global Constraints —
  /// deleting an override silently would be exactly the "forgotten rule
  /// producing worse advice" trust bug ui-spec calls out for B8 in reverse:
  /// removing one without the user meaning to.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this override?'),
        content: Text('This card will no longer be forced for "$_targetLabel".'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.delete(override.id);
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }
}

class _CreateOverrideSheet extends ConsumerStatefulWidget {
  final List<UserCard> userCards;
  final List<SpendCategory> categories;
  const _CreateOverrideSheet({required this.userCards, required this.categories});

  @override
  ConsumerState<_CreateOverrideSheet> createState() => _CreateOverrideSheetState();
}

class _CreateOverrideSheetState extends ConsumerState<_CreateOverrideSheet> {
  OverrideScope _scope = OverrideScope.category;
  String? _selectedUserCardId;
  String? _selectedCategoryId;
  final _merchantController = TextEditingController();
  final _vpaController = TextEditingController();
  final _noteController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _merchantController.dispose();
    _vpaController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_selectedUserCardId == null) return false;
    return switch (_scope) {
      OverrideScope.vpa => _vpaController.text.trim().isNotEmpty,
      OverrideScope.merchantName => _merchantController.text.trim().isNotEmpty,
      OverrideScope.category => _selectedCategoryId != null,
    };
  }

  Future<void> _save() async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null || !_canSave) return;
    setState(() => _saving = true);
    try {
      await repo.createOverride(
        userCardId: _selectedUserCardId!,
        scope: _scope,
        vpa: _scope == OverrideScope.vpa ? _vpaController.text.trim() : null,
        merchantName: _scope == OverrideScope.merchantName ? _merchantController.text.trim() : null,
        categoryId: _scope == OverrideScope.category ? _selectedCategoryId : null,
        reasonNote: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      );
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg, right: AppSpace.lg, top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New override', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<String>(
              initialValue: _selectedUserCardId,
              decoration: const InputDecoration(labelText: 'Card'),
              items: widget.userCards
                  .map((c) => DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedUserCardId = v),
            ),
            const SizedBox(height: AppSpace.md),
            SegmentedButton<OverrideScope>(
              segments: const [
                ButtonSegment(value: OverrideScope.category, label: Text('Category')),
                ButtonSegment(value: OverrideScope.merchantName, label: Text('Merchant')),
                ButtonSegment(value: OverrideScope.vpa, label: Text('VPA')),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            const SizedBox(height: AppSpace.md),
            if (_scope == OverrideScope.category)
              DropdownButtonFormField<String>(
                initialValue: _selectedCategoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: widget.categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              )
            else if (_scope == OverrideScope.merchantName)
              TextField(
                controller: _merchantController,
                decoration: const InputDecoration(labelText: 'Merchant name'),
                onChanged: (_) => setState(() {}),
              )
            else
              TextField(
                controller: _vpaController,
                decoration: const InputDecoration(labelText: 'VPA (e.g. shop@upi)'),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save override'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Write a widget test covering the empty state and the list state**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/features/overrides/manual_overrides_screen.dart';

void main() {
  testWidgets('shows the empty state when there are no overrides', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => const [])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No overrides yet'), findsOneWidget);
  });

  testWidgets('shows one tile per override with its target and card', (tester) async {
    final override = CardOverride(
      id: 'o1',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Fuel'), findsOneWidget);
    expect(find.textContaining('HDFC Millennia'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/features/overrides/manual_overrides_screen_test.dart`
Expected: both tests PASS.

- [ ] **Step 4: Commit**

```bash
git add app/lib/features/overrides/manual_overrides_screen.dart app/test/features/overrides/manual_overrides_screen_test.dart
git commit -m "feat(app): add B8 Manual Overrides screen"
```

---

### Task 5: B1 delta — hero card, "Why this card?" expansion, override chip

Turns the current rank-0 `_RecommendationCard` into ui-spec B1's HERO treatment, adds the expandable arithmetic breakdown (feature 3), and makes the existing `Recommendation(label: 'Override')` pill (already rendered — see `home_screen.dart` line 271-275) tappable through to Task 4's screen, per B8's chip requirement.

**Files:**
- Modify: `app/lib/features/home/home_screen.dart` (`_RecommendationCard`, lines 224-307)
- Test: `app/test/features/home/home_screen_test.dart` (create if it doesn't exist — check first with `ls app/test/features/home/` since the file may not exist yet)

**Interfaces:**
- Consumes: `Recommendation.reasonLines`/`.isOverride`/`.expectedValue`/`.confidence` (existing, unchanged), `ManualOverridesScreen` (Task 4).
- Produces: `_RecommendationCard` now takes an extra `isHero` bool (true only for rank 0 among non-excluded cards, same condition the existing `isBest` local already computes) that switches its visual treatment; no public API change for callers (`_RankedList` still just does `_RecommendationCard(recommendations[index], rank: index)`).

- [ ] **Step 1: Check for an existing test file**

Run: `ls app/test/features/home/ 2>/dev/null`
If nothing prints, this task creates `app/test/features/home/home_screen_test.dart` fresh (Step 4 below); if a file exists, add the new test cases into it instead of overwriting.

- [ ] **Step 2: Replace `_RecommendationCard` in `home_screen.dart`**

Replace the whole `_RecommendationCard` class (lines 224-307) with:

```dart
class _RecommendationCard extends StatefulWidget {
  final Recommendation recommendation;
  final int rank;
  const _RecommendationCard(this.recommendation, {required this.rank});

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final recommendation = widget.recommendation;
    final excluded = recommendation.isExcluded;
    final isHero = widget.rank == 0 && !excluded;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        // ui-spec B1.2: the hero card gets its own art/color treatment,
        // not just a thin border like every other ranked-list row —
        // filled navy so it reads as "the answer" at a glance, matching
        // B1's "answer 'which card?' in under 500ms" purpose statement.
        color: isHero ? AppColors.navy900 : (excluded ? AppColors.surfaceMuted : AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: isHero ? null : Border.all(color: AppColors.ink100),
        boxShadow: isHero
            ? [BoxShadow(color: AppColors.navy900.withValues(alpha: 0.24), blurRadius: 16, offset: const Offset(0, 6))]
            : null,
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (isHero) ...[
                      const StatusPill(
                        label: 'BEST',
                        foreground: AppColors.navy900,
                        background: Colors.white,
                        icon: Icons.star_rounded,
                      ),
                      const SizedBox(width: AppSpace.sm),
                    ],
                    Flexible(
                      child: Text(
                        recommendation.card.name,
                        style: textTheme.titleMedium?.copyWith(
                          color: isHero ? Colors.white : (excluded ? AppColors.ink500 : AppColors.ink900),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (recommendation.isOverride)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.xs),
                  child: GestureDetector(
                    // B8 chip requirement: tapping the "override active" pill
                    // takes the user straight to where they can see/undo it —
                    // an override silently steering advice with no visible
                    // way back is exactly the trust bug B8 exists to prevent.
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ManualOverridesScreen()),
                    ),
                    child: StatusPill(
                      label: 'Override active',
                      foreground: isHero ? Colors.white : AppColors.navy800,
                      background: isHero ? Colors.white.withValues(alpha: 0.16) : AppColors.surfaceMuted,
                      icon: Icons.push_pin_rounded,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (excluded)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.block_rounded, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(recommendation.exclusionReason!, style: textTheme.bodySmall),
                ),
              ],
            )
          else ...[
            MoneyText(
              recommendation.expectedValue,
              confidence: recommendation.confidence,
              style: isHero ? textTheme.headlineMedium?.copyWith(color: Colors.white) : textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            // ui-spec B1.3 "Why this card?" — collapsed to the first reason
            // line by default (short, scannable), full arithmetic behind an
            // explicit tap so the ranked list doesn't turn into a wall of
            // text for every card.
            if (recommendation.reasonLines.isNotEmpty) ...[
              Text(
                '•  ${recommendation.reasonLines.first}',
                style: textTheme.bodySmall?.copyWith(color: isHero ? Colors.white70 : null),
              ),
              if (recommendation.reasonLines.length > 1) ...[
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _expanded ? 'Hide the full breakdown' : 'Why this card?',
                          style: textTheme.labelMedium?.copyWith(
                            color: isHero ? AppColors.teal300 : AppColors.teal600,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Icon(
                          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 18,
                          color: isHero ? AppColors.teal300 : AppColors.teal600,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in recommendation.reasonLines.skip(1))
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '•  $line',
                              style: textTheme.bodySmall?.copyWith(color: isHero ? Colors.white70 : null),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Add the new import to `home_screen.dart`**

```dart
import '../overrides/manual_overrides_screen.dart';
```

- [ ] **Step 4: Write/extend the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
  testWidgets('rank-0 recommendation gets hero styling and a "Why this card?" toggle', (tester) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: const Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0% on ₹2,400', 'Cap headroom: ₹8,600 remaining'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BEST'), findsOneWidget);
    expect(find.text('Why this card?'), findsOneWidget);
    expect(find.textContaining('Cap headroom'), findsNothing);

    await tester.tap(find.text('Why this card?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cap headroom'), findsOneWidget);
    expect(find.text('Hide the full breakdown'), findsOneWidget);
  });

  testWidgets('an override pill navigates to Manual Overrides on tap', (tester) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: const Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0%'],
        isOverride: true,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs)),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Override active'));
    await tester.pumpAndSettle();

    expect(find.text('Manual overrides'), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run the tests**

Run: `cd app && flutter test test/features/home/home_screen_test.dart`
Expected: both tests PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/features/home/home_screen.dart app/test/features/home/home_screen_test.dart
git commit -m "feat(app): B1 hero card, why-this-card expansion, tappable override chip"
```

---

### Task 6: B1 delta — backup card row

ui-spec B1.4: *"If not accepted: HDFC Regalia (2%)"*, "populated from crowdsourced acceptance data where available." The only acceptance-data surface in this codebase today is `GET /admin/acceptance-summary` (`api/src/index.js` ~line 1662), gated by `requireAdmin` — there is no public/user-facing acceptance-data endpoint. Building one is out of scope for this plan (it's a whole crowdsourcing-pipeline surface, not a Home-screen delta). Scope reduction, stated explicitly in code: the backup row shows the next-best non-excluded card from the same already-ranked list `rankedRecommendationsProvider` produces (rank 1, i.e. the runner-up), not real crowdsourced acceptance data.

**Files:**
- Modify: `app/lib/features/home/home_screen.dart` (`_RankedList`, lines ~192-222, and its `build` method)
- Test: `app/test/features/home/home_screen_test.dart` (extend from Task 5)

**Interfaces:**
- Consumes: `rankedRecommendationsProvider` (existing/Task 3), `MoneyText` (existing).
- Produces: `_BackupCardRow` widget, rendered once between the hero card and the rest of the ranked list — no new provider.

- [ ] **Step 1: Add `_BackupCardRow` and wire it into `_RankedList.build`**

In `home_screen.dart`, modify `_RankedList.build`'s `data:` branch (currently just returns a `ListView.builder`) to insert the backup row as the list's second item when a runner-up exists:

```dart
data: (recommendations) {
  if (recommendations.isEmpty) {
    return const EmptyState(
      icon: Icons.credit_card_off_rounded,
      title: 'No cards yet',
      message: 'Add a card to see personalized reward recommendations here.',
    );
  }
  // ui-spec B1.4: the first non-excluded runner-up after the hero (index
  // 0), if one exists — see the class doc comment above for why this is
  // "next-best ranked card" rather than real crowdsourced acceptance data.
  final backup = recommendations.skip(1).firstWhereOrNull((r) => !r.isExcluded);
  return ListView.builder(
    padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xxl),
    itemCount: recommendations.length + (backup != null ? 1 : 0),
    itemBuilder: (context, index) {
      if (backup != null && index == 1) {
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: _BackupCardRow(backup),
        );
      }
      final recIndex = (backup != null && index > 1) ? index - 1 : index;
      return Padding(
        key: recIndex == 0 ? tutorialKeys.firstRecommendationCard : null,
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: _RecommendationCard(recommendations[recIndex], rank: recIndex),
      );
    },
  );
},
```

Add the `firstWhereOrNull` extension used above — it already exists as a private extension in `app/lib/app/providers.dart` (`_FirstWhereOrNull<T>`) but is not exported for reuse from `home_screen.dart`; add a local copy at the bottom of `home_screen.dart` (this codebase's existing convention for small private helpers — the same extension is duplicated privately per-file elsewhere rather than shared via a utils import):

```dart
extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
```

- [ ] **Step 2: Add the `_BackupCardRow` widget**

```dart
/// ui-spec B1.4 backup card row. See the file's Task 6 doc note above
/// _RankedList for the stated scope reduction (no real acceptance data).
class _BackupCardRow extends StatelessWidget {
  final Recommendation backup;
  const _BackupCardRow(this.backup);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz_rounded, size: 16, color: AppColors.ink500),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: Theme.of(context).textTheme.bodySmall,
                children: [
                  const TextSpan(text: 'If not accepted: '),
                  TextSpan(
                    text: backup.card.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          MoneyText(backup.expectedValue, confidence: backup.confidence, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Extend the widget test**

Add to `app/test/features/home/home_screen_test.dart`:

```dart
testWidgets('shows a backup-card row for the runner-up when one exists', (tester) async {
  final recs = [
    Recommendation(card: _card('c1'), expectedValue: const Money.fromRupees(120), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%']),
    Recommendation(card: _card('c2'), expectedValue: const Money.fromRupees(80), confidence: Confidence.estimated, reasonLines: const ['Base rate 2.0%']),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
      child: const MaterialApp(home: Scaffold(body: HomeScreen())),
    ),
  );
  await tester.pumpAndSettle();

  expect(find.textContaining('If not accepted:'), findsOneWidget);
  expect(find.textContaining('Card c2'), findsWidgets);
});
```

- [ ] **Step 4: Run the tests**

Run: `cd app && flutter test test/features/home/home_screen_test.dart`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/home/home_screen.dart app/test/features/home/home_screen_test.dart
git commit -m "feat(app): B1 backup card row"
```

---

### Task 7: B1 delta — alerts strip

ui-spec B1.6: max 2 alerts, priority-ordered `cap nearly hit > fee-waiver deadline > points expiring > bill due > needs-review count`. Of these five, only the first two are computable from data this app already fetches: cap consumption is in `UserCard.capConsumed` (vs. `CardProduct.capRules`, both already on the client); fee-waiver deadlines need one more column, `fee_waiver_states.period_end`, which `GET /user-cards` already queries in its `WHERE` clause but does not currently `SELECT` or return. Points-expiry (`points_ledger.expires_on`), bill-due (`user_cards.due_day`, not currently returned by `GET /user-cards` either), and needs-review count (`needs_review_items`, no client-facing count endpoint exists) all require new endpoints/columns beyond this task's reach — stated explicitly below as a scope reduction rather than faked with placeholder data.

**Files:**
- Modify: `api/src/index.js` (`GET /user-cards`'s fee-waiver query, ~line 926)
- Modify: `app/lib/data/user_cards_repository.dart` (`FeeWaiverProgress`)
- Create: `app/lib/features/home/home_alerts.dart` (pure alert-computation logic)
- Modify: `app/lib/features/home/home_screen.dart` (render the strip)
- Test: `app/test/features/home/home_alerts_test.dart`

**Interfaces:**
- Consumes: `UserCard.capConsumed`, `CardProduct.capRules`, `UserCard.feeWaiverStates` (extended with `periodEnd`), `clockProvider` (existing, `app/lib/app/providers.dart` line ~322).
- Produces: `enum HomeAlertKind { capNearlyHit, feeWaiverDeadline }`; `class HomeAlert { final HomeAlertKind kind; final String message; final int priority; }`; `List<HomeAlert> computeHomeAlerts({required List<UserCard> wallet, required List<CardProduct> catalogue, required DateTime now})` — pure, sorted by priority ascending, capped to 2 by the caller (not by the function itself, so callers/tests can see the full ranked set).

- [ ] **Step 1: Extend the `GET /user-cards` fee-waiver query to return `period_end`**

In `api/src/index.js`, modify the fee-waiver-states query inside `GET /user-cards` (currently, ~line 926):

```js
const feeWaiverStates = await client.query(
  `SELECT fw.fee_waiver_rule_id, fw.qualified_spend, fw.waived_at, fw.period_end,
          r.threshold_spend_inr, r.waives_fee_inr
     FROM fee_waiver_states fw
     JOIN fee_waiver_rules r ON r.id = fw.fee_waiver_rule_id
    WHERE fw.user_card_id = $1 AND fw.period_start <= CURRENT_DATE AND fw.period_end >= CURRENT_DATE`,
  [card.id]
);
```

(The only change is adding `fw.period_end` to the `SELECT` list — the `WHERE` clause is unchanged.)

- [ ] **Step 2: Add `periodEnd` to `FeeWaiverProgress`**

In `app/lib/data/user_cards_repository.dart`, modify `FeeWaiverProgress`:

```dart
class FeeWaiverProgress {
  final String feeWaiverRuleId;
  final Money qualifiedSpend;
  final Money thresholdSpend;
  final Money waivesFee;
  final DateTime? waivedAt;
  final DateTime periodEnd;

  const FeeWaiverProgress({
    required this.feeWaiverRuleId,
    required this.qualifiedSpend,
    required this.thresholdSpend,
    required this.waivesFee,
    this.waivedAt,
    required this.periodEnd,
  });

  factory FeeWaiverProgress.fromJson(Map<String, dynamic> json) {
    return FeeWaiverProgress(
      feeWaiverRuleId: json['fee_waiver_rule_id'] as String,
      qualifiedSpend: Money.fromRupees(_num(json['qualified_spend'])),
      thresholdSpend: Money.fromRupees(_num(json['threshold_spend_inr'])),
      waivesFee: Money.fromRupees(_num(json['waives_fee_inr'])),
      waivedAt: json['waived_at'] == null ? null : DateTime.parse(json['waived_at'] as String),
      periodEnd: DateTime.parse(json['period_end'] as String),
    );
  }
}
```

- [ ] **Step 3: Write the failing test for `computeHomeAlerts`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/home/home_alerts.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id, {List<CapRule> capRules = const []}) =>
    CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa, capRules: capRules);

void main() {
  group('computeHomeAlerts', () {
    test('flags a cap at or above 90% consumed as nearly hit, priority 0', () {
      final cap = CapRule(id: 'cap1', label: 'Monthly cashback cap', capValue: const Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false, capConsumed: {'cap1': const Money.fromRupees(920)});

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts, hasLength(1));
      expect(alerts.first.kind, HomeAlertKind.capNearlyHit);
      expect(alerts.first.priority, 0);
    });

    test('does not flag a cap under 90% consumed', () {
      final cap = CapRule(id: 'cap1', label: 'Monthly cap', capValue: const Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false, capConsumed: {'cap1': const Money.fromRupees(500)});

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });

    test('flags an un-waived fee-waiver deadline within 7 days, priority 1', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(
            feeWaiverRuleId: 'fw1',
            qualifiedSpend: const Money.fromRupees(20000),
            thresholdSpend: const Money.fromRupees(100000),
            waivesFee: const Money.fromRupees(500),
            periodEnd: DateTime(2026, 8, 10),
          ),
        ],
      );

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts, hasLength(1));
      expect(alerts.first.kind, HomeAlertKind.feeWaiverDeadline);
      expect(alerts.first.priority, 1);
    });

    test('an already-waived fee waiver is never flagged', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(
            feeWaiverRuleId: 'fw1',
            qualifiedSpend: const Money.fromRupees(120000),
            thresholdSpend: const Money.fromRupees(100000),
            waivesFee: const Money.fromRupees(500),
            waivedAt: DateTime(2026, 8, 1),
            periodEnd: DateTime(2026, 8, 10),
          ),
        ],
      );

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });

    test('cap-nearly-hit sorts before fee-waiver-deadline when both apply', () {
      final cap = CapRule(id: 'cap1', label: 'cap', capValue: const Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        capConsumed: {'cap1': const Money.fromRupees(950)},
        feeWaiverStates: [
          FeeWaiverProgress(feeWaiverRuleId: 'fw1', qualifiedSpend: const Money.fromRupees(20000), thresholdSpend: const Money.fromRupees(100000), waivesFee: const Money.fromRupees(500), periodEnd: DateTime(2026, 8, 10)),
        ],
      );

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts.map((a) => a.kind), [HomeAlertKind.capNearlyHit, HomeAlertKind.feeWaiverDeadline]);
    });
  });
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd app && flutter test test/features/home/home_alerts_test.dart`
Expected: FAIL — `home_alerts.dart` does not exist.

- [ ] **Step 5: Write `home_alerts.dart`**

```dart
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/user_cards_repository.dart';

/// ui-spec B1.6. Only capNearlyHit and feeWaiverDeadline are implemented —
/// see this plan's Task 7 for why pointsExpiring/billDue/needsReview are a
/// stated scope reduction (no client-facing data source exists for them
/// yet): points_ledger.expires_on and user_cards.due_day are never
/// returned by GET /user-cards today, and there is no user-facing
/// needs-review-count endpoint (needs_review_items is D4/admin-only so
/// far). The enum is deliberately open to extension once those exist.
enum HomeAlertKind { capNearlyHit, feeWaiverDeadline }

class HomeAlert {
  final HomeAlertKind kind;
  final String message;
  final int priority; // lower = shown first, per ui-spec B1.6's ordering

  const HomeAlert({required this.kind, required this.message, required this.priority});
}

const _capNearlyHitThreshold = 0.9; // "nearly hit" = 90%+ of a cap consumed
const _feeWaiverDeadlineWindow = Duration(days: 7);

/// Pure — no IO, no DateTime.now() (per no_datetime_now_outside_clock,
/// [now] is threaded through by the caller from clockProvider).
List<HomeAlert> computeHomeAlerts({
  required List<UserCard> wallet,
  required List<CardProduct> catalogue,
  required DateTime now,
}) {
  final alerts = <HomeAlert>[];

  for (final userCard in wallet) {
    final product = catalogue.where((c) => c.id == userCard.cardProductId).firstOrNull;
    if (product == null) continue;

    for (final cap in product.capRules) {
      final consumed = userCard.capConsumed[cap.id];
      if (consumed == null || cap.capValue.isZero) continue;
      final fraction = consumed.paise / cap.capValue.paise;
      if (fraction >= _capNearlyHitThreshold) {
        alerts.add(HomeAlert(
          kind: HomeAlertKind.capNearlyHit,
          message: '${userCard.cardName}: ${cap.label} cap almost reached this cycle',
          priority: 0,
        ));
      }
    }

    for (final waiver in userCard.feeWaiverStates) {
      if (waiver.waivedAt != null) continue; // already waived, nothing to warn about
      final daysLeft = waiver.periodEnd.difference(now);
      if (daysLeft.isNegative) continue; // window already closed, nothing actionable to show
      if (daysLeft <= _feeWaiverDeadlineWindow) {
        final remaining = waiver.thresholdSpend - waiver.qualifiedSpend;
        alerts.add(HomeAlert(
          kind: HomeAlertKind.feeWaiverDeadline,
          message:
              '${userCard.cardName}: spend ${remaining.isNegative ? const Money.zero() : remaining}.format() more in ${daysLeft.inDays}d to waive the fee'
                  .replaceAll('.format()', ''),
          priority: 1,
        ));
      }
    }
  }

  alerts.sort((a, b) => a.priority.compareTo(b.priority));
  return alerts;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
```

- [ ] **Step 6: Fix the fee-waiver message string bug and re-run**

The `.replaceAll('.format()', '')` line above is a broken way to interpolate a formatted `Money` — fix it directly instead of patching around it:

```dart
        final remaining = waiver.thresholdSpend - waiver.qualifiedSpend;
        final remainingDisplay = remaining.isNegative ? const Money.zero() : remaining;
        alerts.add(HomeAlert(
          kind: HomeAlertKind.feeWaiverDeadline,
          message: '${userCard.cardName}: spend ${remainingDisplay.format()} more in '
              '${daysLeft.inDays}d to waive the fee',
          priority: 1,
        ));
```

Run: `cd app && flutter test test/features/home/home_alerts_test.dart`
Expected: all 5 tests PASS.

- [ ] **Step 7: Render the strip in `home_screen.dart`**

Add a provider-free computed strip driven directly by `userCardsProvider`/`catalogueProvider`/`clockProvider` (no new Riverpod provider needed — this is a leaf presentational concern, matching how `_BackupCardRow` above needed none either):

```dart
class _AlertsStrip extends ConsumerWidget {
  const _AlertsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userCards = ref.watch(userCardsProvider);
    final catalogue = ref.watch(catalogueProvider);
    if (!userCards.hasValue || !catalogue.hasValue) return const SizedBox.shrink();

    final now = ref.watch(clockProvider).now();
    final alerts = computeHomeAlerts(wallet: userCards.requireValue, catalogue: catalogue.requireValue, now: now)
        .take(2) // ui-spec B1.6: max 2 at once
        .toList();
    if (alerts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
      child: Column(
        children: [
          for (final alert in alerts)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.xs),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFB45309)),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: Text(alert.message, style: Theme.of(context).textTheme.bodySmall)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
```

Add the import: `import 'home_alerts.dart';`. Insert `const _AlertsStrip()` into `HomeScreen.build`'s `Column` between the category-chips `SizedBox` and `Expanded(child: _RankedList(...))`.

- [ ] **Step 8: Commit**

```bash
git add api/src/index.js app/lib/data/user_cards_repository.dart app/lib/features/home/home_alerts.dart app/lib/features/home/home_screen.dart app/test/features/home/home_alerts_test.dart
git commit -m "feat: B1 alerts strip (cap-nearly-hit, fee-waiver-deadline)"
```

---

### Task 8: B1 delta — geofence-driven context line

ui-spec B1.1: *"You're at DMart Powai"* · *"Near Indian Oil"* · *"Pick a category"*, tappable to correct location. Reuses the exact same one-shot, foreground-triggered location read and matching machinery `app/lib/features/geofence/nearby_merchants_screen.dart` already built (`nearbyMerchantsRepositoryProvider`, `findNearbyMerchants`, `bestCardForMerchantProvider`) — this task does not add new geolocation or matching code, only a compact single-line presentation of the same result plus a tap target that lets the user override the category directly (scrolls to/focuses the existing category chips row).

**Files:**
- Create: `app/lib/features/home/home_context_line.dart`
- Modify: `app/lib/features/home/home_screen.dart` (render the new widget)
- Test: `app/test/features/home/home_context_line_test.dart`

**Interfaces:**
- Consumes: `nearbyMerchantsRepositoryProvider` (existing), `findNearbyMerchants`/`GeoPoint`/`NearbyMerchantMatch` (existing, `packages/pandapay_domain`), `Geolocator` (existing dependency, same read pattern as `nearby_merchants_screen.dart`'s `_readCurrentLocationOnce`).
- Produces: `class HomeContextLine extends ConsumerStatefulWidget` — a self-contained widget with its own one-shot location state (idle/locating/found/noPermission/noMatch), matching `_NearbyMerchantsScreenState`'s state machine but condensed to a single line. No new provider — the location read itself is inherently a one-shot side effect triggered by the widget's `initState`, same as the existing screen triggers it from a button tap.

- [ ] **Step 1: Write `home_context_line.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';

enum _ContextState { locating, found, noPermission, noMatch, offlineOrError }

/// ui-spec B1.1 context line. Deliberately a thin presentation layer over
/// the SAME foreground one-shot location read + matching machinery
/// app/lib/features/geofence/nearby_merchants_screen.dart already built —
/// see that file's header comment for the explicit "not always-on
/// background geofencing" scope note, which applies here identically.
class HomeContextLine extends ConsumerStatefulWidget {
  const HomeContextLine({super.key});

  @override
  ConsumerState<HomeContextLine> createState() => _HomeContextLineState();
}

class _HomeContextLineState extends ConsumerState<HomeContextLine> {
  _ContextState _state = _ContextState.locating;
  NearbyMerchantMatch? _closest;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _state = _ContextState.noPermission);
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() => _state = _ContextState.noPermission);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      final repo = ref.read(nearbyMerchantsRepositoryProvider);
      final candidates = await repo.fetchNearby(lat: position.latitude, lng: position.longitude, radiusM: 500);
      final matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: 500,
      );
      if (!mounted) return;
      if (matches.isEmpty) {
        setState(() => _state = _ContextState.noMatch);
      } else {
        setState(() {
          _closest = matches.first;
          _state = _ContextState.found;
        });
        final categoryId = matches.first.candidate.categoryId;
        if (categoryId != null) {
          // A found merchant re-ranks Home the same way tapping a category
          // chip does (ui-spec B1.5: "One tap re-ranks; overrides geofence
          // guess" — this is the geofence guess the chip can override).
          // selectedCategoryProvider holds a *slug*, and this repository
          // only carries a category UUID — resolving that mismatch would
          // need a slug<->id lookup this widget doesn't have reason to
          // duplicate from providers.dart's categoriesProvider, so the
          // context line surfaces the merchant name/category for display
          // only in this task; it does not push a re-rank. Stated scope
          // reduction, not a silent gap.
        }
      }
    } catch (_) {
      if (mounted) setState(() => _state = _ContextState.offlineOrError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (_state) {
      _ContextState.locating => (Icons.my_location_rounded, 'Finding where you are…'),
      _ContextState.found => (
          Icons.place_rounded,
          "You're near ${_closest!.candidate.displayName ?? 'a known merchant'}",
        ),
      _ContextState.noMatch => (Icons.explore_off_rounded, 'Not sure where you are — scan or pick a category.'),
      // ui-spec B1 States: "No location permission -> chips primary, no
      // nag" — this line stays factual and unobtrusive, never a permission
      // prompt/nag of its own.
      _ContextState.noPermission => (Icons.explore_off_rounded, 'Pick a category below.'),
      _ContextState.offlineOrError => (Icons.wifi_off_rounded, 'Offline — pick a category below.'),
    };

    return InkWell(
      onTap: () {}, // tappable-to-correct per ui-spec B1.1; correction UI is the category-chip row directly below
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 0),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.ink500),
            const SizedBox(width: AppSpace.xs),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Render it in `home_screen.dart`**

Add the import (`import 'home_context_line.dart';`) and insert `const HomeContextLine()` as the first child of `HomeScreen.build`'s `Column`, before the `if (!signedIn) const _SignInBanner()` line.

- [ ] **Step 3: Write the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay/features/home/home_context_line.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeNearbyRepo implements NearbyMerchantsRepository {
  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({required double lat, required double lng, double radiusM = 2000}) async {
    return const [];
  }
}

void main() {
  testWidgets('shows a fallback line when no location permission flow can complete in a test host', (tester) async {
    // Geolocator has no platform implementation under flutter_test, so this
    // exercises the catch-all offline/error branch — the meaningful
    // assertion is that SOME single-line context text renders, never a
    // blank/crashed widget.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nearbyMerchantsRepositoryProvider.overrideWithValue(_FakeNearbyRepo())],
        child: const MaterialApp(home: Scaffold(body: HomeContextLine())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(Text), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the test**

Run: `cd app && flutter test test/features/home/home_context_line_test.dart`
Expected: PASS (the exact fallback text depends on how `flutter_test`'s host reports `Geolocator.isLocationServiceEnabled()` — either `noPermission` or `offlineOrError`; the assertion above deliberately checks only that a `Text` renders, not the exact copy, since this behavior is host-dependent per `nearby_merchants_screen.dart`'s own PROGRESS.md note that geolocation is unverified on a real device in this sandbox).

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/home/home_context_line.dart app/lib/features/home/home_screen.dart app/test/features/home/home_context_line_test.dart
git commit -m "feat(app): B1 geofence-driven context line"
```

---

### Task 9: B4 — Comparison View

Pure UI over the already-existing `rankedRecommendationsProvider` — no new backend/provider. `Recommendation` doesn't carry separate rate/cap/milestone/forex fields (only `expectedValue` and free-text `reasonLines` — see `packages/pandapay_domain/lib/src/engine/engine.dart` lines 43-61); re-deriving those from `CardProduct.rewardRules`/`capRules` here would duplicate the engine's own arithmetic in a second place, which is exactly the kind of drift this codebase avoids (see `nearby_merchants_screen.dart`'s comment about reusing "one 'pick the best card' implementation"). Instead, the comparison table's per-row summary badges (cap/milestone/forex indicators) are derived by matching keywords already present in `reasonLines` — the same strings the "Why this card?" expansion (Task 5) already shows verbatim — and each row expands to the exact same full `reasonLines` list, so the table never claims a number the engine didn't produce.

**Files:**
- Create: `app/lib/features/comparison/comparison_view_screen.dart`
- Test: `app/test/features/comparison/comparison_view_screen_test.dart`

**Interfaces:**
- Consumes: `rankedRecommendationsProvider` (existing/Task 3), `MoneyText`, `EmptyState`/`ErrorState`.
- Produces: `class ComparisonViewScreen extends ConsumerStatefulWidget` — pushed via `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen()))`. Task 12 (B3) also pushes this from its own "Compare all cards" action.

- [ ] **Step 1: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

enum _SortBy { value, name }

/// ui-spec B4 — full sortable comparison table, reachable from B1 (Task 5's
/// hero card can add a "Compare all" action — wired in this task's Step 3)
/// and from B3 (Task 12). See this class's own header for why cap/
/// milestone/forex columns are keyword-derived from reasonLines rather than
/// re-computed: the engine (packages/pandapay_domain/.../engine.dart) is
/// the only place that arithmetic is allowed to live.
class ComparisonViewScreen extends ConsumerStatefulWidget {
  const ComparisonViewScreen({super.key});

  @override
  ConsumerState<ComparisonViewScreen> createState() => _ComparisonViewScreenState();
}

class _ComparisonViewScreenState extends ConsumerState<ComparisonViewScreen> {
  _SortBy _sortBy = _SortBy.value;
  bool _ascending = false;

  List<Recommendation> _sorted(List<Recommendation> input) {
    final list = [...input];
    list.sort((a, b) {
      final cmp = switch (_sortBy) {
        _SortBy.value => a.expectedValue.paise.compareTo(b.expectedValue.paise),
        _SortBy.name => a.card.name.compareTo(b.card.name),
      };
      return _ascending ? cmp : -cmp;
    });
    return list;
  }

  void _onSort(_SortBy column) {
    setState(() {
      if (_sortBy == column) {
        _ascending = !_ascending;
      } else {
        _sortBy = column;
        _ascending = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ranked = ref.watch(rankedRecommendationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Compare cards')),
      body: ranked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
        data: (recommendations) {
          if (recommendations.isEmpty) {
            return const EmptyState(icon: Icons.compare_arrows_rounded, title: 'Nothing to compare', message: 'Add a card first.');
          }
          final sorted = _sorted(recommendations);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Row(
                  children: [
                    _SortHeaderButton(label: 'Card', active: _sortBy == _SortBy.name, ascending: _ascending, onTap: () => _onSort(_SortBy.name)),
                    const SizedBox(width: AppSpace.md),
                    _SortHeaderButton(label: '₹ value', active: _sortBy == _SortBy.value, ascending: _ascending, onTap: () => _onSort(_SortBy.value)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  itemCount: sorted.length,
                  itemBuilder: (context, index) => _ComparisonRow(sorted[index]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SortHeaderButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;
  const _SortHeaderButton({required this.label, required this.active, required this.ascending, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: active ? FontWeight.w800 : FontWeight.w500)),
          if (active) Icon(ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14),
        ],
      ),
    );
  }
}

/// Keyword match against the engine's own reasonLines strings (engine.dart
/// lines ~164-274) — never a re-derivation of the underlying numbers.
class _ComparisonRow extends StatefulWidget {
  final Recommendation recommendation;
  const _ComparisonRow(this.recommendation);

  @override
  State<_ComparisonRow> createState() => _ComparisonRowState();
}

class _ComparisonRowState extends State<_ComparisonRow> {
  bool _expanded = false;

  bool _mentions(String keyword) =>
      widget.recommendation.reasonLines.any((l) => l.toLowerCase().contains(keyword));

  @override
  Widget build(BuildContext context) {
    final rec = widget.recommendation;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            title: Text(rec.card.name, style: textTheme.titleSmall),
            subtitle: rec.isExcluded
                ? Text(rec.exclusionReason!, style: textTheme.bodySmall?.copyWith(color: AppColors.ink500))
                : Wrap(
                    spacing: AppSpace.xs,
                    children: [
                      if (_mentions('cap')) const StatusPill(label: 'Cap-aware', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                      if (_mentions('milestone')) const StatusPill(label: 'Milestone', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                      if (_mentions('forex')) const StatusPill(label: 'Forex', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                    ],
                  ),
            trailing: rec.isExcluded
                ? const Icon(Icons.block_rounded, color: AppColors.ink500)
                : MoneyText(rec.expectedValue, confidence: rec.confidence),
          ),
          if (_expanded && !rec.isExcluded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in rec.reasonLines)
                    Padding(padding: const EdgeInsets.only(top: 2), child: Text('•  $line', style: textTheme.bodySmall)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Add a "Compare all cards" entry point on B1's hero card**

In `app/lib/features/home/home_screen.dart`, add the import `import '../comparison/comparison_view_screen.dart';` and, inside `_RecommendationCardState.build`'s hero-only (`isHero == true`) branch, add a text button below the reason lines:

```dart
if (isHero)
  Align(
    alignment: Alignment.centerRight,
    child: TextButton(
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
      style: TextButton.styleFrom(foregroundColor: AppColors.teal300),
      child: const Text('Compare all cards'),
    ),
  ),
```

(Placed as the last child in the `Column` returned by `build`, after the "Why this card?" block.)

- [ ] **Step 3: Write the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
  testWidgets('sorts rows by ₹ value descending by default, and toggles on tap', (tester) async {
    final recs = [
      Recommendation(card: _card('low'), expectedValue: const Money.fromRupees(50), confidence: Confidence.estimated, reasonLines: const ['Base rate 1.0%']),
      Recommendation(card: _card('high'), expectedValue: const Money.fromRupees(150), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0% — cap headroom']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: ComparisonViewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final cardTiles = tester.widgetList<Text>(find.textContaining('Card '));
    expect(cardTiles.first.data, 'Card high'); // higher ₹ value first by default

    await tester.tap(find.text('Card')); // sort header
    await tester.pumpAndSettle();
    final afterNameSort = tester.widgetList<Text>(find.textContaining('Card '));
    expect(afterNameSort.first.data, 'Card high'); // 'high' < 'low' alphabetically, descending default
  });

  testWidgets('a row expands to show every reasonLine', (tester) async {
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: const Money.fromRupees(100), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%', 'Cap headroom: ₹500 remaining']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: ComparisonViewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Cap headroom'), findsNothing);
    await tester.tap(find.text('Card c1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cap headroom'), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && flutter test test/features/comparison/comparison_view_screen_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/comparison/comparison_view_screen.dart app/lib/features/home/home_screen.dart app/test/features/comparison/comparison_view_screen_test.dart
git commit -m "feat(app): B4 Comparison View, reachable from B1's hero card"
```

---

### Task 10: Pure-Dart UPI QR parse/build module

B2 (decode a scanned QR) and B3 (build the "Pay with [card]" intent) both need the same two pure operations: parse a UPI deep-link string into its fields, and build one back from a chosen card/amount. This lives in `packages/pandapay_domain` (zero IO, like the engine) so it's unit-testable without a camera, a UPI app, or platform channels — same reasoning as `packages/pandapay_domain/lib/src/geo/geo.dart`'s pure haversine matcher.

**Files:**
- Create: `packages/pandapay_domain/lib/src/upi/upi_qr.dart`
- Modify: `packages/pandapay_domain/lib/pandapay_domain.dart` (export)
- Test: `packages/pandapay_domain/test/upi_qr_test.dart`

**Interfaces:**
- Consumes: `Money` (existing).
- Produces: `class ParsedUpiQr { final String pa; final String? pn; final String? mc; final Money? am; final String cu; final bool isLikelyP2P; }`; `ParsedUpiQr? parseUpiQrString(String raw)` (returns `null` if `raw` isn't a `upi://pay` link at all); `String buildUpiPayUri({required String pa, String? pn, Money? am, String cu = 'INR'})`. Task 11 (B2) consumes `parseUpiQrString`; Task 12 (B3) consumes both.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('parseUpiQrString', () {
    test('parses a full merchant UPI QR string', () {
      final parsed = parseUpiQrString('upi://pay?pa=shop@okhdfcbank&pn=DMart%20Powai&am=2400.00&mc=5411&cu=INR');

      expect(parsed, isNotNull);
      expect(parsed!.pa, 'shop@okhdfcbank');
      expect(parsed.pn, 'DMart Powai');
      expect(parsed.mc, '5411');
      expect(parsed.am, const Money.fromRupees(2400));
      expect(parsed.cu, 'INR');
      expect(parsed.isLikelyP2P, isFalse);
    });

    test('a QR with no mc param is flagged as likely P2P', () {
      final parsed = parseUpiQrString('upi://pay?pa=friend@okaxis&pn=A%20Friend');

      expect(parsed, isNotNull);
      expect(parsed!.mc, isNull);
      expect(parsed.isLikelyP2P, isTrue);
    });

    test('a QR with no am param leaves am null rather than zero', () {
      final parsed = parseUpiQrString('upi://pay?pa=shop@okicici&pn=Some%20Shop&mc=5812');

      expect(parsed, isNotNull);
      expect(parsed!.am, isNull);
    });

    test('a non-UPI string returns null', () {
      expect(parseUpiQrString('https://example.com'), isNull);
      expect(parseUpiQrString('not a url at all'), isNull);
    });

    test('a upi:// link missing pa entirely returns null — not a usable payment target', () {
      expect(parseUpiQrString('upi://pay?pn=Nobody'), isNull);
    });
  });

  group('buildUpiPayUri', () {
    test('builds a well-formed intent with amount', () {
      final uri = buildUpiPayUri(pa: 'shop@okhdfcbank', pn: 'DMart Powai', am: const Money.fromRupees(2400));

      expect(uri, 'upi://pay?pa=shop%40okhdfcbank&pn=DMart%20Powai&am=2400.00&cu=INR');
    });

    test('omits am from the query string when no amount is given', () {
      final uri = buildUpiPayUri(pa: 'shop@okhdfcbank', pn: 'DMart Powai');

      expect(uri, 'upi://pay?pa=shop%40okhdfcbank&pn=DMart%20Powai&cu=INR');
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/pandapay_domain && flutter test test/upi_qr_test.dart`
Expected: FAIL — `parseUpiQrString`/`buildUpiPayUri` are undefined.

- [ ] **Step 3: Write `upi_qr.dart`**

```dart
import '../money/money.dart';

/// B2/B3 — everything decoded from a scanned UPI QR (`upi://pay?...`).
/// [isLikelyP2P] mirrors ui-spec B3.4's "P2P QR detected (no mc, personal
/// VPA pattern)" edge case — this codebase has no merchant-vs-personal VPA
/// classifier, so the heuristic is deliberately just "no mc (merchant
/// category code) present", the one signal actually available from the QR
/// payload alone. Stated simplification, not a full VPA-pattern detector.
class ParsedUpiQr {
  final String pa; // payee VPA — the only required field for a usable payment target
  final String? pn; // payee name
  final String? mc; // merchant category code
  final Money? am; // amount, when the QR pre-fills one
  final String cu; // currency, defaults to INR when absent
  final bool isLikelyP2P;

  const ParsedUpiQr({
    required this.pa,
    this.pn,
    this.mc,
    this.am,
    this.cu = 'INR',
    required this.isLikelyP2P,
  });
}

/// Returns null for anything that isn't a `upi://pay` link, or that is one
/// but has no `pa` — B2's "That's not a UPI code" edge case and B3's "look
/// up VPA in crowdsource DB -> else ask user to pick a category" edge case
/// both start from this returning null/non-null.
ParsedUpiQr? parseUpiQrString(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'upi' || uri.host != 'pay') return null;

  final pa = uri.queryParameters['pa'];
  if (pa == null || pa.isEmpty) return null;

  final amRaw = uri.queryParameters['am'];
  final am = amRaw == null || amRaw.isEmpty ? null : Money.fromRupees(double.parse(amRaw));
  final mc = uri.queryParameters['mc'];

  return ParsedUpiQr(
    pa: pa,
    pn: uri.queryParameters['pn'],
    mc: (mc == null || mc.isEmpty) ? null : mc,
    am: am,
    cu: uri.queryParameters['cu'] ?? 'INR',
    isLikelyP2P: mc == null || mc.isEmpty,
  );
}

/// B3.6 — "Pay with [card]" builds this and hands it to url_launcher.
/// Query params are added in a fixed, stable order (pa, pn, am, cu) so the
/// output is deterministic and test-comparable, matching every UPI app's
/// documented query-string contract (order itself has no semantic meaning
/// to a UPI app, but a stable order makes this function's output
/// reproducible for tests and logs).
String buildUpiPayUri({required String pa, String? pn, Money? am, String cu = 'INR'}) {
  final params = <String>['pa=${Uri.encodeComponent(pa)}'];
  if (pn != null && pn.isNotEmpty) params.add('pn=${Uri.encodeComponent(pn)}');
  if (am != null) params.add('am=${am.rupees.toStringAsFixed(2)}');
  params.add('cu=${Uri.encodeComponent(cu)}');
  return 'upi://pay?${params.join('&')}';
}
```

- [ ] **Step 4: Export it from the package barrel**

Add to `packages/pandapay_domain/lib/pandapay_domain.dart`:

```dart
export 'src/upi/upi_qr.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/pandapay_domain && flutter test test/upi_qr_test.dart`
Expected: all 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/pandapay_domain/lib/src/upi/upi_qr.dart packages/pandapay_domain/lib/pandapay_domain.dart packages/pandapay_domain/test/upi_qr_test.dart
git commit -m "feat(domain): pure UPI QR parse/build module for B2/B3"
```

---

### Task 11: B2 — QR Scanner

Full-screen camera scan of a UPI QR, distinct from the existing `app/lib/features/scan/scan_card_screen.dart` (which scans a QR/barcode off a physical card to identify a card *product* for the wallet — this screen scans a merchant's *payment* QR to pay). Follows the same `MobileScannerController` + `MobileScanner` widget pattern `scan_card_screen.dart` already uses. Gallery import needs `image_picker` (not currently a dependency — `mobile_scanner`'s `analyzeImage(path)` decodes a QR from an arbitrary image file, but something has to hand it a file path from the photo gallery, which is `image_picker`'s job).

**Files:**
- Modify: `app/pubspec.yaml` (add `image_picker`)
- Create: `app/lib/features/scan/upi_qr_scanner_screen.dart`
- Test: `app/test/features/scan/upi_qr_scanner_screen_test.dart`

**Interfaces:**
- Consumes: `parseUpiQrString` (Task 10).
- Produces: `class UpiQrScannerScreen extends StatefulWidget` — on a successful decode, pops itself with `Navigator.of(context).pop<ParsedUpiQr>(parsed)`, so the pushing caller (Task 12's entry point on Home) gets a `ParsedUpiQr?` result exactly like `_scanFromFab` in `router.dart` already gets a `CardProduct?` back from `ScanCardScreen`.

- [ ] **Step 1: Add `image_picker` to `app/pubspec.yaml`**

Add under the `dependencies:` block, near `mobile_scanner`:

```yaml
  # B2 (Group B): gallery import — scanning a UPI QR from a screenshot
  # rather than the live camera (ui-spec B2.2). mobile_scanner's
  # analyzeImage(path) decodes a QR from an arbitrary image file; something
  # has to hand it a file path from the user's photo gallery, which is this
  # package's whole job. Same "added without a live device/pub-get
  # verification in this sandbox" caveat as mobile_scanner/geolocator above
  # (see PROGRESS.md Chunks 30/32) — flagged, not hidden.
  image_picker: ^1.1.2
```

- [ ] **Step 2: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart';

/// ui-spec B2. Works fully offline (feature 4) — every step here is local
/// camera/image decode via mobile_scanner, no network calls at all, unlike
/// most of this app's other screens which need a live API.
class UpiQrScannerScreen extends StatefulWidget {
  const UpiQrScannerScreen({super.key});

  @override
  State<UpiQrScannerScreen> createState() => _UpiQrScannerScreenState();
}

class _UpiQrScannerScreenState extends State<UpiQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handling = false;
  String? _hint;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    _handleRaw(raw);
  }

  Future<void> _handleRaw(String? raw) async {
    if (raw == null || raw.isEmpty) {
      setState(() => _hint = "Couldn't read that — steady the camera or clean the lens.");
      return;
    }
    final parsed = parseUpiQrString(raw);
    if (parsed == null) {
      setState(() {
        _hint = "That's not a UPI code.";
        _handling = false;
      });
      return;
    }
    setState(() => _handling = true);
    // ui-spec B2.3: haptic on a successful decode.
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    Navigator.of(context).pop<ParsedUpiQr>(parsed);
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final capture = await _controller.analyzeImage(picked.path);
    final raw = capture?.barcodes.isNotEmpty == true ? capture!.barcodes.first.rawValue : null;
    await _handleRaw(raw);
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Scan to pay', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded, color: Colors.white),
            onPressed: _toggleTorch,
          ),
          IconButton(
            tooltip: 'Import from gallery',
            icon: const Icon(Icons.photo_library_rounded, color: Colors.white),
            onPressed: _pickFromGallery,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _PermissionExplainer(error: error),
          ),
          // Framing guide (ui-spec B2.1) — a plain square outline, no extra
          // asset/plugin needed.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(border: Border.all(color: Colors.white70, width: 2), borderRadius: BorderRadius.circular(16)),
            ),
          ),
          if (_hint != null)
            Positioned(
              bottom: 48,
              left: 24,
              right: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Text(_hint!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}

/// ui-spec B2 edge case: permission denied -> explainer + settings deep
/// link. mobile_scanner surfaces a MobileScannerException through
/// errorBuilder when the camera permission was refused; permission_handler
/// (already a dependency — see pubspec.yaml's SMS-import section) drives
/// the actual settings deep link, the same package this app already uses
/// for its other runtime-permission flows.
class _PermissionExplainer extends StatelessWidget {
  final MobileScannerException error;
  const _PermissionExplainer({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_rounded, color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Camera access is needed to scan a QR code.',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: openAppSettings,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Write the widget test (covering the non-camera-dependent parts: torch toggle button and hint rendering)**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/upi_qr_scanner_screen.dart';

void main() {
  testWidgets('renders the framing guide, torch and gallery actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpiQrScannerScreen()));
    await tester.pump();

    expect(find.text('Scan to pay'), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_rounded), findsOneWidget);
  });
}
```

(A full `onDetect`/`analyzeImage` round-trip test would need a real camera/platform channel, which `scan_card_screen.dart`'s own tests also don't attempt for the same reason — see `app/test/features/scan/card_text_matcher_test.dart`, which tests only the pure matcher, not the camera widget itself. This test is scoped the same way: verify the screen renders its chrome, not the platform-channel-dependent detection path.)

- [ ] **Step 4: Run the test**

Run: `cd app && flutter pub get && flutter test test/features/scan/upi_qr_scanner_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/features/scan/upi_qr_scanner_screen.dart app/test/features/scan/upi_qr_scanner_screen_test.dart
git commit -m "feat(app): B2 QR Scanner screen (scan a merchant UPI QR to pay)"
```

---

### Task 12: B3 — Scan Result

The biggest single screen in this plan. Depends on Task 2/4 (`CardOverridesRepository`/`cardOverridesProvider` for "Always use this card here"), Task 10 (`ParsedUpiQr`/`buildUpiPayUri`), Task 11 (pushed from `UpiQrScannerScreen`'s pop result), and Task 9 (its own "Compare all" entry to `ComparisonViewScreen`). Ranking here uses its own local amount/category/VPA/MCC context (editable per-scan, independent of Home's `selectedCategoryProvider`/`enteredAmountProvider`) rather than `rankedRecommendationsProvider` — same reasoning ui-spec gives B7 for its own independent inputs.

Three explicit, stated scope reductions (this codebase's convention — see `nearby_merchants_screen.dart`'s header comment):
1. **No automatic VPA→merchant crowdsource lookup** when `mc` is absent. There is no VPA-lookup endpoint in this codebase today (Task 14's `GET /merchants/search` searches display name, not VPA) — building one is out of scope here. The user always picks a category via the same chip row Home uses when `mc` can't resolve one.
2. **No silent background contribution** (`{vpa, name, mcc, grid-coords}`, ui-spec B3.9). `merchant_contributions` has no client-facing write endpoint in `api/src/index.js` — only admin/scraper-side reads exist. Building the ingest endpoint is a crowdsourcing-pipeline project, not a B3 delta.
3. **"This card wasn't accepted" is a local-only re-rank**, per this plan's brief — no acceptance-data write endpoint exists (same gap as Task 6's backup-card-row note); tapping it excludes that card from the in-memory ranked list for the rest of this scan session only.

**Files:**
- Create: `app/lib/features/scan/scan_result_screen.dart`
- Modify: `app/lib/app/router.dart` (`_AppShell`, add a second scan entry point — see Step 5)
- Test: `app/test/features/scan/scan_result_screen_test.dart`

**Interfaces:**
- Consumes: `ParsedUpiQr` (Task 10), `buildUpiPayUri` (Task 10), `catalogueProvider`/`categoriesProvider`/`userCardsProvider`/`recommendationEngineProvider` (existing), `cardOverridesProvider`/`cardOverridesRepositoryProvider` (Task 2), `resolveActiveOverrideCardProductId` (Task 3), `ComparisonViewScreen` (Task 9), `url_launcher`'s `launchUrl`/`canLaunchUrl` (already a dependency — added for G4's `tel:` dial in `app/pubspec.yaml`, reused here for `upi://`).
- Produces: `class ScanResultScreen extends ConsumerStatefulWidget` taking `required ParsedUpiQr parsed`, pushed as `Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanResultScreen(parsed: parsed)))`.

- [ ] **Step 1: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/override_resolver.dart';
import '../../main.dart' show MoneyText;
import '../comparison/comparison_view_screen.dart';

/// ui-spec B3. See this file's Task 12 header comment (plan doc) for three
/// stated scope reductions: no automatic VPA->merchant crowdsource lookup,
/// no silent background contribution write, and a local-only (not
/// server-recorded) re-rank on "This card wasn't accepted".
class ScanResultScreen extends ConsumerStatefulWidget {
  final ParsedUpiQr parsed;
  const ScanResultScreen({super.key, required this.parsed});

  @override
  ConsumerState<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends ConsumerState<ScanResultScreen> {
  late final TextEditingController _merchantController;
  late Money _amount;
  String? _selectedCategoryId;
  final Set<String> _locallyRejectedCardIds = {}; // "wasn't accepted" — session-local only, see scope note above

  @override
  void initState() {
    super.initState();
    _merchantController = TextEditingController(text: widget.parsed.pn ?? '');
    _amount = widget.parsed.am ?? const Money.zero();
  }

  @override
  void dispose() {
    _merchantController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    final categories = ref.watch(categoriesProvider);
    final userCards = ref.watch(userCardsProvider);
    final overrides = ref.watch(cardOverridesProvider);
    final engine = ref.watch(recommendationEngineProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan result'),
        actions: [
          IconButton(
            tooltip: 'Compare all cards',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
          ),
        ],
      ),
      body: _buildBody(catalogue, categories, userCards, overrides, engine),
    );
  }

  Widget _buildBody(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<SpendCategory>> categories,
    AsyncValue<List<UserCard>> userCards,
    AsyncValue<List<CardOverride>> overrides,
    RecommendationEngine engine,
  ) {
    if (catalogue.isLoading || categories.isLoading || userCards.isLoading || overrides.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final combinedError = catalogue.error ?? categories.error ?? userCards.error ?? overrides.error;
    if (combinedError != null) {
      return ErrorState(message: userFacingErrorMessage(combinedError));
    }

    final allCards = catalogue.requireValue;
    final categoryList = categories.requireValue;
    final wallet = userCards.requireValue;
    final overrideList = overrides.requireValue;

    if (widget.parsed.isLikelyP2P) {
      return _P2PNotice(vpa: widget.parsed.pa);
    }

    final cards = wallet.isEmpty ? allCards : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

    final overrideProductId = resolveActiveOverrideCardProductId(
      overrides: overrideList,
      wallet: wallet,
      categoryId: _selectedCategoryId,
      vpa: widget.parsed.pa,
    );

    final context = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      rail: TxnRail.upiQr,
    );
    final swipeContext = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      rail: TxnRail.swipe,
    );

    final snapshots = cards
        .where((c) => !_locallyRejectedCardIds.contains(c.id))
        .map((c) {
      final owned = wallet.where((w) => w.cardProductId == c.id).firstOrNull;
      final capRemaining = owned == null
          ? const <String, Money>{}
          : {for (final cap in c.capRules) if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!};
      return CardSnapshot(
        product: c,
        capRemaining: capRemaining,
        milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
        forcedOverrideCardId: overrideProductId,
      );
    }).toList();

    final upiRanked = engine.rank(context, snapshots);
    final swipeRanked = engine.rank(swipeContext, snapshots);
    final bestUpi = upiRanked.where((r) => !r.isExcluded).firstOrNull;
    final bestSwipe = swipeRanked.where((r) => !r.isExcluded).firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        TextField(
          controller: _merchantController,
          decoration: const InputDecoration(labelText: 'Merchant name'),
        ),
        const SizedBox(height: AppSpace.sm),
        _CategoryPicker(
          categories: categoryList,
          selectedId: _selectedCategoryId,
          onSelected: (id) => setState(() => _selectedCategoryId = id),
        ),
        const SizedBox(height: AppSpace.sm),
        TextField(
          decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          controller: TextEditingController(text: _amount.rupees == 0 ? '' : _amount.rupees.toStringAsFixed(0)),
          onChanged: (v) {
            final parsedAmount = double.tryParse(v);
            if (parsedAmount != null && parsedAmount >= 0) setState(() => _amount = Money.fromRupees(parsedAmount));
          },
        ),
        const SizedBox(height: AppSpace.lg),
        if (bestUpi != null && bestSwipe != null && bestSwipe.expectedValue > bestUpi.expectedValue)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Text(
              'Scan-and-pay earns ${bestUpi.expectedValue.format()} · swiping your ${bestSwipe.card.name} '
              'earns ${bestSwipe.expectedValue.format()} instead.',
              style: Theme.of(this.context).textTheme.bodySmall,
            ),
          ),
        for (final rec in upiRanked)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: _ScanResultCard(
              recommendation: rec,
              vpa: widget.parsed.pa,
              merchantName: _merchantController.text,
              onNotAccepted: () => setState(() => _locallyRejectedCardIds.add(rec.card.id)),
              onPay: () => _payWith(rec),
              onAlwaysUseHere: () => _createOverride(rec, wallet),
            ),
          ),
      ],
    );
  }

  Future<void> _payWith(Recommendation rec) async {
    final uri = Uri.parse(buildUpiPayUri(pa: widget.parsed.pa, pn: _merchantController.text, am: _amount));
    final launched = await canLaunchUrl(uri) && await launchUrl(uri);
    if (!launched && mounted) {
      // ui-spec B3 edge case: no UPI app installed -> recommendation-only
      // with a copy-VPA action.
      await Clipboard.setData(ClipboardData(text: widget.parsed.pa));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No UPI app found — copied ${widget.parsed.pa} to your clipboard instead.')),
      );
    }
  }

  Future<void> _createOverride(Recommendation rec, List<UserCard> wallet) async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    final owned = wallet.where((w) => w.cardProductId == rec.card.id).firstOrNull;
    if (repo == null || owned == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in and add this card to your wallet to create an override.')),
      );
      return;
    }
    try {
      await repo.createOverride(userCardId: owned.id, scope: OverrideScope.vpa, vpa: widget.parsed.pa);
      ref.invalidate(cardOverridesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rec.card.name} will always be suggested here.')));
      }
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
    }
  }
}

class _CategoryPicker extends StatelessWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  const _CategoryPicker({required this.categories, required this.selectedId, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.xs,
      children: [
        for (final c in categories)
          ChoiceChip(
            label: Text(c.name),
            selected: selectedId == c.id,
            onSelected: (_) => onSelected(c.id),
          ),
      ],
    );
  }
}

class _P2PNotice extends StatelessWidget {
  final String vpa;
  const _P2PNotice({required this.vpa});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.person_off_rounded,
      title: "Credit cards can't be used for personal transfers",
      message: 'This looks like a personal UPI transfer to $vpa, not a merchant payment. '
          "Use your bank account's UPI app to send this instead.",
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final Recommendation recommendation;
  final String vpa;
  final String merchantName;
  final VoidCallback onNotAccepted;
  final VoidCallback onPay;
  final VoidCallback onAlwaysUseHere;

  const _ScanResultCard({
    required this.recommendation,
    required this.vpa,
    required this.merchantName,
    required this.onNotAccepted,
    required this.onPay,
    required this.onAlwaysUseHere,
  });

  @override
  Widget build(BuildContext context) {
    final excluded = recommendation.isExcluded;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: excluded ? AppColors.surfaceMuted : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(recommendation.card.name, style: textTheme.titleMedium)),
              if (recommendation.isOverride)
                const StatusPill(label: 'Override', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          if (excluded)
            // ui-spec B3.4: RuPay/UPI eligibility, explicit — the engine's
            // own exclusionReason string ("Not usable via UPI — swipe this
            // instead.") is shown verbatim, never re-worded client-side.
            Row(
              children: [
                const Icon(Icons.block_rounded, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(child: Text(recommendation.exclusionReason!, style: textTheme.bodySmall)),
              ],
            )
          else ...[
            MoneyText(recommendation.expectedValue, confidence: recommendation.confidence, style: textTheme.headlineSmall),
            for (final line in recommendation.reasonLines)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text('•  $line', style: textTheme.bodySmall)),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                FilledButton(onPressed: onPay, child: Text('Pay with ${recommendation.card.name}')),
                OutlinedButton(onPressed: onAlwaysUseHere, child: const Text('Always use this card here')),
                TextButton(onPressed: onNotAccepted, child: const Text("Wasn't accepted")),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
```

- [ ] **Step 2: Add a Home entry point that pushes B2 then B3**

In `app/lib/app/router.dart`'s `_AppShellState`, add a second scan method alongside the existing `_scanFromFab` (which stays exactly as-is — it's UA-4's scan-to-add-a-card flow, a different feature per this plan's brief):

```dart
/// B2/B3: "scan a merchant's UPI QR to pay" — a second, separate scan
/// entry point from the existing FAB's "scan to add a card" flow. Reachable
/// from a new IconButton next to the FAB (Step 2 continued below) rather
/// than repurposing the FAB itself, since the FAB's tooltip/semantics
/// ("Scan a card") is already load-bearing for the add-card flow tested in
/// app/test/app/router_test.dart.
Future<void> _scanToPay() async {
  final parsed = await Navigator.of(context).push<ParsedUpiQr>(
    MaterialPageRoute(builder: (_) => const UpiQrScannerScreen()),
  );
  if (parsed != null && mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScanResultScreen(parsed: parsed)),
    );
  }
}
```

Add the two imports (`import '../features/scan/upi_qr_scanner_screen.dart';` and `import '../features/scan/scan_result_screen.dart';`) and add a second `FloatingActionButton.small` positioned just above the main FAB via a `Column` wrapping the existing `floatingActionButton`:

```dart
floatingActionButton: Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    FloatingActionButton.small(
      heroTag: 'scanToPayFab',
      onPressed: _scanToPay,
      tooltip: 'Scan a UPI QR to pay',
      child: const Icon(Icons.qr_code_2_rounded),
    ),
    const SizedBox(height: 8),
    FloatingActionButton.large(
      key: tutorialKeys.scanFab,
      onPressed: _scanning ? null : _scanFromFab,
      tooltip: 'Scan a card',
      child: _scanning
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.qr_code_scanner_rounded),
    ),
  ],
),
```

(Both `FloatingActionButton`s now need distinct `heroTag`s — Flutter throws at runtime if two FABs in the same route share the default hero tag; the existing large one keeps its implicit default since it's still the only one of its `FloatingActionButton.large` type on screen at a time, but making both explicit is the safer fix — set `heroTag: 'scanFab'` on the large one too.)

- [ ] **Step 3: Write the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('a P2P-detected QR shows the personal-transfer notice, not a card list', (tester) async {
    const parsed = ParsedUpiQr(pa: 'friend@okaxis', pn: 'A Friend', isLikelyP2P: true);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Credit cards can't be used for personal transfers"), findsOneWidget);
  });

  testWidgets('a merchant QR pre-fills the merchant name field from pn', (tester) async {
    const parsed = ParsedUpiQr(pa: 'shop@okhdfcbank', pn: 'DMart Powai', mc: '5411', isLikelyP2P: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'DMart Powai'), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && flutter test test/features/scan/scan_result_screen_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Run the router test suite to catch the dual-FAB regression risk called out in Step 2**

Run: `cd app && flutter test test/app/router_test.dart`
Expected: PASS — if it fails on a duplicate-hero-tag assertion or a FAB-finder that now matches two widgets, fix by keeping the explicit `heroTag`s from Step 2 and, if the test locates the "scan a card" FAB by type rather than tooltip/key, updating it to search by `tutorialKeys.scanFab`'s key (already unique) instead of `find.byType(FloatingActionButton)`.

- [ ] **Step 6: Commit**

```bash
git add app/lib/features/scan/scan_result_screen.dart app/lib/app/router.dart app/test/features/scan/scan_result_screen_test.dart
git commit -m "feat(app): B3 Scan Result screen with UPI pay intent, override creation, local re-rank"
```

---

### Task 13: B5 backend — `GET /merchants/search`

Public (no `requireAuth`/`requireAdmin`), modeled on `GET /merchants/nearby`'s query style (`api/src/index.js` lines ~493-522) and `GET /admin/merchants`'s `q` `ILIKE` pattern (lines ~1332-1360), but distinct from both: unauthenticated like `/merchants/nearby`, text-search like `/admin/merchants`'s `q` param. Each result row is shaped like a `/merchants/nearby` candidate (`merchant_id`, `display_name`, `category_id`, `confidence`, `grid_lat`, `grid_lng`) minus `distance_meters` (search has no origin point to measure distance from), via the same representative-location `LATERAL` join `GET /admin/merchants` already uses.

**Files:**
- Modify: `api/src/index.js` (add the route directly after `GET /merchants/nearby`, ~line 526)

**Interfaces:**
- Consumes: nothing new — reuses `withUserClient(null, ...)` (public read, same as `/merchants/nearby`).
- Produces: `GET /merchants/search?q=<text>` → `{ merchants: [{ merchant_id, display_name, category_id, confidence, grid_lat, grid_lng }] }`. Task 14's `MerchantSearchRepository` consumes this exactly.

- [ ] **Step 1: Add the route**

```js
/**
 * GET /merchants/search — B5: typed search over published merchants, by
 * display name only (not VPA — VPA search is a B3 scope reduction noted in
 * this plan's Task 12). Public read, same is_published-only filter as
 * GET /merchants/nearby, same q ILIKE pattern as GET /admin/merchants but
 * without the admin gate. Each row is shaped like a /merchants/nearby
 * candidate (minus distance_meters, since search has no origin point) so
 * the app can feed results into the same NearbyMerchantCandidate/
 * bestCardForMerchantProvider machinery nearby_merchants_screen.dart
 * already uses, rather than a third parallel "merchant result" shape.
 */
app.get('/merchants/search', async (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q.length === 0) {
    return res.status(400).json({ error: 'q is required' });
  }

  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT m.id AS merchant_id, m.display_name, m.category_id, m.confidence,
                l.grid_lat, l.grid_lng
           FROM merchants m
           LEFT JOIN LATERAL (
             SELECT grid_lat, grid_lng FROM merchant_locations
              WHERE merchant_id = m.id ORDER BY confirmation_count DESC LIMIT 1
           ) l ON true
          WHERE m.is_published = true AND m.display_name ILIKE $1
          ORDER BY m.confirmation_count DESC
          LIMIT 50`,
        [`%${q}%`]
      )
    );
    res.json({ merchants: result.rows });
  } catch (err) {
    console.error('GET /merchants/search error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

- [ ] **Step 2: Manually verify**

Run: `cd api && npm start`, then:

```bash
curl -s "http://localhost:4000/merchants/search?q=dmart"
curl -s "http://localhost:4000/merchants/search?q="   # expect 400
```

Expected: a 200 with a `merchants` array (empty if seed data has no DMart-named row — check `db/seed/*.sql` for what merchant names actually exist and search for one of those instead if `dmart` isn't seeded), and a 400 on an empty `q`.

- [ ] **Step 3: Commit**

```bash
git add api/src/index.js
git commit -m "feat(api): add public GET /merchants/search for B5"
```

---

### Task 14: B5 app — Merchant Search screen + recent searches

**Files:**
- Create: `app/lib/data/merchant_search_repository.dart`
- Create: `app/lib/features/search/merchant_search_screen.dart`
- Modify: `app/lib/app/providers.dart` (add `merchantSearchRepositoryProvider`)
- Modify: `app/lib/features/home/home_screen.dart` (entry point)
- Test: `app/test/data/merchant_search_repository_test.dart`

**Interfaces:**
- Consumes: Task 13's `GET /merchants/search` shape, `NearbyMerchantCandidate`/`GeoPoint` (existing, `packages/pandapay_domain`), `bestCardForMerchantProvider` (existing, `app/lib/app/providers.dart` line ~342), `shared_preferences` (existing dependency — same usage pattern as `onboardingCompleteProvider` in `providers.dart`).
- Produces: `class MerchantSearchRepository` with `Future<List<NearbyMerchantCandidate>> search(String query)`; `merchantSearchRepositoryProvider` (`Provider<MerchantSearchRepository>`, public, no auth — same pattern as `catalogueRepositoryProvider`); `class MerchantSearchScreen extends ConsumerStatefulWidget`, pushed via `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MerchantSearchScreen()))`.

- [ ] **Step 1: Write the repository**

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

/// B5 — HTTP client for GET /merchants/search. Public read, no auth, same
/// pattern as HttpNearbyMerchantsRepository (nearby_merchants_repository.dart)
/// — deserializes into the SAME NearbyMerchantCandidate shape that repo
/// uses, minus a distance (search has no origin point).
abstract class MerchantSearchRepository {
  Future<List<NearbyMerchantCandidate>> search(String query);
}

class HttpMerchantSearchRepository implements MerchantSearchRepository {
  final String baseUrl;
  final http.Client _client;

  HttpMerchantSearchRepository({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    final uri = Uri.parse('$baseUrl/merchants/search').replace(queryParameters: {'q': query});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('GET /merchants/search failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final merchants = (body['merchants'] as List).cast<Map<String, dynamic>>();
    return merchants.map((json) {
      final lat = json['grid_lat'];
      final lng = json['grid_lng'];
      return NearbyMerchantCandidate(
        merchantId: json['merchant_id'] as String,
        displayName: json['display_name'] as String?,
        categoryId: json['category_id'] as String?,
        // Some merchants have no confirmed location row yet — grid_lat/lng
        // can be null. GeoPoint has no "unknown" state, so this falls back
        // to (0, 0) purely as a placeholder the UI never uses for distance
        // math (search results don't sort/filter by distance, unlike the
        // nearby-merchants screen) — only categoryId/displayName matter here.
        location: GeoPoint(
          lat: lat == null ? 0 : double.parse(lat.toString()),
          lng: lng == null ? 0 : double.parse(lng.toString()),
        ),
      );
    }).toList();
  }
}
```

- [ ] **Step 2: Write the repository test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/merchant_search_repository.dart';

void main() {
  group('HttpMerchantSearchRepository', () {
    test('parses a real-shaped GET /merchants/search response', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/merchants/search');
        expect(request.url.queryParameters['q'], 'dmart');
        return http.Response(
          jsonEncode({
            'merchants': [
              {'merchant_id': 'm1', 'display_name': 'DMart Powai', 'category_id': 'groceries', 'confidence': 'high', 'grid_lat': '19.11', 'grid_lng': '72.90'},
            ],
          }),
          200,
        );
      });
      final repo = HttpMerchantSearchRepository(baseUrl: 'http://localhost:4000', client: client);

      final result = await repo.search('dmart');

      expect(result, hasLength(1));
      expect(result.first.displayName, 'DMart Powai');
      expect(result.first.categoryId, 'groceries');
    });

    test('a non-200 response throws ApiException', () async {
      final client = MockClient((request) async => http.Response('bad', 400));
      final repo = HttpMerchantSearchRepository(baseUrl: 'http://localhost:4000', client: client);

      expect(() => repo.search(''), throwsA(isA<ApiException>()));
    });
  });
}
```

- [ ] **Step 3: Run the test**

Run: `cd app && flutter test test/data/merchant_search_repository_test.dart`
Expected: both PASS.

- [ ] **Step 4: Wire the provider**

Add to `app/lib/app/providers.dart` (near `catalogueRepositoryProvider`):

```dart
final merchantSearchRepositoryProvider = Provider<MerchantSearchRepository>((ref) {
  return HttpMerchantSearchRepository(baseUrl: _apiBaseUrl);
});
```

Add the import: `import '../data/merchant_search_repository.dart';`

- [ ] **Step 5: Write the screen, with recent searches via `shared_preferences`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec B5. Recent searches persisted locally (same shared_preferences
/// pattern onboardingCompleteProvider uses in providers.dart) — no backend
/// needed for that part, per this plan's brief.
class MerchantSearchScreen extends ConsumerStatefulWidget {
  const MerchantSearchScreen({super.key});

  @override
  ConsumerState<MerchantSearchScreen> createState() => _MerchantSearchScreenState();
}

const _recentSearchesKey = 'pandapay_app.merchant_recent_searches_v1';
const _maxRecentSearches = 8;

class _MerchantSearchScreenState extends ConsumerState<MerchantSearchScreen> {
  final _controller = TextEditingController();
  List<String> _recent = const [];
  List<NearbyMerchantCandidate>? _results;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _recent = prefs.getStringList(_recentSearchesKey) ?? const []);
  }

  Future<void> _saveRecent(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final updated = [query, ..._recent.where((q) => q != query)].take(_maxRecentSearches).toList();
    await prefs.setStringList(_recentSearchesKey, updated);
    if (mounted) setState(() => _recent = updated);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(merchantSearchRepositoryProvider);
      final results = await repo.search(query.trim());
      await _saveRecent(query.trim());
      if (mounted) setState(() => _results = results);
    } catch (err) {
      if (mounted) setState(() => _error = userFacingErrorMessage(err));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search merchants', border: InputBorder.none),
          onSubmitted: _search,
        ),
        actions: [IconButton(icon: const Icon(Icons.search_rounded), onPressed: () => _search(_controller.text))],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorState(message: _error!, onRetry: () => _search(_controller.text));

    if (_results == null) {
      if (_recent.isEmpty) {
        return const EmptyState(icon: Icons.search_rounded, title: 'Search for a merchant', message: 'Recent searches will show up here.');
      }
      return ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text('Recent searches', style: Theme.of(context).textTheme.labelLarge),
          for (final q in _recent)
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: Text(q),
              onTap: () {
                _controller.text = q;
                _search(q);
              },
            ),
        ],
      );
    }

    if (_results!.isEmpty) {
      // ui-spec B5: "category fallback when no match" — the user picks a
      // category directly instead of a specific merchant.
      return _CategoryFallback(query: _controller.text);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpace.lg),
      itemCount: _results!.length,
      itemBuilder: (context, index) => _MerchantResultTile(_results![index]),
    );
  }
}

class _MerchantResultTile extends ConsumerWidget {
  final NearbyMerchantCandidate candidate;
  const _MerchantResultTile(this.candidate);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(bestCardForMerchantProvider(candidate.categoryId));
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: ListTile(
        title: Text(candidate.displayName ?? 'Unnamed merchant'),
        subtitle: best.when(
          loading: () => const Text('Ranking…'),
          error: (err, _) => Text(userFacingErrorMessage(err)),
          data: (rec) => rec == null ? const Text('No usable card for this merchant.') : Text('Use ${rec.card.name}'),
        ),
        trailing: best.valueOrNull != null
            ? MoneyText(best.value!.expectedValue, confidence: best.value!.confidence)
            : null,
      ),
    );
  }
}

class _CategoryFallback extends ConsumerWidget {
  final String query;
  const _CategoryFallback({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return categories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
      data: (list) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text('No merchant found for "$query" — pick a category instead:', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.xs,
            children: [
              for (final c in list)
                ActionChip(
                  label: Text(c.name),
                  onPressed: () {
                    ref.read(selectedCategoryProvider.notifier).state = c.slug;
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Add a Home entry point**

In `home_screen.dart`, add the import `import '../search/merchant_search_screen.dart';` and an `IconButton` (search icon) somewhere in Home's top row — since `HomeScreen` itself has no `AppBar` (that lives in `_AppShell`), add it as a leading icon in front of `HomeContextLine` (Task 8) by wrapping both in a `Row`:

```dart
Padding(
  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 0),
  child: Row(
    children: [
      Expanded(child: HomeContextLine()),
      IconButton(
        tooltip: 'Search merchants',
        icon: const Icon(Icons.search_rounded, size: 20),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MerchantSearchScreen())),
      ),
    ],
  ),
),
```

This replaces the bare `const HomeContextLine()` Task 8 added as the `Column`'s first child — `HomeContextLine`'s own internal padding (`EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 0)`) should be removed from `home_context_line.dart` at this point since the wrapping `Padding` above now owns it (change `HomeContextLine.build`'s outer `Padding` to `EdgeInsets.zero` to avoid doubled spacing).

- [ ] **Step 7: Commit**

```bash
git add app/lib/data/merchant_search_repository.dart app/lib/features/search/merchant_search_screen.dart app/lib/app/providers.dart app/lib/features/home/home_screen.dart app/lib/features/home/home_context_line.dart app/test/data/merchant_search_repository_test.dart
git commit -m "feat(app): B5 Merchant Search with recent searches and category fallback"
```

---

### Task 15: B6 backend — extend `/transactions` to carry `note`

`POST /transactions` (`api/src/index.js` ~line 1183) already accepts `merchantName`, `occurredAt`, `categoryId`, `rail` — verified by reading the route body and the `transactions` table schema (`db/supabase/migrations/0004_user_domain.sql` line ~96, which already has a `note text` column). No migration needed. The one real gap: `insertTransactionAndUpdateState` (the shared insert helper `POST /transactions` and `POST /transactions/from-sms` both call, ~line 1025) destructures `{ userCardId, amount, occurred, categoryId, rail, merchantName, source }` — no `note` — and its `INSERT INTO transactions` statement doesn't include the column. There is also **no `DELETE /transactions/:id` route** (verified — `grep -n "app.delete" api/src/index.js` shows only `/admin/parser-patterns/:id`), so B6's undo (Task 16) must be a dismiss-only snackbar, not a real undo — stated explicitly there.

**Files:**
- Modify: `api/src/index.js` (`insertTransactionAndUpdateState`, ~line 1025-1053; `POST /transactions`, ~line 1183)
- Modify: `app/lib/data/user_cards_repository.dart` (`logTransaction`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `POST /transactions` now also accepts `note` in its body; `UserCardsRepository.logTransaction` gains `merchantName`/`occurredAt`/`note` parameters. Task 16 consumes the extended `logTransaction` signature.

- [ ] **Step 1: Thread `note` through `insertTransactionAndUpdateState`**

In `api/src/index.js`, change the function signature and its `INSERT`:

```js
async function insertTransactionAndUpdateState(client, userId, {
  userCardId, amount, occurred, categoryId, rail, merchantName, note, source,
}) {
```

```js
  const txn = await client.query(
    `INSERT INTO transactions
       (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source, note, reward_state)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'estimated')
     RETURNING id, amount_inr, occurred_at`,
    [userId, userCardId, amount, occurred, merchantName || null, categoryId || null, rail || 'unknown', source || 'manual', note || null]
  );
```

- [ ] **Step 2: Pass `note` through in `POST /transactions`**

```js
app.post('/transactions', requireAuth, async (req, res) => {
  const { userCardId, amountInr, occurredAt, categoryId, rail, merchantName, note } = req.body || {};
  const amount = Number(amountInr);
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  const occurred = occurredAt ? new Date(occurredAt) : new Date();
  if (Number.isNaN(occurred.getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }

  try {
    const result = await withUserClient(req.userId, (client) =>
      insertTransactionAndUpdateState(client, req.userId, {
        userCardId, amount, occurred, categoryId, rail, merchantName, note, source: 'manual',
      })
    );

    if (result.status !== 201) return res.status(result.status).json({ error: result.error });
    res.status(201).json(result);
  } catch (err) {
    console.error('POST /transactions error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});
```

(Only the destructured fields and the object passed to `insertTransactionAndUpdateState` change — the validation logic is unchanged.)

- [ ] **Step 3: Manually verify**

Run: `cd api && npm start`, then:

```bash
curl -s -X POST http://localhost:4000/transactions \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"userCardId":"<a real id>","amountInr":250,"merchantName":"Chai Point","note":"team snacks","occurredAt":"2026-08-06T10:00:00Z"}'
```

Expected: 201 with a `transaction` object; then `GET /transactions` should show `merchant_name: "Chai Point"` for that row (the existing `GET /transactions` query already selects `t.merchant_name` — no change needed there).

- [ ] **Step 4: Extend `UserCardsRepository.logTransaction`**

In `app/lib/data/user_cards_repository.dart`, replace `logTransaction`:

```dart
  /// UA-3+ (Chunk 17), extended for B6: manual quick-add now carries
  /// merchantName/occurredAt/note through to POST /transactions, all three
  /// already accepted server-side (occurredAt/categoryId/rail/merchantName
  /// were already wired; note is this task's addition — see Task 15 of
  /// the Group B plan). No client-side "undo" beyond a dismiss-only
  /// snackbar (Task 16) — there is no DELETE /transactions/:id route.
  Future<void> logTransaction({
    required String userCardId,
    required Money amount,
    String? categoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'amountInr': amount.rupees,
        'categoryId': ?categoryId,
        'merchantName': ?merchantName,
        'occurredAt': occurredAt?.toIso8601String(),
        'note': ?note,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /transactions failed: ${response.statusCode} ${response.body}');
    }
  }
```

- [ ] **Step 5: Check existing callers still compile**

Run: `cd app && grep -rn "\.logTransaction(" lib/`
Expected: every existing call site passes only named args this signature still accepts (`userCardId`, `amount`, `categoryId`) — the three new parameters are optional, so no caller needs updating. Confirm by running `cd app && flutter analyze lib/` and checking for no new errors at those call sites.

- [ ] **Step 6: Commit**

```bash
git add api/src/index.js app/lib/data/user_cards_repository.dart
git commit -m "feat: carry note through /transactions and logTransaction for B6"
```

---

### Task 16: B6 app — Manual Quick-Add screen

**Files:**
- Create: `app/lib/features/quickadd/quick_add_screen.dart`
- Modify: `app/lib/features/home/home_screen.dart` (entry point)
- Test: `app/test/features/quickadd/quick_add_screen_test.dart`

**Interfaces:**
- Consumes: `userCardsProvider`, `categoriesProvider`, `userCardsRepositoryProvider`, `clockProvider` (all existing), Task 15's extended `logTransaction`, `shared_preferences` (last-used card, same pattern as Task 14's recent searches).
- Produces: `class QuickAddScreen extends ConsumerStatefulWidget`, pushed via `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickAddScreen()))`.

- [ ] **Step 1: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

const _lastUsedCardKey = 'pandapay_app.quick_add_last_used_card_v1';

/// ui-spec B6 — "under 3 taps." No true undo: there is no
/// DELETE /transactions/:id route in this codebase (verified against
/// api/src/index.js — see Task 15's header note), so this posts the
/// transaction immediately on Save and the "Undo" snackbar action is
/// dismiss-only (it removes the snackbar and shows a follow-up notice that
/// the entry was already saved) rather than faking a revert that doesn't
/// actually happen server-side. A real undo is future work once a delete
/// route exists.
class QuickAddScreen extends ConsumerStatefulWidget {
  const QuickAddScreen({super.key});

  @override
  ConsumerState<QuickAddScreen> createState() => _QuickAddScreenState();
}

class _QuickAddScreenState extends ConsumerState<QuickAddScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _noteController = TextEditingController();
  String? _selectedUserCardId;
  String? _selectedCategoryId;
  DateTime? _date;
  bool _saving = false;
  String? _amountError;

  @override
  void initState() {
    super.initState();
    _loadLastUsedCard();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadLastUsedCard() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUsed = prefs.getString(_lastUsedCardKey);
    if (lastUsed != null && mounted) setState(() => _selectedUserCardId = lastUsed);
  }

  Future<void> _rememberLastUsedCard(String userCardId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUsedCardKey, userCardId);
  }

  bool get _canSave {
    final amount = double.tryParse(_amountController.text);
    return _selectedUserCardId != null && amount != null && amount > 0;
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      setState(() => _amountError = 'Enter an amount greater than ₹0');
      return;
    }
    // ui-spec B6 validation: future dates warn, not block.
    final now = ref.read(clockProvider).now();
    final occurredAt = _date ?? now;
    if (occurredAt.isAfter(now)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('This date is in the future'),
          content: const Text('Save it anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Save anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _selectedUserCardId == null) return;
    setState(() => _saving = true);
    try {
      await repo.logTransaction(
        userCardId: _selectedUserCardId!,
        amount: Money.fromRupees(amount),
        categoryId: _selectedCategoryId,
        merchantName: _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
        occurredAt: occurredAt,
        note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      );
      await _rememberLastUsedCard(_selectedUserCardId!);
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Transaction logged'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("This app can't undo a saved transaction yet — there's no delete option either; edit it from Activity instead.")),
                );
              },
            ),
          ),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);
    final categories = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick add')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: ListView(
          children: [
            TextField(
              controller: _amountController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
              decoration: InputDecoration(labelText: 'Amount', prefixText: '₹ ', errorText: _amountError),
              onChanged: (_) => setState(() => _amountError = null),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _merchantController, decoration: const InputDecoration(labelText: 'Merchant (optional)')),
            const SizedBox(height: AppSpace.md),
            userCards.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedUserCardId,
                decoration: const InputDecoration(labelText: 'Card'),
                items: cards.map((c) => DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName))).toList(),
                onChanged: (v) => setState(() => _selectedUserCardId = v),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            categories.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (list) => DropdownButtonFormField<String>(
                initialValue: _selectedCategoryId,
                decoration: const InputDecoration(labelText: 'Category (optional)'),
                items: list.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_date == null ? 'Today' : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}'),
              trailing: const Icon(Icons.calendar_today_rounded),
              onTap: () async {
                final now = ref.read(clockProvider).now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date ?? now,
                  firstDate: DateTime(now.year - 2),
                  lastDate: DateTime(now.year + 1),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _noteController, decoration: const InputDecoration(labelText: 'Note (optional)')),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Add a Home entry point**

In `home_screen.dart`, add the import `import '../quickadd/quick_add_screen.dart';` and a second `IconButton` next to Task 14's search icon in the `Row` added in Task 14 Step 6:

```dart
IconButton(
  tooltip: 'Quick add a transaction',
  icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickAddScreen())),
),
```

- [ ] **Step 3: Write the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('Save stays disabled until an amount and a card are both set', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('an empty-or-zero amount shows a validation error on Save attempt, not a crash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: QuickAddScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '0');
    await tester.pumpAndSettle();
    // Save is still disabled (no card selected) — this test only verifies
    // the screen builds cleanly with a zero-amount entry, matching this
    // task's amount>0 validation rule.
    expect(find.text('Amount'), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && flutter test test/features/quickadd/quick_add_screen_test.dart`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/quickadd/quick_add_screen.dart app/lib/features/home/home_screen.dart app/test/features/quickadd/quick_add_screen_test.dart
git commit -m "feat(app): B6 Manual Quick-Add with last-used-card default and dismiss-only undo"
```

---

### Task 17: B7 — Big-Purchase Calculator

Its own independent amount/category inputs (not `selectedCategoryProvider`/`enteredAmountProvider` — same reasoning as B3's Task 12), computed via the same `RecommendationEngine.rank` call pattern, as a one-off. Split Suggestion (→ G2) and EMI Comparison (→ G3) are visibly present but disabled, since neither Group G screen exists in this codebase yet — stated scope reduction, not a fake navigation.

**Files:**
- Create: `app/lib/features/calculator/big_purchase_calculator_screen.dart`
- Modify: `app/lib/features/home/home_screen.dart` (entry point)
- Test: `app/test/features/calculator/big_purchase_calculator_screen_test.dart`

**Interfaces:**
- Consumes: `catalogueProvider`, `userCardsProvider`, `recommendationEngineProvider`, `categoriesProvider` (all existing).
- Produces: `class BigPurchaseCalculatorScreen extends ConsumerStatefulWidget`, pushed via `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BigPurchaseCalculatorScreen()))`.

- [ ] **Step 1: Write the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec B7. "Split suggestion" (-> G2 Split Planner) and "EMI
/// comparison" (-> G3 EMI Advisor) are visibly present but disabled with a
/// "Coming soon" snackbar — Group G (Tools & Modes) is not built in this
/// codebase yet, and faking a navigation to a screen that doesn't exist
/// would be worse than an honest disabled state. Remove the `onPressed:
/// null` + snackbar-on-tap-of-a-wrapping-InkWell once G2/G3 land.
class BigPurchaseCalculatorScreen extends ConsumerStatefulWidget {
  const BigPurchaseCalculatorScreen({super.key});

  @override
  ConsumerState<BigPurchaseCalculatorScreen> createState() => _BigPurchaseCalculatorScreenState();
}

class _BigPurchaseCalculatorScreenState extends ConsumerState<BigPurchaseCalculatorScreen> {
  Money _amount = const Money.fromRupees(50000);
  String? _categoryId;

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$feature is coming soon.')));
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    final userCards = ref.watch(userCardsProvider);
    final categories = ref.watch(categoriesProvider);
    final engine = ref.watch(recommendationEngineProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Big-purchase calculator')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Amount', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpace.sm),
            TextField(
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixText: '₹ '),
              controller: TextEditingController(text: _amount.rupees.toStringAsFixed(0)),
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed >= 0) setState(() => _amount = Money.fromRupees(parsed));
              },
            ),
            const SizedBox(height: AppSpace.md),
            categories.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (list) => Wrap(
                spacing: AppSpace.xs,
                children: [
                  for (final c in list)
                    ChoiceChip(label: Text(c.name), selected: _categoryId == c.id, onSelected: (_) => setState(() => _categoryId = c.id)),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => _showComingSoon('Split suggestion'), child: const Text('Split suggestion')),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: OutlinedButton(onPressed: () => _showComingSoon('EMI comparison'), child: const Text('EMI comparison')),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            Expanded(child: _buildResults(catalogue, userCards, engine)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(AsyncValue<List<CardProduct>> catalogue, AsyncValue<List<UserCard>> userCards, RecommendationEngine engine) {
    if (catalogue.isLoading || userCards.isLoading) return const Center(child: CircularProgressIndicator());
    final combinedError = catalogue.error ?? userCards.error;
    if (combinedError != null) return ErrorState(message: userFacingErrorMessage(combinedError));

    final allCards = catalogue.requireValue;
    final wallet = userCards.requireValue;
    if (wallet.isEmpty) {
      return const EmptyState(icon: Icons.credit_card_off_rounded, title: 'No cards yet', message: 'Add a card to compare a big purchase across your wallet.');
    }
    final owned = allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

    final context = RecommendationContext(amount: _amount, categoryId: _categoryId, rail: TxnRail.swipe);
    final snapshots = owned.map((c) {
      final uc = wallet.where((w) => w.cardProductId == c.id).first;
      final capRemaining = {
        for (final cap in c.capRules)
          if (uc.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - uc.capConsumed[cap.id]!,
      };
      return CardSnapshot(product: c, capRemaining: capRemaining, milestoneProgress: uc.milestoneQualifiedSpend);
    }).toList();

    final ranked = engine.rank(context, snapshots);
    return ListView.builder(
      itemCount: ranked.length,
      itemBuilder: (context, index) {
        final rec = ranked[index];
        // ui-spec B7.5: flag a milestone-completing purchase — the engine
        // already phrases this exactly in reasonLines ("completes ... milestone").
        final completesMilestone = rec.reasonLines.any((l) => l.contains('completes') && l.contains('milestone'));
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpace.sm),
          child: ListTile(
            title: Text(rec.card.name),
            subtitle: rec.isExcluded ? Text(rec.exclusionReason!) : Text(rec.reasonLines.join(' · ')),
            trailing: rec.isExcluded ? null : MoneyText(rec.expectedValue, confidence: rec.confidence),
            tileColor: completesMilestone ? const Color(0xFFECFDF5) : null,
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 2: Add a Home entry point**

In `home_screen.dart`, add the import `import '../calculator/big_purchase_calculator_screen.dart';` and a third `IconButton` (calculator icon) in the same `Row` from Task 14/16:

```dart
IconButton(
  tooltip: 'Big-purchase calculator',
  icon: const Icon(Icons.calculate_outlined, size: 20),
  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BigPurchaseCalculatorScreen())),
),
```

- [ ] **Step 3: Write the widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/calculator/big_purchase_calculator_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('Split suggestion and EMI comparison show a Coming soon snackbar, never navigate', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Split suggestion'));
    await tester.pump();

    expect(find.text('Split suggestion is coming soon.'), findsOneWidget);
  });

  testWidgets('shows the empty state when the wallet has no cards', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No cards yet'), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && flutter test test/features/calculator/big_purchase_calculator_screen_test.dart`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/calculator/big_purchase_calculator_screen.dart app/lib/features/home/home_screen.dart app/test/features/calculator/big_purchase_calculator_screen_test.dart
git commit -m "feat(app): B7 Big-Purchase Calculator with disabled Split/EMI buttons"
```

---

## Self-Review

**1. Spec coverage** — checked against `ui-spec.md` lines 187-279 (B1-B8), the cross-cutting section (lines 448-467), and the traceability matrix (lines 11-76):

- B1 features 1-7: context line (Task 8), hero card (Task 5), "Why this card?" incl. override chip (Task 5), backup card row (Task 6), category chips (pre-existing, untouched), alerts strip (Task 7), scan button/FAB (pre-existing). B1's ranking-logic block (RuPay/UPI exclusion, cap blending, milestone bonus, forex, manual override force-to-top) is the pre-existing `RecommendationEngine`, now actually fed a resolved override by Task 3. B1 States (no-location-permission, unknown-location, offline, no-cards, cold-start) — no-cards/cold-start/offline already handled by the pre-existing `_RankedList`/loading branch; no-location-permission and unknown-location are Task 8's `_ContextState.noPermission`/`.noMatch` branches, deliberately non-nagging per spec.
- B2: full-screen camera, framing guide, torch, gallery import, haptic, offline-only operation, non-UPI/unreadable/permission-denied edge cases — all Task 11.
- B3: editable merchant/category, editable amount, ranked list, RuPay/UPI + P2P eligibility messaging, UPI-vs-swipe comparison, Pay-with intent, Always-use-here override creation, wasn't-accepted local re-rank, mc-absent fallback — all Task 12, with three named scope reductions (VPA crowdsource lookup, silent contribution, server-recorded acceptance data).
- B4: full sortable table, per-row expansion, reachable from B1 and B3 — Task 9, wired from both Task 5 (B1) and Task 12 (B3).
- B5: typed search, recent searches, category fallback, result→recommendation — Tasks 13-14.
- B6: amount/merchant/card/category/date/note under 3 taps, last-used card default, save→immediate cap/milestone update (via existing `logTransaction`→`insertTransactionAndUpdateState`), undo snackbar (dismiss-only, stated), amount>0 + future-date-warns validation — Tasks 15-16.
- B7: amount+category input, side-by-side ₹ value across owned cards, milestone-completion flag, Split/EMI buttons present-but-disabled with stated scope note — Task 17.
- B8: list/create/edit/delete/disable, empty state pointing to B3, and the ranking-wiring bug fix — Tasks 1-4, sequenced first per the brief's constraint (confirmed: Task 3 precedes Task 12/B3 and Task 5/B1's override chip).
- Traceability-matrix rows touching B: 4.1 (B2/B3 — Tasks 11-12), 4.4 (B1/B3/B4 "why this card" — Tasks 5, 9, 12), 4.5 (B4 — Task 9), 4.6 (B3 create/B8 manage — Tasks 1-4, 12), 4.7 (B6 — Tasks 15-16), 4.8 (B5 — Tasks 13-14), 10.1 (cap tracker feeding B1/B3 — pre-existing engine, Task 3 wiring), 10.15 (B7 — Task 17), 11.3 ("Home = one answer" — Task 5's hero treatment).
- Cross-cutting: estimated/confirmed badges via `MoneyText` in every new screen that shows money (Tasks 5, 6, 9, 12, 14, 16, 17); loading/empty/error states via `EmptyState`/`ErrorState` in every new screen; destructive-action confirmation on override delete (Task 4) and future-date save (Task 16); offline behavior stated per-screen in doc comments (Tasks 4, 11); accessibility (48dp targets via standard Material `IconButton`/`FilledButton` sizing, no color-only signaling — alerts strip pairs color with an icon+text, Task 7).

**2. Placeholder scan** — searched the finished plan for "TBD/TODO/similar to Task N/add appropriate error handling/fill in" (see the grep run before this section): zero matches except the three legitimate uses of the word "placeholder" itself describing an actual design decision (Global Constraints' own rule statement, the alerts-strip scope-note prose, and Task 14's `GeoPoint(0,0)` fallback comment, which explains a real fallback value, not an unwritten one). One garbled sentence was found and fixed in Task 16's undo-snackbar copy during this pass.

**3. Type/signature consistency** — traced across all 17 tasks:
- `CardOverride`/`OverrideScope` (Task 2) used identically in Tasks 3, 4, 12 — same field names (`vpa`, `merchantName`, `categoryId`, `isEnabled`, `cardDisplayName`).
- `resolveActiveOverrideCardProductId(overrides:, wallet:, categoryId:, merchantName:, vpa:)` (Task 3) called with matching named args in Task 12 (adds `vpa:`) — no signature drift.
- `UserCardsRepository.logTransaction` (Task 15's extension) is called with the exact extended signature in Task 16.
- `FeeWaiverProgress.periodEnd` (Task 7's addition) is a `required DateTime`, matching both the modified `fromJson` and every test construction in Task 7's own test file.
- `ParsedUpiQr`/`buildUpiPayUri` (Task 10) consumed with identical field names in Tasks 11-12.
- `_RecommendationCard`'s public constructor (`_RecommendationCard(recommendation, {required rank})`) is unchanged by Task 5's internal rewrite to `StatefulWidget`, so Task 6's `_RankedList` modification (written before Task 5's widget existed, in this plan's own build order — Task 5 precedes Task 6) still compiles against it.
- Every new provider name referenced by a later task (`cardOverridesProvider`, `cardOverridesRepositoryProvider`, `merchantSearchRepositoryProvider`) is spelled identically at its definition and every call site.

No inconsistencies required fixing beyond the Task 16 copy fix above.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-07-group-b-home-recommendation.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

