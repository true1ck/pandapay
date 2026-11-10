import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Fact _fact(String id, String source, String engine, {String? ruleId}) {
  final j =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  j['factId'] = _hex(id);
  j['sourceKey'] = source;
  final prov = (j['provenance'] as Map).cast<String, Object?>();
  prov['engine'] = engine;
  if (ruleId != null) prov['ruleId'] = ruleId;
  j['provenance'] = prov;
  return Fact.fromJson(j);
}

TransactionEntry _entry(String id, String source, DateTime at) =>
    TransactionEntry(
      id: id,
      amount: Money.fromPaise(25000),
      occurredAt: at,
      sourceKey: source,
      eventId: 'event-$id',
      merchantName: 'Shop $id',
      source: 'sms',
      status: 'active',
      pipelineVersion: 2,
    );

void main() {
  final now = DateTime(2026, 11, 10);

  test(
    'only Gemini reads are AI auto-resolved; user facts are History; rule reads show nowhere',
    () {
      final lists = settledLists(
        [
          _entry('a', 'sa', DateTime(2026, 11, 8)),
          _entry('b', 'sb', DateTime(2026, 11, 9)),
          _entry('c', 'sc', DateTime(2026, 11, 7)),
        ],
        {
          'sa': [_fact('fa', 'sa', 'rules')],
          'sb': [_fact('fb1', 'sb', 'rules'), _fact('fb2', 'sb', 'user')],
          'sc': [_fact('fc', 'sc', 'rules', ruleId: 'AI-abc123')],
        },
        now: now,
      );
      expect(lists.history.map((i) => i.entry.id), ['b']);
      expect(lists.history.single.byUser, isTrue);
      // Rule reads are silent; only the Gemini one (c) is listed.
      expect(lists.auto.map((i) => i.entry.id), ['c']);
      expect(lists.auto.single.how, 'Read by a Gemini AI rule, verified');
      expect(lists.auto.single.source, SettledSource.ai);
    },
  );

  test('the reader is named from the rule ids', () {
    expect(settledSourceOf(['BNK-HDFC-01']), SettledSource.rule);
    expect(settledSourceOf(['SOLVER-REFINED']), SettledSource.onDevice);
    expect(
      settledSourceOf(['GEN-DEBIT-01', 'AI-9f:local:ab']),
      SettledSource.ai,
    );
    expect(settledSourceOf(const []), SettledSource.rule);
  });

  test('an AI rule that exists only on this phone is not yet verified', () {
    final lists = settledLists(
      [_entry('u', 'su', DateTime(2026, 11, 8))],
      {
        'su': [_fact('fu', 'su', 'rules', ruleId: 'AI-abc:local:def')],
      },
      now: now,
    );
    expect(lists.auto.single.how, 'Read by a Gemini AI rule, not yet verified');
  });

  test('old, unsourced and non-v2 transactions are left out', () {
    final old = _entry('old', 'so', DateTime(2026, 5, 1));
    final v1 = TransactionEntry(
      id: 'v1',
      amount: Money.fromPaise(100),
      occurredAt: DateTime(2026, 11, 9),
      sourceKey: 'sv',
      source: 'sms',
      status: 'active',
    );
    final lists = settledLists(
      [old, v1, _entry('n', 'sn', DateTime(2026, 11, 9))],
      {
        'so': [_fact('fo', 'so', 'rules')],
        'sv': [_fact('fv', 'sv', 'rules')],
      },
      now: now,
    );
    expect(lists.auto, isEmpty);
    expect(lists.history, isEmpty);
  });

  test('each list is capped at the row limit, newest first', () {
    final entries = [
      for (var i = 0; i < settledMaxRows + 20; i++)
        _entry(
          't$i',
          's$i',
          DateTime(2026, 11, 9).subtract(Duration(minutes: i)),
        ),
    ];
    final facts = {
      for (var i = 0; i < settledMaxRows + 20; i++)
        's$i': [_fact('f$i', 's$i', 'rules', ruleId: 'AI-cap$i')],
    };
    final lists = settledLists(entries, facts, now: now);
    expect(lists.auto.length, settledMaxRows);
    expect(lists.auto.first.entry.id, 't0');
  });

  testWidgets('a card shows the shop, the amount and how it was settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SettledCard(
              item: SettledItem(
                entry: _entry('x', 'sx', DateTime(2026, 11, 8)),
                byUser: false,
                how: 'Read by a rule',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Shop x'), findsOneWidget);
    expect(find.text('Read by a rule'), findsOneWidget);
    expect(find.textContaining('250'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Move back to review'), findsOneWidget);
  });

  group('with a phone database', () {
    late ResponseCache cache;
    late ProviderContainer container;
    setUp(() {
      final db = openInMemoryForTesting();
      cache = ResponseCache(db);
      SmsV2Schema.ensure(cache.financialStore.database.db);
      container = ProviderContainer(
        overrides: [
          app.cacheNamespaceProvider.overrideWithValue('user:one'),
          app.responseCacheProvider.overrideWith((ref) async => cache),
          aiReviewStatusProvider.overrideWith(
            (ref) async => const AiReviewStatus(),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        cache.financialStore.dispose();
        db.close();
      });
    });

    testWidgets('Move to Needs review opens one review row, and is repeatable', (
      tester,
    ) async {
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, r, _) {
                ref = r;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final db = cache.financialStore.database.db;
      final entry = _entry('r', 'sr', DateTime(2026, 11, 8));
      await tester.runAsync(() => reopenForReview(ref, entry));
      var rows = db.select(
        "SELECT kind, status, payload FROM v2_review_items WHERE namespace='user:one'",
      );
      expect(rows.length, 1);
      expect(rows.single['kind'], 'event');
      expect(rows.single['status'], 'open');
      expect(jsonDecode(rows.single['payload'] as String) as Map, {
        'sourceKey': 'sr',
        'eventId': 'event-r',
        'reason': 'reopened',
        'hasReading': true,
      });
      // Answered earlier, then moved back again: it opens once more.
      db.execute("UPDATE v2_review_items SET status='resolved'");
      await tester.runAsync(() => reopenForReview(ref, entry));
      rows = db.select('SELECT status FROM v2_review_items');
      expect(rows.length, 1);
      expect(rows.single['status'], 'open');
      // A transaction with no stored message cannot be put back.
      final bare = TransactionEntry(
        id: 'b',
        amount: Money.fromPaise(100),
        occurredAt: DateTime(2026, 11, 8),
        source: 'sms',
        status: 'active',
      );
      Object? failure;
      await tester.runAsync(() async {
        try {
          await reopenForReview(ref, bare);
        } catch (e) {
          failure = e;
        }
      });
      expect(failure, isA<ArgumentError>());
    });

    test(
      'failed and turned-down AI drafts are counted; ready ones are not',
      () async {
        final db = cache.financialStore.database.db;
        void put(String key, String status) => db.execute(
          'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?)',
          [
            'user:one',
            key,
            jsonEncode({'status': status}),
          ],
        );
        put('ai:a', 'failed');
        put('ai:b', 'rejected');
        put('ai:c', 'ready');
        db.execute(
          'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?)',
          [
            'user:two',
            'ai:z',
            jsonEncode({'status': 'failed'}),
          ],
        );
        expect(await container.read(aiUnreadCountProvider.future), 2);
      },
    );
  });

  testWidgets(
    'the AI auto-resolved tab lists the Gemini items with a plain note',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settledListsProvider.overrideWith(
              (ref) async => SettledLists(
                auto: [
                  SettledItem(
                    entry: _entry('g', 'sg', DateTime(2026, 11, 8)),
                    byUser: false,
                    source: SettledSource.ai,
                    how: 'Read by a Gemini AI rule, verified',
                  ),
                ],
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettledList(history: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Filed by Gemini AI'), findsOneWidget);
      expect(find.text('Shop g'), findsOneWidget);
      expect(find.text('Read by a Gemini AI rule, verified'), findsOneWidget);
    },
  );

  testWidgets('an empty AI tab says what will appear there', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settledListsProvider.overrideWith(
            (ref) async => const SettledLists(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SettledList(history: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing filed by Gemini yet'), findsOneWidget);
  });

  testWidgets('the AI header stays hidden with nothing to report', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: AiProgressHeader(openItems: 3)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('ai-progress-header')), findsNothing);
  });
}
