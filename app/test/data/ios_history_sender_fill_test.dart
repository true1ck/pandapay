import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_probe_diagnostics.dart';
import 'package:pandapay/data/ios_sender_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

// Synthetic fixtures; no real account suffix, transaction reference or SMS.
const ns = 'user:history-sender-fill';
const spent =
    'Rs.42.50 spent on your SBI Credit Card ending with 4242 at '
    'TESTTECHNOLOGIES on 01-11-26 via UPI (Ref No. SYNTHETIC). Not you? '
    'Report at https://sbicard.com/Dispute';
const request =
    'TEST TECHNOLOGIES PRIVATE LIMITED has requested money from '
    'you on PhonePe. Rs.42.50 will be debited from your account on approving '
    'the request - https://phone.pe/TEST';
const card = UserCard(
  id: 'saved-card',
  cardProductId: 'sbi-phonepe-rupay',
  cardName: 'PhonePe SBI RuPay Credit Card',
  cardType: 'credit',
  last4: '4242',
  isDefault: false,
);

Map<Object?, Object?> row(String sender, String body, {String? at}) => {
  'sender': sender,
  'senderEvidence': 'text',
  'body': body,
  'receivedAt': at ?? '2026-11-01T08:00:00.030Z',
};

void main() {
  group('inferSenderFromBody', () {
    String? infer(String body) => IosShortcutSmsBatch.inferSenderFromBody(body);

    test('SBI Credit Card with its sbicard.com link is one issuer', () {
      expect(infer(spent), 'VM-SBICRD');
    });
    test('payment app is used when no bank is named', () {
      expect(infer(request), 'VM-PHONPE');
    });
    test('a named bank wins over the payment app it mentions', () {
      expect(infer('Rs 100 debited from HDFC Bank A/c 1234 via PhonePe'),
          'VM-HDFCBK');
    });
    test('two banks or no issuer gives no sender', () {
      expect(infer('Rs 500 sent from HDFC Bank A/c 1234 to ICICI A/c 9876'),
          isNull);
      expect(infer('Rs 500 debited from your account'), isNull);
    });
  });

  test('fill details explain why no sender was chosen', () {
    final none = IosShortcutSmsBatch.senderFillDetails('Rs 5 debited A/c XX1');
    expect(none['fill_result'], 'no_issuer_named');
    final two = IosShortcutSmsBatch.senderFillDetails(
      'Rs 500 sent from HDFC Bank to ICICI A/c',
    );
    expect(two['fill_result'], 'several_issuers_named');
    expect(two['issuers_named'], ['VM-HDFCBK', 'VM-ICICIB']);
    expect(IosShortcutSmsBatch.senderFillDetails(request)['fill_result'],
        'filled_from_payment_app');
  });

  test('probe export summarises fill results and intake outcomes', () {
    final probe = IosSenderProbeSession();
    addTearDown(probe.dispose);
    probe.process([
      {...row('', spent), 'id': 'a', 'origin': 'history'},
      {...row('', 'Rs 500 sent from HDFC Bank to ICICI A/c 9876'),
        'id': 'b', 'origin': 'history'},
    ]);
    final record = (probe.exportJournal['records'] as List).first as Map;
    expect((record['inferred'] as Map)['sender_fill'], isA<Map>());
    final summary = senderFillSummary(probe.exportJournal['records']);
    expect(summary['messages'], 2);
    expect(summary['real_sender_supplied'], 0);
    expect(summary['fill_results'], {
      'filled_from_issuer': 1,
      'several_issuers_named': 1,
    });
    expect(summary['filled_senders'], {'VM-SBICRD': 1});
    expect(summary['several_issuer_combinations'], {'VM-HDFCBK+VM-ICICIB': 1});
    expect(summary['transactions_added_with_fill'], 1);
  });

  test('contact names are personal; headers and numbers are not', () {
    bool name(String s) => IosShortcutSmsBatch.looksLikeContactName(s);
    for (final s in ['Sujay', 'Me', 'Mom Work', 'Ravi K.']) {
      expect(name(s), isTrue, reason: s);
    }
    for (final s in ['SBICRD-S', 'JioBal-S', 'Pluxee-S', 'VM-HDFCBK',
        'HDFCBK', 'DOPBNK-G', '650001', '199', '+917411147986',
        'alerts@bank.com']) {
      expect(name(s), isFalse, reason: s);
    }
    expect(IosShortcutSmsBatch.normalizeSender('+91 74111 47986'),
        '+917411147986');
    expect(IosShortcutSmsBatch.normalizeSender('SBICRD-S'), 'SBICRD-S');
  });

  test('every row reaches intake; contact names are ignored as personal', () {
    final batch = IosShortcutSmsBatch.fromRows([
      row('Sujay', spent),
      row('+91 74111 47986', spent),
      row('SBICRD-S', spent),
    ]);
    // Native acknowledgement needs one result per row.
    expect(batch.messages, hasLength(3));
    expect(batch.personal, 1);
    expect(batch.messages.map((m) => m.sender),
        ['Sujay', '+917411147986', 'SBICRD-S']);
    expect(classifySmsTriage('Sujay', spent).reasonCode, 'p2p_contact_name');
    expect(classifySmsTriage('+917411147986', spent).reasonCode,
        'p2p_mobile_number');
    expect(classifySmsTriage('SBICRD-S', spent).kind,
        SmsTriageKind.financialCandidate);
  });

  group('history import with filled sender', () {
    late AppDatabase db;
    late FinancialStore store;
    late SmsImportStore intake;
    setUp(() {
      db = openInMemoryForTesting();
      store = FinancialStore(db);
      store.replaceCards(ns, [card]);
      intake = SmsImportStore(store);
    });
    tearDown(() {
      store.dispose();
      db.close();
    });

    List<TransactionEntry> transactions() => store
        .entities(ns, 'transactions')
        .map(TransactionEntry.fromJson)
        .toList();
    List<String> senderReviews() => [
      for (final r in db.db.select(
        "SELECT payload FROM local_needs_review WHERE namespace=? "
        "AND payload LIKE '%sender_unavailable%'",
        [ns],
      ))
        r['payload'] as String,
    ];
    void importHistory(Map<Object?, Object?> input, {bool fill = true}) {
      final batch = IosShortcutSmsBatch.fromRows([
        input,
      ], allowSenderInference: fill);
      intake.captureBatch(ns, batch.messages);
    }

    test('blank-sender history SMS becomes a transaction', () {
      final batch = IosShortcutSmsBatch.fromRows([row('', spent)]);
      expect(batch.messages.single.sender, 'VM-SBICRD');
      expect(batch.sourceRows.single['senderInferred'], isTrue);
      intake.captureBatch(ns, batch.messages);
      final saved = transactions().single;
      expect(saved.amount.rupees, 42.50);
      expect(saved.userCardId, card.id);
      expect(senderReviews(), isEmpty);
    });

    test('re-import clears the old sender-unavailable review copy', () {
      importHistory(row('', spent), fill: false);
      expect(transactions(), isEmpty);
      expect(senderReviews(), hasLength(1));
      importHistory(row('', spent));
      expect(transactions(), hasLength(1));
      expect(senderReviews(), isEmpty);
    });

    test('no identifiable issuer still goes to review', () {
      importHistory(row('', 'Rs.42.50 debited from your A/c XX4242 on '
          '01-11-26 to TESTSHOP. Avl Bal Rs.1000.00'));
      expect(transactions(), isEmpty);
      expect(senderReviews(), hasLength(1));
    });
  });
}
