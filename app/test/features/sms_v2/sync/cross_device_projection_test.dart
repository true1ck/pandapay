// Lane P: an Android and an iPhone, each with its own SQLite store, receive the
// same server stream in different orders and with duplicates. They must show the
// same events, ledger, category totals, refund netting and review prompts, and a
// correction made on one phone must reach the other.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_service.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../support/rules.dart';
import '../support/sync_harness.dart';

void main() {
  final bundle = testRuleBundle();
  late Device uploader, android, iphone;
  late ServerLog server;

  setUp(() {
    uploader = Device('uploader');
    android = Device('android');
    iphone = Device('iphone');
    server = ServerLog();
    uploader.capture(bundle, sharedHistory(bundle));
    server.ingest(uploader);
  });
  tearDown(() {
    uploader.dispose();
    android.dispose();
    iphone.dispose();
  });

  test('the stream is rich enough to be a meaningful comparison', () {
    final view = digest(uploader);
    final totals = view['totals'] as Map;
    expect(server.length, greaterThan(300));
    expect((view['events'] as List).length, greaterThan(150));
    expect(totals['refund'], greaterThan(0), reason: 'refund netting is exercised');
    expect((totals['byCategory'] as Map).length, greaterThan(2));
  });

  test('different order and duplicates converge to identical state', () async {
    final pages = server.pages(size: 20);
    expect(pages.length, greaterThan(10));
    await android.receive(bundle, pages);
    await iphone.receive(bundle, shuffledWithDuplicates(pages, 99));
    final a = digest(android), i = digest(iphone);
    for (final key in a.keys) {
      expect(i[key], a[key], reason: key);
    }
    // And both agree with the phone that produced the stream.
    final source = digest(uploader);
    expect(a['ledger'], source['ledger']);
    expect(a['totals'], source['totals']);
    expect(a['events'], source['events']);
  });

  test('three different orders agree', () async {
    final pages = server.pages(size: 20);
    final reversed = pages.reversed.toList();
    final third = Device('third');
    addTearDown(third.dispose);
    await android.receive(bundle, pages);
    await iphone.receive(bundle, [...reversed, ...reversed]);
    await third.receive(bundle, shuffledWithDuplicates(pages, 7));
    expect(digest(iphone), digest(android));
    expect(digest(third), digest(android));
  });

  test('a correction on one phone reaches the other', () async {
    final pages = server.pages(size: 20);
    await android.receive(bundle, pages);
    await iphone.receive(bundle, shuffledWithDuplicates(pages, 3));
    expect(digest(iphone), digest(android));

    // The user recategorises a purchase that has a refund on the Android phone.
    final events = android.events.listSince(DateTime.utc(1900));
    final refund = events.firstWhere(
      (e) =>
          e.type == EventType.refund &&
          e.legs.any((l) => l.role == LegRole.original),
    );
    final originalFact = refund.legs
        .firstWhere((l) => l.role == LegRole.original)
        .factId;
    final purchase = events.firstWhere(
      (e) =>
          e.type != EventType.refund &&
          e.legs.any((l) => l.factId == originalFact),
    );
    final before = digest(android);
    String category(Map<String, Object?> view, String eventId) =>
        (view['categories'] as Map)[eventId] as String;
    final service = CorrectionsService(
      financial: android.financial,
      namespace: harnessNamespace,
      bundle: bundle,
    );
    String recategorise(Event event, String id) {
      final money = android.facts.get(event.eventId)!;
      final target = category(before, event.eventId).startsWith('groceries')
          ? 'dining'
          : 'groceries';
      service.apply(
        SmsCorrection(
          id: id,
          sourceKey: money.sourceKey,
          kind: CorrectionKind.wrongCategory,
          corrected: {
            'merchantKey': (money.counterparty?.name ?? 'MERCHANT')
                .toUpperCase(),
            'category': target,
          },
          trace: const DecisionTrace(
            appVersion: '2',
            engineVersion: '2.0.0',
            bundleVersion: 1,
            outcome: 'matched',
          ),
          factIds: [money.factId],
          eventId: event.eventId,
          reportCase: false,
        ),
      );
      return target;
    }

    // A purchase that was never refunded, so category totals must move.
    final refunded = {
      for (final e in events)
        if (e.type == EventType.refund)
          for (final l in e.legs)
            if (l.role == LegRole.original) l.factId,
    };
    final plain = events.firstWhere(
      (e) =>
          e.type == EventType.purchase &&
          !refunded.contains(e.eventId) &&
          e.eventId != purchase.eventId &&
          category(before, e.eventId) != 'other' &&
          android.facts.get(e.eventId)?.counterparty?.name !=
              android.facts.get(purchase.eventId)?.counterparty?.name,
    );
    final refundedTarget = recategorise(purchase, 'lane-p-refunded');
    final plainTarget = recategorise(plain, 'lane-p-plain');
    expect(
      category(digest(android), purchase.eventId),
      '$refundedTarget|user',
    );

    // Upload goes to the server; the iPhone receives it reordered and duplicated.
    final already = server.length;
    server.ingest(android);
    expect(server.length, greaterThan(already));
    final update = server.pages(size: 5, from: already);
    await android.receive(bundle, update); // the echo of its own change
    await iphone.receive(bundle, shuffledWithDuplicates(update, 11));

    final a = digest(android), i = digest(iphone);
    expect(category(i, purchase.eventId), '$refundedTarget|user');
    expect(category(i, plain.eventId), '$plainTarget|user');
    expect(
      category(i, refund.eventId),
      contains(refundedTarget),
      reason: 'the refund follows its purchase on the other phone',
    );
    for (final key in a.keys) {
      expect(i[key], a[key], reason: key);
    }
    // Spend moved between categories without changing the total.
    final beforeTotals = before['totals'] as Map;
    final afterTotals = i['totals'] as Map;
    expect(afterTotals['spend'], beforeTotals['spend']);
    expect(afterTotals['refund'], beforeTotals['refund']);
    expect(afterTotals['byCategory'], isNot(beforeTotals['byCategory']));
  });
}
