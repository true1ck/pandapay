// Whole IPO lifecycles through the real pipeline and the real rules, read the way
// the IPO screen reads them: which application each message joins, and its status.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:ipo';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var n = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: testRuleBundle(),
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  void send(String sender, String body, String day) {
    n++;
    pipeline.process(
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: n.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      ),
    );
  }

  List<IpoApplication> applications() => ipoApplications(
    FactStore(db.db, namespace: _ns).all(),
    EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
  );

  const block =
      'Rs.14,250.00 has been blocked in your A/c XX1234 towards ASBA application for TATA TECHNOLOGIES LTD IPO on 22-11-26. -HDFC Bank';
  const release =
      'Rs.14,250.00 blocked in your A/c XX1234 towards ASBA for TATA TECHNOLOGIES LTD has been released on 30-11-26. -HDFC Bank';
  const allot =
      'Rs.14,250.00 debited from A/c XX1234 on 30-11-26 towards IPO allotment of TATA TECHNOLOGIES LTD. -HDFC Bank';

  test('applied only: one application, amount blocked', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    final apps = applications();
    expect(apps, hasLength(1));
    expect(apps.single.status, 'blocked');
    expect(apps.single.blockedMinor, 1425000);
  });

  test('applied then allotted: still one application, allotted', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send('VM-HDFCBK-S', allot, '2026-11-30');
    final apps = applications();
    expect(apps, hasLength(1));
    expect(apps.single.status, 'allotted');
  });

  test('applied then not allotted: released', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send('VM-HDFCBK-S', release, '2026-11-30');
    final apps = applications();
    expect(apps, hasLength(1));
    expect(apps.single.status, 'released');
  });

  test('a no-allotment notice is shown on the one application still waiting', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send(
      'VM-BSEIND-S',
      'BSE: Dear Investor, No allotment for your IPO application no. 1234567. Blocked funds will be released by your bank within 3 working days.',
      '2026-11-29',
    );
    final a = applications().single;
    expect(a.status, 'blocked');
    expect(a.noAllotmentNoticeAt, isNotNull);
  });

  test('with two applications waiting the notice is not guessed onto either', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send(
      'VM-HDFCBK-S',
      'Rs.14,250.00 has been blocked in your A/c XX1234 towards ASBA application for SWIGGY LIMITED IPO on 23-11-26. -HDFC Bank',
      '2026-11-23',
    );
    send(
      'VM-BSEIND-S',
      'BSE: Dear Investor, No allotment for your IPO application no. 1234567. Blocked funds will be released by your bank within 3 working days.',
      '2026-11-29',
    );
    expect(applications().every((a) => a.noAllotmentNoticeAt == null), isTrue);
  });

  test('a released application does not show a notice line', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send('VM-HDFCBK-S', release, '2026-11-30');
    send(
      'VM-BSEIND-S',
      'BSE: Dear Investor, No allotment for your IPO application no. 1234567. Blocked funds will be released by your bank within 3 working days.',
      '2026-11-29',
    );
    final a = applications().single;
    expect(a.status, 'released');
    expect(a.noAllotmentNoticeAt, isNull);
  });

  test('a "no allotment" exchange notice alone creates no application', () {
    send(
      'VM-BSEIND-S',
      'BSE: Dear Investor, No allotment for your IPO application no. 1234567. Blocked funds will be released by your bank within 3 working days.',
      '2026-11-29',
    );
    expect(applications(), isEmpty);
  });

  test('two IPOs with the same amount are two applications, each its own result', () {
    send('VM-HDFCBK-S', block, '2026-11-22');
    send(
      'VM-HDFCBK-S',
      'Rs.14,250.00 has been blocked in your A/c XX1234 towards ASBA application for SWIGGY LIMITED IPO on 23-11-26. -HDFC Bank',
      '2026-11-23',
    );
    send('VM-HDFCBK-S', allot, '2026-11-30');
    final apps = applications();
    final byCompany = {for (final a in apps) a.company: a.status};
    // The allotment names Tata Technologies; Swiggy must still be waiting.
    expect(byCompany.length, 2, reason: '$byCompany');
    expect(byCompany.entries.firstWhere((e) => e.key.contains('TATA')).value, 'allotted');
    expect(byCompany.entries.firstWhere((e) => e.key.contains('SWIGGY')).value, 'blocked');
  });

  test('a registrar partial allotment: debit for the shares, the rest unblocked', () {
    send(
      'AX-ICICIT-S',
      'IPO-REG',
      '2026-11-20',
    ); // an unrelated short message must not matter
    send(
      'VM-HDFCBK-S',
      'Rs.15,000.00 has been blocked in your A/c XX1234 towards ASBA application for SAMPLEWORK IPO on 22-11-26. -HDFC Bank',
      '2026-11-22',
    );
    send(
      'VM-KFINCR-S',
      'Your bank is instructed to Debit Rs. 1500.00 towards partial-allotment & unblock Rs. 13500.00 for SAMPLEWORK IPO applno. UPSAMPLE00012345. Please contact your bank or ignore if already unblocked.',
      '2026-11-29',
    );
    final apps = applications();
    expect(apps, hasLength(1), reason: '${apps.map((a) => '${a.company}:${a.status}')}');
    expect(apps.single.status, 'partially_allotted');
    expect(apps.single.releasedMinor, 1350000);
  });

  test('messages that never name the company still pair a block with its release', () {
    send(
      'VM-HDFCBK-S',
      'Rs 9,000.00 blocked in your account towards ASBA bid. Funds will stay blocked until allotment.',
      '2026-11-22',
    );
    send(
      'VM-HDFCBK-S',
      'Rs 9,000.00 earlier blocked towards your ASBA bid has been released to your account.',
      '2026-11-29',
    );
    final apps = applications();
    expect(apps, hasLength(1), reason: '${apps.map((a) => a.status)}');
    expect(apps.single.status, 'released');
  });

  test('UPI mandate route: block then unblock is one released application', () {
    send(
      'AX-ICICIT-S',
      'Dear Customer, UPI Mandate for Rs 14,250.00 for IPO of TATA TECH has been successfully created and amount is blocked in A/c XX1234. UMRN 1234567890. -ICICI Bank',
      '2026-11-22',
    );
    send(
      'AX-ICICIT-S',
      'Your account XX1234 has been unblocked by an amount of Rs 14,250.00 against the UPI one-time mandate. UMN: ipo1234@icici.',
      '2026-11-29',
    );
    final apps = applications();
    expect(apps, hasLength(1), reason: '${apps.map((a) => a.status)}');
    expect(apps.single.status, 'released');
  });

  test('UPI mandate route: block then the allotment debit is allotted', () {
    send(
      'AX-ICICIT-S',
      'Dear Customer, UPI Mandate for Rs 14,250.00 for IPO of TATA TECH has been successfully created and amount is blocked in A/c XX1234. UMRN 1234567890. -ICICI Bank',
      '2026-11-22',
    );
    send(
      'AX-ICICIT-S',
      'Your A/c XX1234 is debited for Rs 14,250.00 on 30-Nov-26 against UPI mandate for IPO TATA TECH. -ICICI Bank',
      '2026-11-30',
    );
    final apps = applications();
    expect(apps, hasLength(1), reason: '${apps.map((a) => a.status)}');
    expect(apps.single.status, 'allotted');
  });
}
