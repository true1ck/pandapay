import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Fact _fact(String id, String source, String engine) {
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

  test('rules and AI readings are Auto; user facts are History', () {
    final lists = settledLists(
      [
        _entry('a', 'sa', DateTime(2026, 11, 8)),
        _entry('b', 'sb', DateTime(2026, 11, 9)),
        _entry('c', 'sc', DateTime(2026, 11, 7)),
      ],
      {
        'sa': [_fact('fa', 'sa', 'rules')],
        'sb': [_fact('fb1', 'sb', 'rules'), _fact('fb2', 'sb', 'user')],
        'sc': [_fact('fc', 'sc', 'ai')],
      },
      now: now,
    );
    expect(lists.history.map((i) => i.entry.id), ['b']);
    expect(lists.history.single.byUser, isTrue);
    expect(lists.auto.map((i) => i.entry.id), ['a', 'c']);
    expect(lists.auto.last.how, 'Read by an AI rule');
    expect(lists.auto.first.how, 'Read by a rule');
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
        's$i': [_fact('f$i', 's$i', 'rules')],
    };
    final lists = settledLists(entries, facts, now: now);
    expect(lists.auto.length, settledMaxRows);
    expect(lists.auto.first.entry.id, 't0');
  });

  testWidgets('a card shows the shop, the amount and how it was settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
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
    );
    expect(find.text('Shop x'), findsOneWidget);
    expect(find.text('Read by a rule'), findsOneWidget);
    expect(find.textContaining('250'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
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
