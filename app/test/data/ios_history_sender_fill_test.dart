import 'package:flutter_test/flutter_test.dart';
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
}
