import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

/// CCR-003: a refund ledger row carries its category on the wire, so a second
/// device reads the same category totals from the synced events alone.
void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = testRuleBundle();
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  const purchaseBody =
      'Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-10-05:12:30:11. Avl Lmt: Rs.45,000.00.';
  const refundBody =
      'Refund of Rs.499.00 from SWIGGY credited to your HDFC Bank Credit Card XX5678 on 03-11-26.';
  const unknownRefundBody =
      'Refund of Rs.250.00 from ZZQXV credited to your HDFC Bank Credit Card XX5678 on 04-11-26.';

  void capture(String namespace, List<(String, DateTime)> messages) {
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    ).processBatch([
      for (final (index, m) in messages.indexed)
        SmsMessage(
          sourceKey: '${index + 10}'.padLeft(64, '0'),
          sender: 'VM-HDFCBK-S',
          body: m.$1,
          observedAt: m.$2,
        ),
    ], backfill: true);
  }

  /// The sync response a server would return for what [namespace] uploaded.
  Map<String, Object?> serverBody(String namespace) {
    final queued = OutboxStore(
      database.db,
      namespace: namespace,
    ).due(DateTime.utc(2027));
    List<Map<String, Object?>> kind(String name) => [
      for (final r in queued)
        if (r.kind == name) r.json,
    ];
    Map<String, String> stamps(String name, String key) => {
      for (final row in kind(name)) row[key] as String: '2026-11-04T00:00:00Z',
    };
    return {
      'cursor': 'page-1',
      'facts': [for (final s in kind('source')) ...s['facts'] as List],
      'instruments': kind('instrument'),
      'events': kind('event'),
      'ledger': kind('ledger'),
      'aiResults': <Object?>[],
      'corrections': <Object?>[],
      'latestBundleVersion': 1,
      'updatedAt': {
        'events': stamps('event', 'eventId'),
        'instruments': stamps('instrument', 'instrumentId'),
        'ledger': stamps('ledger', 'entryId'),
      },
    };
  }

  Future<void> pullInto(String namespace, Map<String, Object?> body) =>
      SyncPull(
        financial: financial,
        namespace: namespace,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        bundle: bundle,
      ).pull();

  /// Totals as a device computes them. [withLocalContext] false reads only the
  /// synced rows and events, which is all a fresh second device has.
  Totals totalsFor(
    String namespace,
    DateTime from,
    DateTime to, {
    bool withLocalContext = true,
  }) {
    final ledger = LedgerStore(database.db, namespace: namespace);
    return LedgerSnapshot(
      entries: ledger.list(),
      events: EventStore(
        database.db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900)),
      categoryByEvent: withLocalContext ? ledger.categoryDecisions() : const {},
    ).totals(from, to);
  }

  final oct = (
    DateTime.utc(2026, 9, 30, 18, 30),
    DateTime.utc(2026, 10, 31, 18, 30),
  );
  final nov = (
    DateTime.utc(2026, 10, 31, 18, 30),
    DateTime.utc(2026, 11, 30, 18, 30),
  );

  test(
    'a refund of an earlier-month purchase reduces that purchase category and syncs identically',
    () async {
      capture('source', [
        (purchaseBody, DateTime.utc(2026, 10, 5, 12, 31)),
        (refundBody, DateTime.utc(2026, 11, 3, 10)),
      ]);
      final ledger = LedgerStore(database.db, namespace: 'source');
      final refundRow = ledger.list().singleWhere((e) => e.isRefundShaped);
      expect(refundRow.category, 'dining');
      expect(refundRow.validate().ok, isTrue);
      // Persisted on the wire field, not as local metadata.
      final stored = jsonDecode(
        database.db.select(
              'SELECT payload FROM v2_ledger WHERE namespace=? AND entry_id=?',
              ['source', refundRow.entryId],
            ).single['payload']
            as String,
      );
      expect(stored['category'], 'dining');
      expect(stored.containsKey('_categoryDecision'), isFalse);

      final octSource = totalsFor('source', oct.$1, oct.$2);
      final novSource = totalsFor('source', nov.$1, nov.$2);
      expect(octSource.byCategory, {'dining': 49900});
      expect(novSource.byCategory, {'dining': -49900});
      expect(novSource.spendMinor, -49900);
      expect(novSource.refundMinor, 49900);
      expect(novSource.transactionCount, 1);

      await pullInto('target', serverBody('source'));
      for (final withContext in [true, false]) {
        final octTarget = totalsFor(
          'target',
          oct.$1,
          oct.$2,
          withLocalContext: withContext,
        );
        final novTarget = totalsFor(
          'target',
          nov.$1,
          nov.$2,
          withLocalContext: withContext,
        );
        expect(octTarget.byCategory, octSource.byCategory);
        expect(novTarget.byCategory, novSource.byCategory);
        expect(novTarget.spendMinor, novSource.spendMinor);
        expect(novTarget.refundMinor, novSource.refundMinor);
        expect(novTarget.transactionCount, novSource.transactionCount);
        expect(octTarget.transactionCount, octSource.transactionCount);
      }
      final targetRefund = LedgerStore(
        database.db,
        namespace: 'target',
      ).list().singleWhere((e) => e.isRefundShaped);
      expect(targetRefund.category, 'dining');
    },
  );

  test(
    'a standalone refund with no linked purchase falls back to a safe category',
    () async {
      capture('source', [(unknownRefundBody, DateTime.utc(2026, 11, 4, 10))]);
      final ledger = LedgerStore(database.db, namespace: 'source');
      final row = ledger.list().single;
      expect(row.isRefundShaped, isTrue);
      expect(row.category, 'other');
      expect(row.categorySource, CategorySource.fallback);
      expect(row.validate().ok, isTrue);
      final source = totalsFor('source', nov.$1, nov.$2);
      expect(source.byCategory, {'other': -25000});
      expect(source.refundMinor, 25000);
      expect(source.transactionCount, 1);

      await pullInto('target', serverBody('source'));
      final target = totalsFor(
        'target',
        nov.$1,
        nov.$2,
        withLocalContext: false,
      );
      expect(target.byCategory, source.byCategory);
      expect(target.spendMinor, source.spendMinor);
    },
  );

  test(
    'a refund row stored before CCR-003 reads its local decision and is upgraded on the next write',
    () {
      capture('source', [
        (purchaseBody, DateTime.utc(2026, 10, 5, 12, 31)),
        (refundBody, DateTime.utc(2026, 11, 3, 10)),
      ]);
      final ledger = LedgerStore(database.db, namespace: 'source');
      final row = ledger.list().singleWhere((e) => e.isRefundShaped);
      // Rewrite the row exactly as an older build stored it.
      database.db.execute(
        'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
        [
          jsonEncode({
            ...row.withCategory(null, null).toJson(),
            '_categoryDecision': {
              'slug': 'groceries',
              'source': 'user',
              'ruleId': null,
              'confidence': 1.0,
            },
          }),
          'source',
          row.entryId,
        ],
      );
      expect(ledger.get(row.entryId)!.category, isNull);
      expect(ledger.categoryDecisions()[row.eventId]!.slug, 'groceries');
      expect(
        totalsFor('source', nov.$1, nov.$2).byCategory,
        {'dining': -49900},
        reason: 'the linked purchase still wins, as before',
      );

      ledger.replaceForEvent(
        row.eventId,
        [row.withCategory(null, null)],
        category: const CategoryDecision(
          slug: 'groceries',
          source: CategorySource.user,
          confidence: 1,
        ),
      );
      final upgraded = ledger.get(row.entryId)!;
      expect(upgraded.category, 'groceries');
      expect(upgraded.categorySource, CategorySource.user);
      expect(
        database.db.select('SELECT payload FROM v2_ledger WHERE entry_id=?', [
          row.entryId,
        ]).single['payload'],
        isNot(contains('_categoryDecision')),
      );
      expect(ledger.categoryDecisions()[row.eventId]!.slug, 'groceries');
    },
  );
}
