// When an AI reading needs the person (the AI is unsure, or its reading contradicts its own message), which
// open questions are AI auto-resolved instead, and the dismissal store. All data is invented.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart' show SmsIntakeEntry;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TransactionEntry;
import 'package:pandapay/features/sms_v2/pipeline/ai_doubt.dart';
import 'package:pandapay/features/sms_v2/pipeline/review_content.dart';
import 'package:pandapay/features/sms_v2/providers/ai_review_doubt.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/dismissal_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/ui/auto_dismissal_actions.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Fact _spend(
  String id, {
  String source = 's',
  String direction = 'debit',
  double confidence = .95,
  bool evidenceOnly = false,
  String ruleId = 'AI-aaa111:local:abc',
}) {
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
  j['confidence'] = confidence;
  j['attrs'] = <String, Object?>{
    ...(j['attrs'] as Map).cast<String, Object?>(),
    'direction': direction,
    if (evidenceOnly) 'evidenceOnly': true,
  };
  j['provenance'] = <String, Object?>{
    ...(j['provenance'] as Map).cast<String, Object?>(),
    'ruleId': ruleId,
  };
  return Fact.fromJson(j);
}

LocalReviewItem _template(
  String source, {
  bool hasReading = true,
  String? reason,
}) => LocalReviewItem(
  id: '$source:0',
  kind: 'template',
  payload: {
    'sourceKey': source,
    'hasReading': hasReading,
    'reason': ?reason,
  },
  message: null,
);

void main() {
  group('the wording of a message gives a direction only when it is clear', () {
    test('one family of verbs: money out or money in', () {
      expect(wordingDirection('Rs.450.00 debited from A/c XX1234 on 20-11-26'), Direction.debit);
      expect(wordingDirection('Rs.450.00 credited to A/c XX1234 on 20-11-26'), Direction.credit);
    });
    test('both families, no verb, declined, OTP or balance notices give none', () {
      expect(wordingDirection('Rs.450 debited and will be credited back in 3 days'), isNull);
      expect(wordingDirection('Your plan renews soon'), isNull);
      expect(wordingDirection('Payment of Rs.450 declined: insufficient balance'), isNull);
      expect(wordingDirection('OTP 123456 for a credited amount. Do not share'), isNull);
      expect(wordingDirection('Avl bal Rs.4,500 as of 20-11-26'), isNull);
    });
  });

  group('aiDoubtOf', () {
    const credited = 'Rs.450.00 credited to your A/c XX1234 on 20-11-26.';
    const debited = 'Rs.450.00 debited from your A/c XX1234 on 20-11-26.';

    test('a confident reading that agrees with its message is not a question', () {
      expect(aiDoubtOf([_spend('a')], body: debited), isNull);
      expect(aiDoubtOf([_spend('a', direction: 'credit')], body: credited), isNull);
    });
    test('low confidence on any fact is a question', () {
      expect(aiDoubtOf([_spend('a'), _spend('b', confidence: .69)]), AiDoubt.lowConfidence);
      expect(aiDoubtOf([_spend('a', confidence: .7)]), isNull, reason: 'the floor is .7, not above it');
    });
    test('a debit read from a message that says credited (and the reverse) is a question', () {
      expect(aiDoubtOf([_spend('a')], body: credited), AiDoubt.directionConflict);
      expect(aiDoubtOf([_spend('a', direction: 'credit')], body: debited), AiDoubt.directionConflict);
    });
    test('narrow on purpose: no message text, an unclear message or evidence-only movement never conflict', () {
      expect(aiDoubtOf([_spend('a')]), isNull, reason: 'no text: only confidence can be judged');
      expect(aiDoubtOf([_spend('a')], body: 'Your bill is ready'), isNull);
      expect(aiDoubtOf([_spend('a', evidenceOnly: true)], body: credited), isNull);
      expect(
        aiDoubtOf([_spend('a'), _spend('b', direction: 'credit')], body: credited),
        isNull,
        reason: 'one movement agrees with the words: consistent',
      );
    });
  });

  group('wordings the review found (invented messages)', () {
    // wording -> the direction its own words give (null: not clear)
    final directions = <String, Direction?>{
      'Refund of Rs 500.00 for your purchase at SHOP credited to your card XX1234.': Direction.credit,
      'Rs 200 debited from A/c XX1234 was reversed and credited back to your account on 12-Nov.': Direction.credit,
      'Reversal of Rs 300 for txn at SHOP processed to A/c XX1234.': Direction.credit,
      'John sent Rs 300 to you via UPI': Direction.credit,
      'Rs 1000 transferred to your account XX1234 from XYZ': Direction.credit,
      'Rs 300 debited from A/c XX1234 Avl Bal Rs 5000. Not you? Call 1800': Direction.debit,
      'Rs 450 sent to SHOP from A/c XX1234': Direction.debit,
      'Rs 500 debited and will be credited back in 3 days': null,
      'Paid Rs 300 to SHOP, received by SHOP UPI Ref 1234': null,
      'Rs 500 A/c XX1234 UPI Ref 123 SHOP': null,
    };
    directions.forEach((body, expected) {
      test('direction of "$body" is $expected', () => expect(wordingDirection(body), expected));
    });

    test('a debit read from a refund, a reversal or money sent to you is a direction conflict', () {
      for (final body in [
        'Refund of Rs 500.00 for your purchase at SHOP credited to your card XX1234.',
        'Rs 200 debited from A/c XX1234 was reversed and credited back to your account on 12-Nov.',
        'John sent Rs 300 to you via UPI',
        'Rs 1000 transferred to your account XX1234 from XYZ',
      ]) {
        expect(aiDoubtOf([_spend('a')], body: body), AiDoubt.directionConflict, reason: body);
      }
      // ...and a credit read from them is not.
      expect(aiDoubtOf([_spend('a', direction: 'credit')], body: 'John sent Rs 300 to you via UPI'), isNull);
    });

    test('money that has not moved (a future debit, a request, a pending payment) must not be booked silently', () {
      for (final body in [
        'Your EMI of Rs 2000 will be debited on 5 Nov from A/c XX1234',
        'ABC has requested Rs 500 from you on UPI. Approve in your app. Ref 123',
        'UPI txn of Rs 300 to SHOP is pending',
        'A debit of Rs 700 is scheduled for 9 Nov',
        'OTP 4321 for txn of Rs 500 at SHOP. Do not share',
      ]) {
        expect(aiDoubtOf([_spend('a')], body: body), AiDoubt.notMovedYet, reason: body);
      }
      // A charge that is merely worded as a mandate is a real charge.
      expect(aiDoubtOf([_spend('a')], body: 'Rs 200 has been debited via AutoPay mandate to NETFLIX'), isNull);
      // Only a real movement is doubted: a reading that is not a movement is not.
      expect(aiDoubtOf([_spend('a', evidenceOnly: true)], body: 'Rs 300 is pending'), isNull);
    });
  });

  group('which open questions are AI auto-resolved', () {
    test('confident: settled; unsure and reopened stay on Needs review', () {
      final items = [
        _template('sure'),
        _template('low'),
        _template('asked', reason: 'reopened'),
        _template('rule'), // a signed rule read it, not an AI rule
        _template('none', hasReading: false),
      ];
      final facts = {
        'sure': [_spend('f1', source: 'sure')],
        'low': [_spend('f2', source: 'low', confidence: .5)],
        'asked': [_spend('f4', source: 'asked')],
        'rule': [_spend('f5', source: 'rule', ruleId: 'BNK-RULE-1')],
      };
      final r = classifyOpenAiReadings(
        items: items,
        aiRead: {'sure', 'low', 'asked', 'none'},
        factsBySource: facts,
      );
      expect(r.confident, {'sure'});
      expect(r.doubtful, {
        'low': AiDoubt.lowConfidence,
        'asked': AiDoubt.reopened,
      });
      expect(r.settles(items.first), isTrue);
      expect(r.settles(items[1]), isFalse);
      expect(r.settles(items[3]), isFalse, reason: 'not read by an AI rule: an ordinary question');
    });

    test('a direction conflict is found from the message text the item carries', () {
      LocalReviewItem withText(String body) => LocalReviewItem(
        id: 'x:0',
        kind: 'template',
        payload: {'sourceKey': 'x', 'hasReading': true},
        message: SmsIntakeEntry(
          'x',
          QueuedSms(sender: 'AX-SYNTHBK', body: body, receivedAt: DateTime.utc(2026, 11, 20)),
        ),
      );
      final facts = {
        'x': [_spend('g', source: 'x')],
      };
      final credited = classifyOpenAiReadings(
        items: [withText('Rs.450.00 credited to your A/c XX1234.')],
        aiRead: {'x'},
        factsBySource: facts,
      );
      expect(credited.doubtful, {'x': AiDoubt.directionConflict});
      expect(credited.confident, isEmpty);
      final debited = classifyOpenAiReadings(
        items: [withText('Rs.450.00 debited from your A/c XX1234.')],
        aiRead: {'x'},
        factsBySource: facts,
      );
      expect(debited.confident, {'x'});
    });
  });

  group('dismissals', () {
    late Database db;
    late DismissalStore store;
    final at = DateTime.utc(2026, 11, 20, 9);

    setUp(() {
      db = sqlite3.openInMemory();
      SmsV2Schema.ensure(db);
      store = DismissalStore(SyncStateStore(db, namespace: 'user:a'));
    });
    tearDown(() => db.dispose());

    test('a record round-trips, remembers its origin and kind, and is per account', () {
      store.put(
        AutoDismissal(
          sourceKey: 'tx1',
          kind: AutoDismissal.kindTransaction,
          dismissedAt: at,
          entryId: 'v2:e1',
          eventId: 'e1',
        ),
      );
      dismissRead(store: store, sourceKey: 'read1', at: at);
      final all = {for (final d in store.all()) d.sourceKey: d};
      expect(all.keys, {'tx1', 'read1'});
      expect(all['tx1']!.origin, AutoDismissal.originAutoResolved);
      expect(all['tx1']!.entryId, 'v2:e1');
      expect(all['tx1']!.eventId, 'e1');
      expect(all['read1']!.kind, AutoDismissal.kindRead);
      expect(DismissalStore(SyncStateStore(db, namespace: 'user:b')).all(), isEmpty);
      store.remove('read1');
      expect(store.get('read1'), isNull);
      // Other sync-state keys are not mistaken for records.
      SyncStateStore(db, namespace: 'user:a').put('trace:zzz', '{}');
      SyncStateStore(db, namespace: 'user:a').put('dismissal:bad', 'not json');
      expect(store.all().map((d) => d.sourceKey), ['tx1']);
    });

    test('a read: Dismiss then Recover puts it back in AI auto-resolved', () async {
      dismissRead(store: store, sourceKey: 'read1', at: at);
      final to = await recoverDismissed(
        store: store,
        record: store.get('read1')!,
        aiStillReads: true,
        restore: () async => fail('a read has nothing to restore'),
        decidedAt: () => null,
        sendToReview: () async => fail('stays in AI auto-resolved'),
      );
      expect(to, RecoveredTo.autoResolved);
      expect(store.all(), isEmpty);
    });

    test('a read whose AI rule is gone falls back to Needs review', () async {
      dismissRead(store: store, sourceKey: 'read1', at: at);
      final sent = <String>[];
      final to = await recoverDismissed(
        store: store,
        record: store.get('read1')!,
        aiStillReads: false,
        restore: () async => true,
        decidedAt: () => null,
        sendToReview: () async => sent.add('read1'),
      );
      expect(to, RecoveredTo.needsReview);
      expect(sent, ['read1']);
      expect(store.all(), isEmpty);
    });

    test('a transaction whose restore fails falls back to Needs review', () async {
      store.put(
        AutoDismissal(
          sourceKey: 'tx1',
          kind: AutoDismissal.kindTransaction,
          dismissedAt: at,
          entryId: 'v2:e1',
        ),
      );
      var sent = 0;
      final to = await recoverDismissed(
        store: store,
        record: store.get('tx1')!,
        aiStillReads: true,
        restore: () async => throw StateError('no saved reading'),
        decidedAt: () => null,
        sendToReview: () async => sent++,
      );
      expect(to, RecoveredTo.needsReview);
      expect(sent, 1);
    });

    test('a restore that did not take (the account changed) keeps the row and stamps nothing', () async {
      store.put(
        AutoDismissal(
          sourceKey: 'tx1',
          kind: AutoDismissal.kindTransaction,
          dismissedAt: at,
          entryId: 'v2:e1',
          eventId: 'e1',
        ),
      );
      final to = await recoverDismissed(
        store: store,
        record: store.get('tx1')!,
        aiStillReads: true,
        restore: () async => false,
        decidedAt: () => '2026-11-21T10:00:00Z',
        sendToReview: () async => fail('not Needs review'),
      );
      expect(to, RecoveredTo.unchanged);
      expect(store.get('tx1')!.restored, isFalse);
      expect(store.get('tx1')!.restoredDecidedAt, isNull);
    });

    test('a failed hide leaves no record (History never lists what is still counted)', () async {
      final entry = TransactionEntry(
        id: 'v2:e1',
        amount: const Money.zero(),
        occurredAt: at,
        sourceKey: 'tx1',
        eventId: 'e1',
        source: 'sms',
        status: 'active',
        pipelineVersion: 2,
      );
      await expectLater(
        dismissTransaction(
          store: store,
          entry: entry,
          at: at,
          hide: () async => throw StateError('could not hide'),
        ),
        throwsStateError,
      );
      expect(store.all(), isEmpty);
    });
  });
}
