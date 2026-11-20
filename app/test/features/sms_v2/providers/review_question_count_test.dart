// The count shown outside the Needs review screen (Insights card, import
// summary, notification) is the number of reviews LEFT: the questions the
// person still has to answer, which is what the screen's own tab says.
//
// It is worked out without building the review list (docs/PERFORMANCE_RULEBOOK.md
// R6), so these tests pin it to the page's number on one realistic account.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/providers/ai_status_provider.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/review_question_count.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/ui/review_clustering.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../support/ledger_dataset.dart';

void main() {
  late Dataset d;
  late ProviderContainer container;

  setUp(() {
    d = Dataset(3)..open();
    d.seed();
    SmsIntakeRepository(d.database); // creates the captured-message table
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(ns),
        responseCacheProvider.overrideWith((ref) async => d.cache),
        smsV2RuntimeProvider.overrideWith((ref) async => null),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    d.close();
  });

  void message(
    String source,
    String sender,
    String body,
  ) => d.database.db.execute(
    'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
    [
      ns,
      source,
      sender,
      body,
      DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
    ],
  );

  void open(
    String id,
    String kind,
    Map<String, Object?> payload,
  ) => d.database.db.execute(
    'INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)',
    [ns, id, kind, jsonEncode(payload), 'open'],
  );

  /// A format that has no reading yet, with its captured message.
  void template(
    String id,
    String hash, {
    String sender = 'VM-SBIUPI-S',
    String body = 'Rs.250.00 debited from A/c XX1234 on 05-11-26 Ref 1234',
    bool withMessage = true,
  }) {
    open(id, 'template', {'sourceKey': id, 'templateHash': hash});
    if (withMessage) message(id, sender, body);
  }

  void aiRead(String source, {required bool withReading}) {
    SyncStateStore(d.database.db, namespace: ns).put(
      'trace:$source',
      jsonEncode({'ruleId': 'AI-$source:local:${'a' * 64}'}),
    );
    if (withReading) {
      d.facts.insert(
        Fact.fromJson({
          ...fixture('fact/movement.card_spend.json'),
          'factId': hex(0x90000 + source.hashCode.abs() % 1000),
          'sourceKey': source,
        }),
      );
    }
  }

  Future<({int page, int outside})> numbers() async {
    final items = await container.read(reviewItemsProvider.future);
    final ai = await container.read(aiReviewStatusProvider.future);
    return (
      page: reviewQuestionCount([
        for (final item in items)
          if (ai.resolutionOf(item) == null) item,
      ], reviewKindOf),
      outside: await container.read(reviewQuestionCountProvider.future),
    );
  }

  test(
    'is the questions left: one per format, Pay Later merged, AI-read ones out',
    () async {
      for (var i = 0; i < 5; i++) {
        template(
          'same-$i',
          'h-same',
        ); // five messages, one format: one question
      }
      for (var i = 0; i < 3; i++) {
        // Three formats from one Pay Later provider: one question.
        template(
          'lazy-$i',
          'h-lazy-$i',
          sender: 'VK-LZYPAY',
          body: 'LazyPay bill $i of Rs.${100 + i}.00 is due on 10-11-26',
        );
      }
      template('other', 'h-other', body: 'Dear customer your plan renews soon');
      template(
        'gone',
        'h-gone',
        withMessage: false,
      ); // its text is no longer on the phone
      for (var i = 0; i < 2; i++) {
        open('receipt-$i', 'template', {
          'reason': kReceiptWithoutPaymentReason,
          'amountMinor': 21545 + i,
          'receiptAt': '2026-11-05T10:00:00Z',
        });
      }
      open('link-0', 'link', {'reason': 'ambiguous_link', 'candidates': []});
      // Read by an AI rule: the screen files it under "AI suggested", not here.
      template('ai-read', 'h-ai-read');
      aiRead('ai-read', withReading: true);
      // A leftover trace with no reading to go with it does not hide the message.
      template('ai-stale', 'h-ai-stale');
      aiRead('ai-stale', withReading: false);

      final n = await numbers();
      expect(
        n.page,
        1 + 1 + 1 + 1 + 2 + 1 + 1,
        reason:
            'same + pay later + other + gone + receipts + link + stale trace',
      );
      expect(
        n.outside,
        n.page,
        reason: 'the outside number is the page number',
      );
      final rows = d.database.db
          .select(
            "SELECT COUNT(*) AS n FROM v2_review_items WHERE status='open'",
          )
          .single['n'];
      expect(
        n.outside,
        lessThan(rows as int),
        reason: 'questions, not messages',
      );
    },
  );

  test('follows an answer: resolving a question lowers it by one', () async {
    template('a', 'h-a');
    template(
      'b',
      'h-b',
      body: 'Rs.9.00 debited on 05-11-26 for something else entirely',
    );
    expect(await container.read(reviewQuestionCountProvider.future), 2);
    d.database.db.execute(
      "UPDATE v2_review_items SET status='resolved' WHERE review_id='a'",
    );
    // Screens invalidate the list after an answer; the count follows it.
    container.invalidate(reviewItemsProvider);
    await container.read(reviewItemsProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(reviewQuestionCountProvider.future), 1);
    expect((await numbers()).page, 1);
  });

  test('the shared outside provider is this number', () async {
    template('a', 'h-a');
    template('b', 'h-a');
    template(
      'c',
      'h-c',
      body: 'A different message about another thing, Rs.5.00',
    );
    expect(await container.read(needsReviewCountProvider.future), 2);
  });

  test('nothing open is zero', () async {
    expect(await container.read(reviewQuestionCountProvider.future), 0);
  });
}
