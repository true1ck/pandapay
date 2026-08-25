import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/notification_preferences_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/notifications/notification_gate.dart';

NotificationPreferences _prefs({
  bool categoryLocation = true,
  bool categoryCaps = true,
  bool categoryMilestones = true,
  bool categoryFeeWaivers = true,
  bool categoryBills = true,
  bool categoryExpiry = true,
  bool categoryMonthlyReport = true,
  bool categoryNeedsReview = true,
  String? quietHoursStart,
  String? quietHoursEnd,
  int dailyCap = 3,
}) {
  return NotificationPreferences(
    categoryLocation: categoryLocation,
    categoryCaps: categoryCaps,
    categoryMilestones: categoryMilestones,
    categoryFeeWaivers: categoryFeeWaivers,
    categoryBills: categoryBills,
    categoryExpiry: categoryExpiry,
    categoryMonthlyReport: categoryMonthlyReport,
    categoryNeedsReview: categoryNeedsReview,
    quietHoursStart: quietHoursStart,
    quietHoursEnd: quietHoursEnd,
    dailyCap: dailyCap,
  );
}

/// UserCardsRepository.recordNotification is what recordAppNotification
/// calls under the hood (see providers.dart) — recording instead of
/// actually POSTing lets fire()'s "did it try to write the inbox row"
/// assertion run without an http.Client mock.
class _RecordingUserCardsRepository extends UserCardsRepository {
  _RecordingUserCardsRepository() : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  final List<String> recordedCategories = [];

  @override
  Future<void> recordNotification({
    required String category,
    required String title,
    String? body,
    String severity = 'info',
    String? deepLink,
    String? dedupeKey,
  }) async {
    recordedCategories.add(category);
  }
}

class _FakeMutedMerchantsRepository extends NotificationPreferencesRepository {
  _FakeMutedMerchantsRepository(this._mutedIds) : super(apiBaseUrl: 'http://test.local', accessToken: 'tok');
  final Set<String> _mutedIds;

  @override
  Future<List<MutedMerchant>> fetchMutedMerchants() async {
    return _mutedIds
        .map((id) => MutedMerchant(merchantId: id, mutedAt: DateTime(2026, 1, 1), merchantName: 'Merchant'))
        .toList();
  }
}

void main() {
  group('NotificationGate.categoryEnabled', () {
    test('reads the matching column for each of the 8 preference categories', () {
      final prefs = _prefs(
        categoryLocation: true,
        categoryCaps: false,
        categoryMilestones: true,
        categoryFeeWaivers: false,
        categoryBills: true,
        categoryExpiry: false,
        categoryMonthlyReport: true,
        categoryNeedsReview: false,
      );
      expect(NotificationGate.categoryEnabled(prefs, 'location'), isTrue);
      expect(NotificationGate.categoryEnabled(prefs, 'caps'), isFalse);
      expect(NotificationGate.categoryEnabled(prefs, 'milestones'), isTrue);
      expect(NotificationGate.categoryEnabled(prefs, 'fee_waivers'), isFalse);
      expect(NotificationGate.categoryEnabled(prefs, 'bills'), isTrue);
      expect(NotificationGate.categoryEnabled(prefs, 'expiry'), isFalse);
      expect(NotificationGate.categoryEnabled(prefs, 'monthly_report'), isTrue);
      expect(NotificationGate.categoryEnabled(prefs, 'needs_review'), isFalse);
    });

    test('a category with no preference column (streak, card_added) is always allowed', () {
      final prefs = _prefs();
      expect(NotificationGate.categoryEnabled(prefs, 'streak'), isTrue);
      expect(NotificationGate.categoryEnabled(prefs, 'card_added'), isTrue);
    });
  });

  group('NotificationGate.inQuietHours', () {
    test('no quiet hours set never suppresses', () {
      final prefs = _prefs();
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 23, 0)), isFalse);
    });

    test('inside a same-day window suppresses', () {
      final prefs = _prefs(quietHoursStart: '13:00', quietHoursEnd: '15:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 14, 0)), isTrue);
    });

    test('exactly at the start boundary suppresses (inclusive start)', () {
      final prefs = _prefs(quietHoursStart: '13:00', quietHoursEnd: '15:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 13, 0)), isTrue);
    });

    test('exactly at the end boundary does not suppress (exclusive end)', () {
      final prefs = _prefs(quietHoursStart: '13:00', quietHoursEnd: '15:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 15, 0)), isFalse);
    });

    test('before a same-day window does not suppress', () {
      final prefs = _prefs(quietHoursStart: '13:00', quietHoursEnd: '15:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 12, 59)), isFalse);
    });

    test('a window that wraps past midnight suppresses both sides of midnight', () {
      final prefs = _prefs(quietHoursStart: '22:00', quietHoursEnd: '07:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 23, 0)), isTrue);
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 3, 0)), isTrue);
    });

    test('a window that wraps past midnight does not suppress the daytime gap', () {
      final prefs = _prefs(quietHoursStart: '22:00', quietHoursEnd: '07:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 12, 0)), isFalse);
    });

    test('equal start and end is treated as disabled, not a 24-hour window', () {
      final prefs = _prefs(quietHoursStart: '09:00', quietHoursEnd: '09:00');
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 9, 0)), isFalse);
      expect(NotificationGate.inQuietHours(prefs, DateTime(2026, 1, 1, 15, 0)), isFalse);
    });
  });

  group('NotificationGate.dailyCapReached', () {
    test('below the cap is not reached', () => expect(NotificationGate.dailyCapReached(2, 3), isFalse));
    test('exactly at the cap is reached', () => expect(NotificationGate.dailyCapReached(3, 3), isTrue));
    test('past the cap is reached', () => expect(NotificationGate.dailyCapReached(5, 3), isTrue));
  });

  group('NotificationGate.fire', () {
    late Ref ref;
    late ProviderContainer container;
    late _RecordingUserCardsRepository userCardsRepo;

    ProviderContainer buildContainer({
      NotificationPreferences? prefs,
      NotificationPreferencesRepository? notifPrefsRepo,
    }) {
      userCardsRepo = _RecordingUserCardsRepository();
      final refCaptureProvider = Provider<void>((r) => ref = r);
      final c = ProviderContainer(
        overrides: [
          notificationPreferencesProvider.overrideWith((_) async => prefs),
          if (notifPrefsRepo != null) notificationPreferencesRepositoryProvider.overrideWithValue(notifPrefsRepo),
          userCardsRepositoryProvider.overrideWithValue(userCardsRepo),
        ],
      );
      c.read(refCaptureProvider);
      return c;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      container.dispose();
    });

    test('signed out (no preferences row) suppresses and never records', () async {
      container = buildContainer(prefs: null);
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final fired = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k1');
      expect(fired, isFalse);
      expect(userCardsRepo.recordedCategories, isEmpty);
    });

    test('a disabled category suppresses and never records', () async {
      container = buildContainer(prefs: _prefs(categoryCaps: false));
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final fired = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k1');
      expect(fired, isFalse);
      expect(userCardsRepo.recordedCategories, isEmpty);
    });

    test('inside quiet hours suppresses', () async {
      container = buildContainer(prefs: _prefs(quietHoursStart: '00:00', quietHoursEnd: '23:59'));
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final fired = await gate.fire(
        category: 'caps',
        title: 't',
        body: 'b',
        dedupeKey: 'k1',
        now: DateTime(2026, 1, 1, 12, 0),
      );
      expect(fired, isFalse);
      expect(userCardsRepo.recordedCategories, isEmpty);
    });

    test('a muted merchant suppresses a merchant-scoped notification', () async {
      container = buildContainer(prefs: _prefs(), notifPrefsRepo: _FakeMutedMerchantsRepository({'m1'}));
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final fired = await gate.fire(
        category: 'location',
        title: 't',
        body: 'b',
        dedupeKey: 'k1',
        merchantId: 'm1',
      );
      expect(fired, isFalse);
      expect(userCardsRepo.recordedCategories, isEmpty);
    });

    test('a merchant that is not muted still fires', () async {
      container = buildContainer(prefs: _prefs(), notifPrefsRepo: _FakeMutedMerchantsRepository({'other'}));
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final fired = await gate.fire(
        category: 'location',
        title: 't',
        body: 'b',
        dedupeKey: 'k1',
        merchantId: 'm1',
      );
      expect(fired, isTrue);
      expect(userCardsRepo.recordedCategories, ['location']);
    });

    test('the same dedupeKey does not fire twice', () async {
      container = buildContainer(prefs: _prefs());
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final first = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'same-key');
      final second = await gate.fire(category: 'caps', title: 't2', body: 'b2', dedupeKey: 'same-key');
      expect(first, isTrue);
      expect(second, isFalse);
      expect(userCardsRepo.recordedCategories, ['caps']);
    });

    test('a different dedupeKey fires again', () async {
      container = buildContainer(prefs: _prefs());
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final first = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'key-a');
      final second = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'key-b');
      expect(first, isTrue);
      expect(second, isTrue);
      expect(userCardsRepo.recordedCategories, ['caps', 'caps']);
    });

    test('the daily cap suppresses once reached, even with a fresh dedupeKey', () async {
      container = buildContainer(prefs: _prefs(dailyCap: 2));
      final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
      final r1 = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k1');
      final r2 = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k2');
      final r3 = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k3');
      expect([r1, r2, r3], [true, true, false]);
      expect(userCardsRepo.recordedCategories, ['caps', 'caps']);
    });

    test(
      'a clear condition fires and records, even though the OS plugin call itself fails '
      'in this test environment (no real platform channel — see the try/catch around it)',
      () async {
        container = buildContainer(prefs: _prefs());
        final gate = NotificationGate(ref: ref, notifications: FlutterLocalNotificationsPlugin());
        final fired = await gate.fire(category: 'caps', title: 't', body: 'b', dedupeKey: 'k-success');
        expect(fired, isTrue);
        expect(userCardsRepo.recordedCategories, ['caps']);
      },
    );
  });
}
