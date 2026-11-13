import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/personal/owner_identity_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/ai_withdrawal.dart';
import 'package:pandapay/features/sms_v2/pipeline/owner_recheck.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:owner';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsIntakeRepository intake;
  late OwnerIdentityStore store;
  final sent = <SmsMessage>[];

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    SmsV2Schema.ensure(db.db);
    final json = (jsonDecode(jsonEncode(testRuleBundle().toJson())) as Map)
        .cast<String, Object?>();
    json['solverPack'] =
        (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync()) as Map)
            .cast<String, Object?>();
    bundle = RuleBundle.fromJson(json);
    intake = SmsIntakeRepository(db);
    store = OwnerIdentityStore(db.db, namespace: _ns);
    sent.clear();
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SmsV2Pipeline pipeline() => SmsV2Pipeline(
    financial: financial,
    namespace: _ns,
    bundle: bundle,
    appVersion: '2.0.0',
    ownerNames: store.entries(),
  );

  /// Receives one SMS: keeps the original on the phone and reads it.
  void receive(String sender, String body, String day, {bool keep = true}) {
    final sms = QueuedSms(
      sender: sender,
      body: body,
      receivedAt: DateTime.parse('${day}T06:00:00Z'),
    );
    if (keep) intake.remember(_ns, sms);
    final m = SmsMessage(
      sender: sender,
      body: body,
      sourceKey: smsSourceKey(_ns, sender, body),
      observedAt: sms.receivedAt,
    );
    sent.add(m);
    pipeline().process(m, backfill: true);
  }

  List<String> rows() =>
      financial
          .entities(_ns, 'transactions')
          .map(TransactionEntry.fromJson)
          .where((t) => t.status == 'active')
          .map((t) => '${t.entryKind.name}:${t.amount.paise}')
          .toList()
        ..sort();

  /// The badge each transfer shows: "family:70000", "self:150000".
  List<String> badges() =>
      financial
          .entities(_ns, 'transactions')
          .map(TransactionEntry.fromJson)
          .where((t) => t.status == 'active' && t.entryKind == TxnEntryKind.transfer)
          .map((t) => '${t.transferType}:${t.amount.paise}')
          .toList()
        ..sort();

  /// What the sync does after the owner's identity changes.
  Future<int> recheck({bool revert = false}) async {
    final identity = OwnerIdentity.fromEntries(store.entries());
    final sources = OwnerRecheck(
      financial: financial,
      namespace: _ns,
      bundle: bundle,
    ).sourcesToRecheck(identity, revertUnmatched: revert);
    final taken = AiWithdrawal(
      financial: financial,
      namespace: _ns,
      bundle: bundle,
    ).withdraw(sources);
    final again = [
      for (final m in sent)
        if (taken.contains(m.sourceKey)) m,
    ];
    if (again.isNotEmpty) pipeline().processBatch(again, backfill: true);
    return taken.length;
  }

  const debitToOwn =
      'Sent Rs.1500.00 from Kotak Bank AC X9876 to asharao@okhdfcbank on 09-11-26.UPI Ref 100000000001. Not you, https://kotak.com/KBANKT/Fraud';
  const creditFromOwn =
      'Received Rs.700.00 in your Kotak Bank AC X9876 from asharao@okaxis on 10-11-26.UPI Ref:100000000002.';
  const creditFromSibling =
      'Received Rs.900.00 in your Kotak Bank AC X9876 from KABIR MARIA RAO on 12-11-26.UPI Ref:100000000003.';
  const debitToShop =
      'Sent Rs.250.00 from Kotak Bank AC X9876 to paytm.q123abc@pty on 11-11-26.UPI Ref 100000000004. Not you, https://kotak.com/KBANKT/Fraud';

  test('before the owner is known, payments to themselves count as spend and income', () {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    receive('AD-KOTAKB', creditFromOwn, '2026-11-10');
    expect(rows(), ['income:70000', 'spend:150000']);
  });

  test('typing a name turns their own payments into transfers, and only those', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    receive('AD-KOTAKB', creditFromOwn, '2026-11-10');
    receive('AD-KOTAKB', debitToShop, '2026-11-11');
    receive('AD-KOTAKB', creditFromSibling, '2026-11-12');

    store.addName(first: 'Asha', last: 'Rao');
    final n = await recheck();

    expect(n, 2, reason: 'only the two messages that changed are read again');
    expect(rows(), [
      'income:90000', // the sibling's money is still income
      'spend:25000', // the shop is still spend
      'transfer:150000',
      'transfer:70000',
    ]);
  });

  test('without a usable owner name nothing is re-read', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    expect(await recheck(), 0);
    expect(rows(), ['spend:150000']);
  });

  test('a name typed twice is harmless', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    store.addName(first: 'Asha', last: 'Rao');
    await recheck();
    expect(await recheck(), 0, reason: 'nothing left to change');
    expect(rows(), ['transfer:150000']);
  });

  test('both legs of one transfer become ONE transfer, not two', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    receive(
      'AD-HDFCBK',
      'Credit Alert! Rs.1500.00 credited to HDFC Bank A/c xx5678 on 09-11-26 from VPA asharao@okaxis (UPI 222222222222)',
      '2026-11-09',
    );
    store.addName(first: 'Asha', last: 'Rao');
    await recheck();
    final r = rows();
    expect(r.where((e) => e.startsWith('spend') || e.startsWith('income')), isEmpty, reason: '$r');
    expect(r.where((e) => e.startsWith('transfer')), hasLength(1), reason: '$r');
  });

  test('a message whose original is no longer on the phone is left exactly as it is', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09', keep: false);
    store.addName(first: 'Asha', last: 'Rao');
    expect(await recheck(), 0);
    expect(rows(), ['spend:150000']);
  });

  test('marking a payee as their own works with no name at all', () async {
    receive('AD-KOTAKB', debitToShop, '2026-11-11');
    expect(rows(), ['spend:25000']);
    store.markOwn(vpa: 'paytm.q123abc@pty');
    expect(await recheck(), 1);
    expect(rows(), ['transfer:25000']);
  });

  test('"not me" takes a payment back out of transfers', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    store.addName(first: 'Asha', last: 'Rao');
    await recheck();
    expect(rows(), ['transfer:150000']);

    store.markNotOwn(vpa: 'asharao@okhdfcbank');
    expect(await recheck(), 1);
    expect(rows(), ['spend:150000']);
  });

  test('removing a name puts the payments back, when asked to look', () async {
    receive('AD-KOTAKB', debitToOwn, '2026-11-09');
    store.addName(first: 'Asha', last: 'Rao');
    await recheck();
    expect(rows(), ['transfer:150000']);

    store.remove('ASHA RAO');
    expect(await recheck(), 0, reason: 'by default only a rejection reverts');
    expect(await recheck(revert: true), 1);
    expect(rows(), ['spend:150000']);
  });

  group('family and single payments', () {
    const debitToShopAgain =
        'Sent Rs.350.00 from Kotak Bank AC X9876 to paytm.q123abc@pty on 13-11-26.UPI Ref 100000000005. Not you, https://kotak.com/KBANKT/Fraud';

    test('a family member the person marks is a transfer with a Family badge, and only they', () async {
      receive('AD-KOTAKB', creditFromSibling, '2026-11-12');
      receive('AD-KOTAKB', debitToShop, '2026-11-11');
      expect(rows(), ['income:90000', 'spend:25000']);

      store.markFamily(name: 'Kabir Maria Rao');
      expect(await recheck(), 1);
      expect(rows(), ['spend:25000', 'transfer:90000']);
      expect(badges(), ['family:90000']);
    });

    test('a payee already counted as your own can be moved to family and back', () async {
      receive('AD-KOTAKB', debitToOwn, '2026-11-09');
      store.addName(first: 'Asha', last: 'Rao');
      await recheck();
      expect(badges(), ['self:150000']);

      store.markFamily(vpa: 'asharao@okhdfcbank');
      expect(await recheck(), 1);
      expect(badges(), ['family:150000']);
      expect(rows(), ['transfer:150000']);

      store.unmarkFamily(vpa: 'asharao@okhdfcbank');
      expect(await recheck(), 1);
      expect(badges(), ['self:150000']);
    });

    test('unmarking family puts a plain payee back into spending', () async {
      receive('AD-KOTAKB', debitToShop, '2026-11-11');
      store.markFamily(vpa: 'paytm.q123abc@pty');
      await recheck();
      expect(badges(), ['family:25000']);

      store.unmarkFamily(vpa: 'paytm.q123abc@pty');
      expect(await recheck(revert: true), 1);
      expect(rows(), ['spend:25000']);
    });

    test('"only this payment" changes that payment and leaves the payee alone', () async {
      receive('AD-KOTAKB', debitToShop, '2026-11-11');
      receive('AD-KOTAKB', debitToShopAgain, '2026-11-13');
      final first = smsSourceKey(_ns, 'AD-KOTAKB', debitToShop);

      store.markOnce(sourceKey: first, family: true);
      expect(await recheck(), 1);
      expect(rows(), ['spend:35000', 'transfer:25000']);
      expect(badges(), ['family:25000']);

      // Taking it back puts that one payment back.
      store.clearOnce(first);
      expect(await recheck(revert: true), 1);
      expect(rows(), ['spend:25000', 'spend:35000']);
    });

    test('a single payment can be marked as one of your own accounts instead', () async {
      receive('AD-KOTAKB', debitToShop, '2026-11-11');
      store.markOnce(
        sourceKey: smsSourceKey(_ns, 'AD-KOTAKB', debitToShop),
        family: false,
      );
      expect(await recheck(), 1);
      expect(badges(), ['self:25000']);
    });

    test('a payment marked only-self stays Self even if its payee is family', () async {
      receive('AD-KOTAKB', debitToShop, '2026-11-11');
      store.markFamily(vpa: 'paytm.q123abc@pty');
      await recheck();
      expect(badges(), ['family:25000']);
      store.markOnce(
        sourceKey: smsSourceKey(_ns, 'AD-KOTAKB', debitToShop),
        family: false,
      );
      expect(await recheck(), 1);
      expect(badges(), ['self:25000']);
    });
  });
}
