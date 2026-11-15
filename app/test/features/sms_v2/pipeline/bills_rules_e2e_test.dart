// The whole chain for the Bills page, with the REAL rule folder: a message is
// read by the rules, saved as facts by the pipeline, and the app turns the typed
// facts into rows. No fact is built by hand here, so a reworded alert that the
// rules read is a row on the page, and one they do not read is not.
// Every message is synthetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/ledger/premium_notices.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../../../tools/sms_rules_cli/lib/rules_source.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  late RuleBundle bundle;
  late RulesSource source;
  var n = 0;

  setUpAll(() {
    source = readRulesFolder('../rules/sms/v2');
    expect(source.problems, isEmpty);
    bundle = parseUnsignedBundle(source.bundle);
  });

  setUp(() {
    n = 0;
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: 'user:test',
      bundle: bundle,
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  /// A message read on [at] (UTC) from [sender].
  void read(String sender, String body, DateTime at) {
    n++;
    pipeline.process(
      SmsMessage(
        sender: sender,
        body: body,
        observedAt: at,
        sourceKey: n.toString().padLeft(64, '0'),
      ),
    );
  }

  List<Commitment> rows(DateTime now) {
    final facts = FactStore(db.db, namespace: 'user:test').all();
    final events = EventStore(db.db, namespace: 'user:test')
        .listSince(DateTime.utc(2000));
    return billsFromFacts(facts, events, now: now);
  }

  List<PremiumNotice> notices() =>
      premiumNoticesFromFacts(FactStore(db.db, namespace: 'user:test').all());

  final nov1 = DateTime.utc(2026, 11, 1, 4);
  final now = DateTime(2026, 11, 2, 12);

  test('a SIP instalment the fund announced is a SIP row on its date', () {
    read(
      'VM-FUNDCO-S',
      'Your monthly SIP of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.',
      nov1,
    );
    final sip = rows(now).single;
    expect(sip.category, CommitmentCategory.investment);
    expect(sip.title, 'Sunrise Equity Fund');
    expect(sip.dueOn, DateTime(2026, 11, 5));
    expect(sip.amount!.paise, 500000);
    expect(sip.cadence, CommitmentCadence.monthly);
    expect(sip.status, CommitmentStatus.due);
  });

  test('the same reminder twice, or read again, is still one row', () {
    const body =
        'Your monthly SIP of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.';
    read('VM-FUNDCO-S', body, nov1);
    read('VM-FUNDCO-S', body, nov1.add(const Duration(days: 3)));
    read('VM-FUNDCO-S', body, nov1); // the very same message again
    expect(rows(now), hasLength(1));
  });

  test('a past-tense debit is never a scheduled row', () {
    read(
      'VM-FUNDCO-S',
      'Your SIP instalment of Rs 5,000 in Sunrise Equity Fund was debited from your bank account on 05-Nov-26.',
      nov1,
    );
    expect(rows(now), isEmpty);
  });

  test('an EMI the lender announced is a loan row with its account', () {
    read(
      'VM-GENBNK-S',
      'Dear Customer, your loan EMI of Rs.12,345.00 will be debited from A/c XX1234 on 07-Nov-26. Please maintain sufficient balance.',
      nov1,
    );
    final emi = rows(now).single;
    expect(emi.category, CommitmentCategory.loanOrEmi);
    expect(emi.dueOn, DateTime(2026, 11, 7));
    expect(emi.amount!.paise, 1234500);
    expect(emi.cadence, CommitmentCadence.monthly);
  });

  test('an EMI due notice on a loan account is under Loans and EMIs', () {
    read(
      'VM-GENBNK-S',
      'Your EMI of Rs 12,345 for your Personal Loan A/c XX1234 is due on 05-Nov-26. Please maintain sufficient balance.',
      nov1,
    );
    final emi = rows(now).single;
    expect(emi.category, CommitmentCategory.loanOrEmi);
    expect(emi.identifier, '1234');
    expect(emi.dueOn, DateTime(2026, 11, 5));
  });

  test('an insurance premium debit notice is an insurance row, any insurer', () {
    read(
      'VM-INSCOX-S',
      'Dear Customer, your Sunrise Life Insurance premium of Rs 2,500 for policy no 123456789 will be auto-debited from your account on 25-11-2026.',
      nov1,
    );
    final p = rows(now).single;
    expect(p.category, CommitmentCategory.insurance);
    expect(p.title, 'Sunrise Life Insurance');
    expect(p.dueOn, DateTime(2026, 11, 25));
    expect(p.cadence, CommitmentCadence.oneTime);
  });

  test('a month-only premium notice is a notice, never a bill with a day', () {
    read(
      'VM-INSCOX-S',
      'Dear Policyholder, policy no. 123456789 Next Premium falls due on 12/2026. Please pay on time.',
      nov1,
    );
    expect(rows(now), isEmpty); // no dated bill, no amount to invent
    final notice = notices().single;
    expect(notice.month, DateTime(2026, 12));
    expect(notice.category, CommitmentCategory.insurance);
    expect(notice.policyLast4, '6789');
  });

  test('every kind of notice together, each in its own place', () {
    read(
      'VM-FUNDCO-S',
      'Your monthly SIP of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.',
      nov1,
    );
    read(
      'VM-GENBNK-S',
      'Dear Customer, your loan EMI of Rs.12,345.00 will be debited from A/c XX1234 on 07-Nov-26. Please maintain sufficient balance.',
      nov1,
    );
    read(
      'VM-INSCOX-S',
      'Dear Customer, your Sunrise Life Insurance premium of Rs 2,500 for policy no 123456789 will be auto-debited from your account on 25-11-2026.',
      nov1,
    );
    read(
      'VM-INSCOX-S',
      'Dear Policyholder, your Next Premium is due in September 2026. Pay online to avoid lapse.',
      nov1,
    );
    expect(
      {for (final r in rows(now)) r.category},
      {
        CommitmentCategory.investment,
        CommitmentCategory.loanOrEmi,
        CommitmentCategory.insurance,
      },
    );
    expect(notices().single.month, DateTime(2026, 9)); // already past
  });

  test('a receipt that also mentions the next month is not a notice', () {
    read(
      'VM-INSCOX-S',
      'Premium of Rs 2,500 received for policy no 123456789. Next Premium falls due on 09/2026.',
      nov1,
    );
    expect(notices(), isEmpty);
  });

  test('a message read before the rule existed is read again when it ships', () {
    const body =
        'Dear Policyholder, policy no. 123456789 Next Premium falls due on 12/2026. Please pay on time.';
    // The rule folder as it was before this rule.
    final without = parseUnsignedBundle({
      ...source.bundle,
      'rules': [
        for (final r in source.bundle['rules'] as List)
          if ((r as Map)['id'] != 'GENZ-INS-PREMIUM-NEXT-MONTH') r,
      ],
    });
    final message = SmsMessage(
      sender: 'VM-INSCOX-S',
      body: body,
      observedAt: nov1,
      sourceKey: 'a' * 64,
    );
    final old = SmsV2Pipeline(
      financial: financial,
      namespace: 'user:test',
      bundle: without,
      appVersion: '2.0.0',
      revision: 'before',
    );
    old.process(message);
    expect(notices(), isEmpty);
    // The next rule release re-reads what was left unread.
    final next = SmsV2Pipeline(
      financial: financial,
      namespace: 'user:test',
      bundle: bundle,
      appVersion: '2.0.0',
      revision: 'after',
    );
    next.process(message);
    expect(notices().single.month, DateTime(2026, 12));
    // And a third read changes nothing.
    next.process(message);
    expect(notices(), hasLength(1));
  });
}
