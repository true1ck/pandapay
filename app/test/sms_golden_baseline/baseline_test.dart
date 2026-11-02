@Tags(['golden-baseline'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

/// WP-00 baseline of today's PHONE parser (`LocalSmsParser`) over the golden
/// cases in `tools/sms_golden/cases`.
///
/// Skipped in normal runs. Run with:
///   SMS_GOLDEN_BASELINE=1 flutter test test/sms_golden_baseline --tags golden-baseline
/// It writes `tools/sms_golden/reports/baseline_phone.interpretations.json`.
/// Score it with `tools/sms_golden/score_baseline.sh`, which runs
/// `sms_rules golden --interpretations ...` and writes baseline_phone.json/.md.
///
/// Today's parser has no v2 facts, so its output is mapped to the nearest v2
/// Fact (see [_toFacts]). It cannot name an issuer or a purpose such as
/// `card_payment`, so those are scored as misses (the issuer field is excluded
/// by the scoring script).
void main() {
  final enabled = Platform.environment['SMS_GOLDEN_BASELINE'] == '1';
  final skip = enabled ? false : 'golden baseline: set SMS_GOLDEN_BASELINE=1 (tag golden-baseline)';

  test('phone parser baseline over the golden cases', () {
    final goldenDir = Platform.environment['SMS_GOLDEN_DIR'] ?? '../tools/sms_golden';
    final results = <String, Object?>{};
    var messages = 0;
    final files = Directory('$goldenDir/cases')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final msgs = (c['messages'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < msgs.length; i++) {
        final m = msgs[i];
        results['${c['id']}#$i'] = _interpret(
          m['sender'] as String,
          m['body'] as String,
          DateTime.parse(m['observedAt'] as String).toUtc(),
        );
        messages++;
      }
    }
    expect(messages, greaterThanOrEqualTo(80));
    final out = File('$goldenDir/reports/baseline_phone.interpretations.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'engine': 'phone: LocalSmsParser.parse (capture gate + parser)', 'results': results})}\n',
    );
    expect(out.existsSync(), isTrue);
  }, skip: skip);
}

Map<String, Object?> _interpret(String sender, String body, DateTime at) {
  // Mirrors the real capture path: gate, sensitivity veto, then the parser.
  if (!capturesFinancialSms(body, sender: sender) || LocalSmsParser.sensitive(body)) {
    return {'facts': <Object?>[], 'unknown': false};
  }
  final LocalSmsObservation? obs;
  try {
    obs = LocalSmsParser.parse(
      namespace: 'user:baseline',
      sender: sender,
      body: body,
      receivedAt: at,
    );
  } catch (_) {
    return {'facts': <Object?>[], 'unknown': true};
  }
  if (obs == null) return {'facts': <Object?>[], 'unknown': false};
  return _toFacts(obs);
}

Map<String, Object?> _instrument(TxnInstrument? kind, String? card, String? acct) {
  String? k;
  switch (kind) {
    case TxnInstrument.creditCard:
      k = 'credit_card';
    case TxnInstrument.debitCard:
      k = 'debit_card';
    case TxnInstrument.wallet:
      k = 'wallet';
    case TxnInstrument.upiBank:
      k = 'bank_account';
    default:
      k = null;
  }
  final mask = card ?? acct;
  if (k == null && mask != null) k = card != null ? 'credit_card' : 'bank_account';
  return {if (k != null) 'kind': k, if (mask != null) 'maskDigits': mask};
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, Object?> _toFacts(LocalSmsObservation o) {
  final facts = <Map<String, Object?>>[];
  final card = o.cardLast4 ?? o.transaction?.cardLast4;
  final acct = o.accountLast4 ?? o.transaction?.accountLast4;
  final t = o.transaction;
  final inst = _instrument(t?.instrument, card, acct);

  if (o.disposition == LocalSmsDisposition.review) {
    return {'facts': <Object?>[], 'unknown': true};
  }
  switch (o.eventType) {
    case LocalSmsEventType.promotion:
    case LocalSmsEventType.security:
      facts.add({'factType': 'info', 'attrs': {'category': o.eventType == LocalSmsEventType.security ? 'security' : 'promotion'}});
    case LocalSmsEventType.transaction:
    case LocalSmsEventType.investment:
      if (t != null) {
        final kind = t.entryKind;
        final purpose = switch (kind) {
          TxnEntryKind.spend => 'purchase',
          TxnEntryKind.investment => 'investment',
          TxnEntryKind.transfer => 'transfer',
          _ => null,
        };
        final direction = switch (kind) {
          TxnEntryKind.spend || TxnEntryKind.investment => 'debit',
          TxnEntryKind.income => 'credit',
          _ => null,
        };
        facts.add({
          'factType': 'movement',
          'attrs': {
            if (direction != null) 'direction': direction,
            if (purpose != null) 'purpose': purpose,
          },
          'amounts': [
            {'role': 'posted', 'minor': t.amount.paise},
          ],
          if (inst.isNotEmpty) 'instrument': inst,
        });
      }
    case LocalSmsEventType.balance:
      break;
    case LocalSmsEventType.bill:
      if (o.amountDue != null) {
        facts.add({
          'factType': 'bill_due',
          'attrs': {if (o.dueDate != null) 'dueDate': _date(o.dueDate!)},
          'amounts': [
            {'role': 'due_total', 'minor': o.amountDue!.paise},
            if (o.minimumDue != null) {'role': 'due_minimum', 'minor': o.minimumDue!.paise},
          ],
          if (inst.isNotEmpty) 'instrument': inst,
        });
      }
    case LocalSmsEventType.autopay:
      facts.add({
        'factType': 'mandate',
        'attrs': {'phase': 'created', if (o.billerName != null) 'merchantName': o.billerName},
        if (o.autopayLimit != null)
          'amounts': [
            {'role': 'ceiling', 'minor': o.autopayLimit!.paise},
          ],
        if (inst.isNotEmpty) 'instrument': inst,
      });
    case LocalSmsEventType.failed:
      facts.add({
        'factType': 'attempt',
        'attrs': {'status': 'failed'},
        if (o.amount != null)
          'amounts': [
            {'role': 'posted', 'minor': o.amount!.paise},
          ],
        if (inst.isNotEmpty) 'instrument': inst,
      });
    case LocalSmsEventType.unknown:
      return {'facts': <Object?>[], 'unknown': true};
  }
  if (o.availableBalance != null) {
    facts.add({
      'factType': 'balance_snapshot',
      'amounts': [
        {'role': 'available_balance', 'minor': o.availableBalance!.paise},
      ],
      if (inst.isNotEmpty) 'instrument': inst,
    });
  }
  // A captured message that produced no fact is dropped, as today.
  return {'facts': facts, 'unknown': false};
}
