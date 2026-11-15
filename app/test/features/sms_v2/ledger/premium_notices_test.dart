import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/premium_reminders.dart';
import 'package:pandapay/features/sms_v2/ledger/premium_notices.dart';
import 'package:sqlite3/sqlite3.dart';

// Synthetic wording only: the repository is public.
const _notice = 'Dear Policyholder, your Next Premium falls due on 09/2026 for '
    'Policy No. 123456789. Pay online. -INSCO';

PremiumNotice? read(String body, {String key = 'k1', DateTime? at}) =>
    premiumNoticeFromSms(
      sourceKey: key,
      sender: 'VM-INSCO-S',
      body: body,
      receivedAt: at ?? DateTime(2026, 8, 20),
    );

Database db() {
  final d = sqlite3.openInMemory();
  d.execute('''
    CREATE TABLE v2_sync_state(namespace TEXT, key TEXT, value TEXT,
      PRIMARY KEY(namespace,key));
    CREATE TABLE sms_captured_messages(namespace TEXT, id TEXT, sender TEXT,
      body TEXT, received_at INTEGER, PRIMARY KEY(namespace,id));
  ''');
  return d;
}

void main() {
  group('premiumNoticeFromSms', () {
    test('reads the month and the policy digits, never a day', () {
      final n = read(_notice)!;
      expect(n.month, DateTime(2026, 9));
      expect(n.policyLast4, '6789');
    });

    test('also reads a named month', () {
      final n = read('Your Next Premium is due in Sep 2026. -INSCO')!;
      expect(n.month, DateTime(2026, 9));
    });

    test('a message with an amount is a payable bill, not a notice', () {
      expect(
        read('Next Premium falls due on 09/2026. Amount Rs 5,000.'),
        isNull,
      );
    });

    test('other messages are ignored', () {
      expect(read('Your OTP is 123456'), isNull);
      expect(read('Next premium will be intimated shortly'), isNull);
    });
  });

  group('PremiumNoticeStore', () {
    test('saves, reads back, and replaces the same message', () {
      final store = PremiumNoticeStore(db(), namespace: 'u1');
      store.save(read(_notice)!);
      store.save(read(_notice)!);
      final all = store.all();
      expect(all, hasLength(1));
      expect(all.single.month, DateTime(2026, 9));
      expect(all.single.sender, 'VM-INSCO-S');
    });

    test('keeps one account apart from another', () {
      final d = db();
      PremiumNoticeStore(d, namespace: 'u1').save(read(_notice)!);
      expect(PremiumNoticeStore(d, namespace: 'u2').all(), isEmpty);
    });

    test('the one-time scan finds only notices among captured messages', () {
      final d = db();
      d.execute(
        'INSERT INTO sms_captured_messages VALUES(?,?,?,?,?)',
        ['u1', 'a', 'VM-INSCO-S', _notice, DateTime(2026, 8, 20).millisecondsSinceEpoch],
      );
      d.execute(
        'INSERT INTO sms_captured_messages VALUES(?,?,?,?,?)',
        ['u1', 'b', 'VM-BANK-S', 'Rs 10 spent at a shop', 1],
      );
      final store = PremiumNoticeStore(d, namespace: 'u1');
      expect(store.scanCaptured(), 1);
      expect(store.all().single.sourceKey, 'a');
    });
  });

  group('shown on the Bills page', () {
    final now = DateTime(2026, 11, 15);
    PremiumNotice at(String key, String body, DateTime got) =>
        read(body, key: key, at: got)!;

    test('a month still ahead is an upcoming reminder', () {
      final upcoming = at(
        'u',
        'Your Next Premium falls due on 12/2026 for Policy No. 123456789.',
        DateTime(2026, 11, 2),
      );
      final reminders = derivePremiumReminders(
        observations: [upcoming.toObservation()],
        now: now,
      );
      expect(reminders.single.premiumMonth, DateTime(2026, 12));
    });

    test('a month gone by is past history that needs confirming', () {
      final old = read(_notice, at: DateTime(2026, 8, 20))!; // 09/2026
      expect(
        derivePremiumReminders(observations: [old.toObservation()], now: now),
        isEmpty,
      );
      final past = pastPremiumReceiptsFromNotices([old], now);
      expect(past.single.status, PastBillReceiptStatus.needsConfirmation);
      expect(past.single.accountLast4, '6789');
    });

    test('the current month is still a reminder, not history', () {
      final nov = at(
        'n',
        'Your Next Premium falls due on 11/2026 for Policy No. 123456789.',
        DateTime(2026, 10, 25),
      );
      expect(pastPremiumReceiptsFromNotices([nov], now), isEmpty);
      expect(
        derivePremiumReminders(observations: [nov.toObservation()], now: now),
        hasLength(1),
      );
    });

    test('two notices for one policy and month are one past row', () {
      final a = at('a', _notice, DateTime(2026, 8, 1));
      final b = at('b', _notice, DateTime(2026, 8, 20));
      final past = pastPremiumReceiptsFromNotices([a, b], now);
      expect(past, hasLength(1));
      expect(past.single.sourceKey, 'b');
    });
  });
}
