// Which card or account a movement is attributed to, end to end through the
// real pipeline, rules and stores:
//  - a credit card whose messages never print a number still becomes ONE source;
//  - an account or card the user rejected ("Not mine") stays rejected: later
//    messages are silent (no review item, nothing in the ledger), whether they
//    print the number short, long, or name the number only.
// Synthetic messages only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:test';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  late InstrumentStore instruments;
  var n = 0;

  late RuleBundle bundle;
  // Building the bundle reads every rule file: once per file, not per test.
  setUpAll(() => bundle = testRuleBundle());

  setUp(() {
    n = 0;
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: bundle,
      appVersion: '2.0.0',
    );
    instruments = InstrumentStore(db.db, namespace: _ns);
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SmsMessage sms(String sender, String body, {DateTime? at}) {
    final i = n++;
    return SmsMessage(
      sender: sender,
      body: body,
      sourceKey: i.toRadixString(16).padLeft(64, '0'),
      observedAt: at ?? DateTime.utc(2026, 11, 1, 7).add(Duration(days: i)),
    );
  }

  Instrument seeded(
    InstrumentKind kind,
    String issuer,
    String? mask, {
    InstrumentStatus status = InstrumentStatus.confirmed,
    String id = '44444444-4444-4444-8444-444444444444',
  }) {
    final t = DateTime.utc(2026, 1, 1);
    final i = Instrument(
      instrumentId: id,
      kind: kind,
      issuerSlug: issuer,
      maskDigits: mask,
      displayName: defaultDisplayName(defaultIssuerLabel(issuer), kind, mask),
      status: status,
      firstSeenAt: t,
      lastSeenAt: t,
      evidenceCount: 1,
    );
    instruments.upsert(i);
    return i;
  }

  int openInstrumentReviews() =>
      db.db
              .select(
                "SELECT COUNT(*) AS c FROM v2_review_items WHERE namespace=? AND kind='instrument' AND status='open'",
                [_ns],
              )
              .single['c']
          as int;

  String scapiaSpend(String store, String amount) =>
      'Hi! Your txn of ₹$amount at $store on your Scapia Federal Visa credit card was successful. '
      'Not you? Go to Scapia support on the app.- Federal Bank';

  group('a credit card that never prints its number', () {
    test('every spend is attributed to one card, not to "card not identified"', () {
      for (final (store, amount) in [
        ('EXAMPLE STORE', '1,200.00'),
        ('SAMPLE CAFE', '340.50'),
        ('DEMO TRAVEL', '2,000.00'),
      ]) {
        pipeline.process(sms('VM-FEDSCP-S', scapiaSpend(store, amount)));
      }
      final cards = instruments.list().where((i) => i.kind == InstrumentKind.creditCard).toList();
      expect(cards, hasLength(1));
      expect(cards.single.issuerSlug, 'federal');
      expect(cards.single.maskDigits, isNull);
      final spends = LedgerStore(db.db, namespace: _ns).list().where((e) => e.isSpend).toList();
      expect(spends, hasLength(3));
      for (final e in spends) {
        expect(e.from, isA<InstrumentEndpoint>(), reason: 'spend has a source');
        expect((e.from as InstrumentEndpoint).instrumentId, cards.single.instrumentId);
      }
    });

    test('its payment confirmation and a refund land on the same card', () {
      pipeline.process(sms('VM-FEDSCP-S', scapiaSpend('EXAMPLE STORE', '1,200.00')));
      pipeline.process(
        sms(
          'VM-FEDSCP-S',
          "Yay! We've received your payment of ₹1,200.00 towards your Scapia Federal credit card. -Federal Bank",
        ),
      );
      final cards = instruments.list().where((i) => i.kind == InstrumentKind.creditCard).toList();
      expect(cards, hasLength(1), reason: 'one card, not one per kind of message');
    });

    test('a message that is only a reminder does not invent a card', () {
      pipeline.process(
        sms(
          'VM-FEDSCP-S',
          'Reminder: please make your payment of ₹2,000.00 towards your Scapia Federal credit card by the due date. -Federal Bank',
        ),
      );
      expect(instruments.list().where((i) => i.kind == InstrumentKind.creditCard), isEmpty);
    });

    test('a failed transaction creates no card and no spend', () {
      pipeline.process(
        sms(
          'VM-FEDSCP-S',
          'Hi! Your txn of ₹1,200.00 at EXAMPLE STORE on your Scapia Federal Visa credit card was not successful. '
          'Not you? Go to Scapia support on the app.- Federal Bank',
        ),
      );
      expect(instruments.list().where((i) => i.kind == InstrumentKind.creditCard), isEmpty);
      expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
    });
  });

  group('an account the user said is not theirs stays out', () {
    // The template the rules count as a debit (the other India Post template is
    // read as "unknown"), so an empty ledger below is caused by the rejection.
    String debitBody(String digits) =>
        'Account No. XXXXXXXX$digits DEBIT with amount Rs.900.00 on 29-07-2026. Balance: Rs.514.00.[IN0000001]';
    const sender = 'BT-DOPBNK-G';

    test('control: the same alert for an account the user keeps is counted', () {
      seeded(InstrumentKind.bankAccount, 'indiapost', '1234');
      pipeline.process(sms(sender, debitBody('1234')));
      final entries = LedgerStore(db.db, namespace: _ns).list();
      expect(entries.where((e) => e.isSpend), hasLength(1));
    });

    test('a later alert is silent: no review item, nothing counted, still rejected', () {
      final rejected = seeded(InstrumentKind.bankAccount, 'indiapost', '1234', status: InstrumentStatus.rejected);
      pipeline.process(sms(sender, debitBody('1234')));
      expect(openInstrumentReviews(), 0);
      expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
      expect(instruments.list(), hasLength(1));
      expect(instruments.get(rejected.instrumentId)!.status, InstrumentStatus.rejected);
      final facts = FactStore(db.db, namespace: _ns);
      expect(facts.all(), isNotEmpty);
    });

    test('the same account printed longer is still the rejected one', () {
      seeded(InstrumentKind.bankAccount, 'indiapost', '551234', status: InstrumentStatus.rejected);
      pipeline.process(sms(sender, debitBody('1234')));
      expect(openInstrumentReviews(), 0);
      expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
      expect(instruments.list(), hasLength(1), reason: 'no second account appears');
    });

    test('a bank that only prints the number is not counted into an unknown account', () {
      seeded(InstrumentKind.bankAccount, 'indiapost', '1234', status: InstrumentStatus.rejected);
      pipeline.process(
        sms(
          'VM-GENBNK-S',
          'Rs: 4,100.00 has been transferred to your account XXXXXXX1234 on 05-Apr-2026. '
          'Please check with your bank for details. From Sample Bank',
        ),
      );
      expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
      expect(openInstrumentReviews(), 0);
    });

    test('the same notice for an account the user keeps is counted to that account', () {
      final live = seeded(InstrumentKind.bankAccount, 'sbi', '1234');
      pipeline.process(
        sms(
          'VM-GENBNK-S',
          'Rs: 4,100.00 has been transferred to your account XXXXXXX1234 on 05-Apr-2026. '
          'Please check with your bank for details. From Sample Bank',
        ),
      );
      final entries = LedgerStore(db.db, namespace: _ns).list();
      expect(entries, hasLength(1));
      expect((entries.single.to as InstrumentEndpoint).instrumentId, live.instrumentId);
    });

    test('rejecting one account does not hide another bank\'s account with other digits', () {
      seeded(InstrumentKind.bankAccount, 'indiapost', '1234', status: InstrumentStatus.rejected);
      pipeline.process(sms(sender, debitBody('9999')));
      expect(LedgerStore(db.db, namespace: _ns).list().where((e) => e.isSpend), hasLength(1));
    });
  });
}
