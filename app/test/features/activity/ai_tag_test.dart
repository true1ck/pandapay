// The small "AI" tag on a transaction an AI-drafted rule read that PandaPay has not checked yet. Invented data only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_badge.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/providers/open_questions.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

Fact _fact({String engine = 'rules', String ruleId = 'AI-aaa111:local:abc'}) {
  final j =
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  j['provenance'] = <String, Object?>{
    ...(j['provenance'] as Map).cast<String, Object?>(),
    'engine': engine,
    'ruleId': ruleId,
  };
  return Fact.fromJson(j);
}

Event _event({bool confirmed = false}) {
  final name = confirmed
      ? 'card_bill_payment_user_confirmed'
      : 'card_bill_payment_complete';
  return Event.fromJson(
    (jsonDecode(
              File(
                '../contracts/sms/v2/fixtures/valid/event/$name.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>(),
  );
}

TransactionEntry _entry({bool ai = false}) => TransactionEntry(
  id: 'v2:e1',
  amount: Money.fromPaise(25000),
  occurredAt: DateTime(2026, 11, 8),
  merchantName: 'Shop one',
  source: 'sms',
  status: 'active',
  pipelineVersion: 2,
  aiUnverified: ai,
);

void main() {
  group('which readings carry the tag', () {
    test('an AI rule that exists only on this phone, not yet confirmed or edited: tagged', () {
      expect(isUnverifiedAiReading(_fact(), _event()), isTrue);
    });
    test('a verified AI rule (no :local: suffix) is not tagged', () {
      expect(isUnverifiedAiReading(_fact(ruleId: 'AI-aaa111'), _event()), isFalse);
    });
    test('a signed rule or the on-device reader is not tagged', () {
      expect(isUnverifiedAiReading(_fact(ruleId: 'BNK-RULE-1'), _event()), isFalse);
      expect(isUnverifiedAiReading(_fact(ruleId: 'SOLVER-GEN-1'), _event()), isFalse);
    });
    test('the person\'s own fact (an edit) or a confirmation ends it', () {
      expect(isUnverifiedAiReading(_fact(engine: 'user'), _event()), isFalse);
      expect(isUnverifiedAiReading(_fact(), _event(confirmed: true)), isFalse);
    });
  });

  group('the flag on the row', () {
    test('is saved with the row and absent (false) on older rows', () {
      expect(_entry(ai: true).toJson()['ai_unverified'], isTrue);
      expect(TransactionEntry.fromJson(_entry(ai: true).toJson()).aiUnverified, isTrue);
      expect(_entry().toJson().containsKey('ai_unverified'), isFalse);
      expect(TransactionEntry.fromJson(_entry().toJson()).aiUnverified, isFalse);
      expect(_entry(ai: true).copyWith(status: 'ignored').aiUnverified, isTrue);
    });
    test('is not a kind of money: txnBadgeKind never returns it', () {
      expect(txnBadgeKind(_entry(ai: true)), isNull);
      expect(TxnBadgeKind.aiUnverified.isTransfer, isFalse);
      expect(TxnBadgeKind.aiUnverified.label, 'AI');
    });
  });

  group('TransactionAiTag', () {
    Widget host(Widget child, {GoRouter? router, Set<String> open = const {}}) => ProviderScope(
      key: UniqueKey(),
      overrides: [openReviewKeysProvider.overrideWith((ref) async => open)],
      child: router == null
          ? MaterialApp(home: Scaffold(body: Center(child: child)))
          : MaterialApp.router(routerConfig: router),
    );

    testWidgets('shows "AI" for a tagged transaction and nothing otherwise', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: [
              TransactionAiTag(entry: _entry(ai: true)),
              TransactionAiTag(
                entry: TransactionEntry.fromJson({..._entry().toJson(), 'id': 'v2:plain'}),
              ),
            ],
          ),
        ),
      );
      expect(find.text('AI'), findsOneWidget);
      expect(find.byKey(const Key('ai-tag-v2:e1')), findsOneWidget);
      expect(find.byKey(const Key('ai-tag-v2:plain')), findsNothing);
    });

    testWidgets('no tag while the message is an open question on Needs review (it has no card in AI auto-resolved)', (tester) async {
      final tagged = TransactionEntry.fromJson({
        ..._entry(ai: true).toJson(),
        'source_key': 'src-1',
        'event_id': 'ev-1',
      });
      await tester.pumpWidget(host(TransactionAiTag(entry: tagged), open: {'src-1'}));
      await tester.pumpAndSettle();
      expect(find.text('AI'), findsNothing);
      await tester.pumpWidget(host(TransactionAiTag(entry: tagged), open: {'ev-1'}));
      await tester.pumpAndSettle();
      expect(find.text('AI'), findsNothing);
      await tester.pumpWidget(host(TransactionAiTag(entry: tagged), open: {'another'}));
      await tester.pumpAndSettle();
      expect(find.text('AI'), findsOneWidget);
    });

    testWidgets('the tap target is 44 dp, and the tag takes no more room than its pill', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(TransactionAiTag(entry: _entry(ai: true), onTap: () => taps++)),
      );
      await tester.pumpAndSettle();
      final pill = tester.getRect(find.byType(TransactionBadgePill));
      final taken = tester.getSize(find.byType(TapTargetPadding));
      expect(taken.width, closeTo(pill.width, 0.01), reason: 'layout is unchanged');
      expect(taken.height, closeTo(pill.height, 0.01));
      expect(pill.height, lessThan(44));
      // Just outside the pill, inside the 44 dp square around it.
      await tester.tapAt(pill.center + Offset(0.0, 21.0));
      expect(taps, 1);
      await tester.tapAt(pill.center + Offset(-20.0, 0.0));
      expect(taps, 2);
      // Beyond it: nothing.
      await tester.tapAt(pill.center + Offset(0.0, 40.0));
      expect(taps, 2);
    });

    testWidgets('tapping it calls onTap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(TransactionAiTag(entry: _entry(ai: true), onTap: () => taps++)),
      );
      await tester.tap(find.text('AI'));
      expect(taps, 1);
    });

    testWidgets('by default it opens AI auto-resolved on Needs review', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: TransactionAiTag(entry: _entry(ai: true))),
          ),
          GoRoute(
            path: '/activity/needs-review',
            builder: (_, state) => Scaffold(
              body: Text('review tab=${state.uri.queryParameters['tab']}'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(const SizedBox(), router: router));
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      expect(find.text('review tab=auto'), findsOneWidget);
    });
  });
}
