import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/notifications/notification_gate.dart';
import 'package:pandapay/features/notifications/notification_triggers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// WP9 cap alerts for v2 caps: the 80% / 100% triggers on
/// consumed_native / cap_amount, bucketed by the server's period_start, with
/// the next-best OWNED card ("Use X for Y instead") when it earns more than
/// base. The existing dedupe key shape (and so the gate's dedupe and daily
/// budget) is unchanged; v1 caps keep today's path.
final _now = DateTime(2026, 11, 15);
const _dining = SpendCategory(id: 'cat-dining', slug: 'dining', name: 'Dining');

CardProduct _capped() =>
    parseCard(v2CardJson('a', name: 'Rewards Card', categoryId: 'cat-dining'));

UserCard _ownedA(
  Object? native, {
  Object? consumedV1 = 0,
  String start = '2026-11-01',
  String end = '2026-11-30',
  bool withRow = true,
  String? nickname,
}) => parseUserCard(
  userCardJson(
    'ua',
    'a',
    nickname: nickname,
    capStates: [
      if (withRow)
        capStateRowJson(
          'a-cap',
          consumed: consumedV1,
          consumedNative: native,
          capKind: native == null ? null : 'bonus_points',
          capAmount: native == null ? null : 1500,
          periodStart: native == null ? null : start,
          periodEnd: native == null ? null : end,
        ),
    ],
  ),
);

// 3% on dining vs 1% base: earns more than base.
CardProduct _other({double diningRate = 3}) => CardProduct(
  id: 'b',
  name: 'Dining Specialist',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: [
    RewardRule(
      id: 'b-dining',
      categoryId: 'cat-dining',
      unit: RewardUnit.cashbackPercent,
      rate: diningRate,
    ),
  ],
);

UserCard _ownedB() => UserCard(
  id: 'ub',
  cardProductId: 'b',
  cardName: 'Dining Specialist',
  isDefault: false,
);

List<CapAlert> _plan(
  UserCard a, {
  bool withOther = true,
  CardProduct? other,
  List<SpendCategory> categories = const [_dining],
  DateTime? now,
}) {
  final product = _capped();
  return NotificationTriggerRunner.planV2CapAlerts(
    userCard: a,
    product: product,
    owned: [(a, product), if (withOther) (_ownedB(), other ?? _other())],
    categories: categories,
    now: now ?? _now,
  );
}

void main() {
  group('ratio = consumed_native / cap_amount', () {
    test('83% of the native cap warns', () {
      final alerts = _plan(_ownedA(1250));
      expect(alerts, hasLength(1));
      expect(alerts.single.title, 'Rewards Card is close to its cap');
      expect(alerts.single.body, contains('83%'));
      expect(alerts.single.dedupeKey, endsWith(':warning'));
    });

    test('100% is "reached"; beyond 100% too', () {
      for (final native in [1500, 1600]) {
        final alerts = _plan(_ownedA(native));
        expect(alerts.single.title, 'Rewards Card cap reached');
        expect(alerts.single.dedupeKey, endsWith(':reached'));
      }
    });

    test('79% raises nothing', () {
      expect(_plan(_ownedA(1185)), isEmpty);
    });

    test('exactly 80% warns, and says 80% (one rounding rule with the bars)',
        () {
      final alerts = _plan(_ownedA(1200));
      expect(alerts, hasLength(1));
      expect(alerts.single.body, contains('80%'));
    });

    test('99.7% says 99%, never 100% before the cap is reached', () {
      final alerts = _plan(_ownedA(1495.5));
      expect(alerts.single.body, contains('99%'));
      expect(alerts.single.dedupeKey, endsWith(':warning'));
    });

    test('the v1 measure is never used: huge v1 consumed, low native: no '
        'alert', () {
      expect(_plan(_ownedA(100, consumedV1: 99999)), isEmpty);
    });

    test('the v1 measure is never used: v1 consumed 0, high native: alert',
        () {
      expect(_plan(_ownedA(1400, consumedV1: 0)), hasLength(1));
    });
  });

  group('the reached body says what the cap means for its kind', () {
    /// A reached alert for a cap of [kind] (the row has used all of it).
    String reachedBody(
      String kind, {
      num amount = 1500,
      Map<String, dynamic> capExtra = const {},
      Map<String, dynamic> cardExtra = const {},
    }) {
      final product = parseCard({
        ...v2CardJson(
          'a',
          name: 'Rewards Card',
          categoryId: 'cat-dining',
          capKind: kind,
          capAmount: amount,
          capExtra: capExtra,
        ),
        ...cardExtra,
      });
      final owned = parseUserCard(
        userCardJson(
          'ua',
          'a',
          capStates: [
            capStateRowJson(
              'a-cap',
              consumed: 0,
              consumedNative: amount,
              capKind: kind,
              capAmount: amount,
              periodStart: '2026-11-01',
              periodEnd: '2026-11-30',
            ),
          ],
        ),
      );
      return NotificationTriggerRunner.planV2CapAlerts(
        userCard: owned,
        product: product,
        owned: [(owned, product)],
        categories: const [_dining],
        now: _now,
      ).single.body;
    }

    test('a bonus cap: extra spend earns only the base rate', () {
      expect(
        reachedBody('bonus_points'),
        contains('extra spend here earns only 1 pt/₹100'),
      );
    });

    test('a total cap: extra spend earns nothing', () {
      expect(
        reachedBody('total_points'),
        contains('extra spend here earns nothing'),
      );
      expect(
        reachedBody('total_cashback', amount: 500),
        contains('extra spend here earns nothing'),
      );
    });

    test('an eligible-spend cap follows its post-cap behaviour', () {
      expect(
        reachedBody(
          'eligible_spend',
          amount: 20000,
          capExtra: {'post_cap_behavior': 'zero'},
        ),
        contains('earns nothing'),
      );
      expect(
        reachedBody(
          'eligible_spend',
          amount: 20000,
          capExtra: {
            'post_cap_behavior': 'custom_rate',
            'post_cap_unit': 'points_per_100',
            'post_cap_rate': 2,
          },
        ),
        contains('earns only 2 pts/₹100'),
      );
    });

    test('a count cap whose post-cap rate is unsure names no rate', () {
      final body = reachedBody(
        'txn_count',
        amount: 3,
        capExtra: {'post_cap_behavior': 'custom_rate'},
      );
      expect(body, contains('won\'t earn the capped rate'));
      expect(body, isNot(contains('earns only')));
    });

    test('a bonus cap whose base is unsure falls back to the bonus wording',
        () {
      final body = reachedBody(
        'bonus_points',
        cardExtra: {'base_reward_unit': null, 'base_reward_rate': null},
      );
      expect(body, contains('won\'t earn the bonus rate'));
    });

    test('the warning body is unchanged (percentage and label only)', () {
      final alerts = _plan(_ownedA(1250));
      expect(alerts.single.body, isNot(contains('earns')));
    });
  });

  group('nothing we cannot stand behind', () {
    test('no row (nothing consumed): no alert', () {
      expect(_plan(_ownedA(0, withRow: false)), isEmpty);
    });

    test('unknown consumed_native: no alert', () {
      expect(_plan(_ownedA(null)), isEmpty);
    });

    test('a row from a period that has ended: no alert', () {
      expect(
        _plan(_ownedA(1450, start: '2026-10-01', end: '2026-10-31')),
        isEmpty,
      );
    });
  });

  group('dedupe bucket is the server\'s period_start', () {
    test('the key carries period_start and keeps the v1 key shape', () {
      final key = _plan(_ownedA(1250)).single.dedupeKey;
      expect(key, 'cap:ua:a-cap:2026-11-01:warning');
    });

    test('a new period gives a new key (alerts again)', () {
      final november = _plan(_ownedA(1250)).single.dedupeKey;
      final december = _plan(
        _ownedA(1250, start: '2026-12-01', end: '2026-12-31'),
        now: DateTime(2026, 12, 10),
      ).single.dedupeKey;
      expect(december, 'cap:ua:a-cap:2026-12-01:warning');
      expect(december, isNot(november));
    });

    test('warning and reached are separate keys in one period', () {
      final warning = _plan(_ownedA(1250)).single.dedupeKey;
      final reached = _plan(_ownedA(1500)).single.dedupeKey;
      expect(reached, isNot(warning));
    });
  });

  group('next-best owned card', () {
    test('is named when it earns more than base', () {
      final body = _plan(_ownedA(1250)).single.body;
      expect(body, contains('Use Dining Specialist for Dining instead.'));
    });

    test('is named on a reached cap too', () {
      final body = _plan(_ownedA(1500)).single.body;
      expect(body, endsWith('Use Dining Specialist for Dining instead.'));
    });

    test('is omitted when no other owned card earns more than base', () {
      expect(_plan(_ownedA(1250), other: _other(diningRate: 1)).single.body,
          isNot(contains('Use ')));
    });

    test('is omitted when only the capped card is owned', () {
      expect(_plan(_ownedA(1250), withOther: false).single.body,
          isNot(contains('Use ')));
    });

    test('is omitted when the category list is not loaded', () {
      expect(_plan(_ownedA(1250), categories: const []).single.body,
          isNot(contains('Use ')));
    });
  });

  test('the capped card\'s nickname is used', () {
    final alerts = _plan(_ownedA(1250, nickname: 'Daily Driver'));
    expect(alerts.single.title, 'Daily Driver is close to its cap');
  });

  group('through the runner (gate dedupe and budget untouched)', () {
    Future<List<Map<String, String>>> run({
      required List<(UserCard, CardProduct)> owned,
    }) async {
      final fired = <Map<String, String>>[];
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          ownedCardsWithProductProvider.overrideWith(
            (ref) => AsyncValue.data(owned),
          ),
          categoriesProvider.overrideWith((ref) async => const [_dining]),
          notificationGateProvider.overrideWith(
            (ref) => _RecordingGate(ref, fired),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(categoriesProvider.future);
      await container.read(notificationTriggerRunnerProvider).runCapChecks();
      return fired;
    }

    test('a v2 card fires through the gate as category "caps"', () async {
      // The runner reads the real clock, so use the current month's row.
      final today = DateTime.now();
      String day(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final start = DateTime(today.year, today.month, 1);
      final a = _ownedA(
        1250,
        start: day(start),
        end: day(DateTime(today.year, today.month + 1, 0)),
      );
      final fired = await run(owned: [(a, _capped()), (_ownedB(), _other())]);
      expect(fired, hasLength(1));
      expect(fired.single['category'], 'caps');
      expect(fired.single['dedupeKey'], 'cap:ua:a-cap:${day(start)}:warning');
      expect(fired.single['body'], contains('Use Dining Specialist'));
    });

    test('a v1 card still uses the v1 path', () async {
      final v1 = parseCard(v1CardJson('v', withCap: true));
      final owned = parseUserCard(
        userCardJson(
          'uv',
          'v',
          // ₹450 of a ₹500 v1 cap: 90%.
          capStates: [capStateRowJson('v-cap', consumed: 450)],
        ),
      );
      final fired = await run(owned: [(owned, v1)]);
      expect(fired, hasLength(1));
      expect(fired.single['title'], contains('is close to its cap'));
      expect(fired.single['dedupeKey'], startsWith('cap:uv:v-cap:'));
      // v1 bodies are unchanged: no next-best suggestion.
      expect(fired.single['body'], isNot(contains('Use ')));
    });
  });
}

class _RecordingGate extends NotificationGate {
  final List<Map<String, String>> fired;
  _RecordingGate(Ref ref, this.fired)
    : super(ref: ref, notifications: FlutterLocalNotificationsPlugin());

  @override
  Future<bool> fire({
    required String category,
    required String title,
    required String body,
    required String dedupeKey,
    String? merchantId,
    String severity = 'info',
    String? deepLink,
    DateTime? now,
    int? notificationId,
  }) async {
    fired.add({
      'category': category,
      'title': title,
      'body': body,
      'dedupeKey': dedupeKey,
    });
    return true;
  }
}
