// ignore_for_file: use_null_aware_elements
//
// Converts the three existing synthetic sources into golden cases:
//   docs/sms-pipeline-v2/seed/probe_cases.json     (35 review probes)
//   app/test/fixtures/sms_family_corpus.json       (23 family cases)
//   app/test/fixtures/local_sms_cases.json         (24 local parser cases)
//
// Usage (from tools/sms_rules_cli):
//   dart run tool/convert_seed.dart <repoRoot>
//
// Every case is expressed as partial v2 Facts (contracts.md). Re-running
// rewrites tools/sms_golden/cases/ files for these ids; other files are kept.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_template.dart';

typedef J = Map<String, Object?>;

int _minor(num rupees) => (rupees * 100).round();

J _amt(String role, num rupees, {String unit = 'INR'}) => {
  'role': role,
  'minor': unit == 'POINTS' ? rupees.round() : _minor(rupees),
  if (unit != 'INR') 'unit': unit,
};

J _inst(String kind, {String? issuer, String? mask}) => {
  'kind': kind,
  if (issuer != null) 'issuerSlug': issuer,
  if (mask != null) 'maskDigits': mask,
};

J _mov(
  String direction,
  String? purpose,
  num rupees, {
  J? instrument,
  String? rail,
  J? counterparty,
  J? references,
  bool? evidenceOnly,
}) => {
  'factType': 'movement',
  'attrs': {
    'direction': direction,
    if (purpose != null) 'purpose': purpose,
    if (rail != null) 'rail': rail,
    if (evidenceOnly != null) 'evidenceOnly': evidenceOnly,
  },
  'amounts': [_amt('posted', rupees)],
  if (instrument != null) 'instrument': instrument,
  if (counterparty != null) 'counterparty': counterparty,
  if (references != null) 'references': references,
};

J _balance(String role, num rupees, {J? instrument}) => {
  'factType': 'balance_snapshot',
  'amounts': [_amt(role, rupees)],
  if (instrument != null) 'instrument': instrument,
};

J _hold(String phase, String purpose, String role, num rupees, {J? instrument}) => {
  'factType': 'hold',
  'attrs': {'phase': phase, 'purpose': purpose},
  'amounts': [_amt(role, rupees)],
  if (instrument != null) 'instrument': instrument,
};

J _attempt(String status, {String? direction, num? rupees, String role = 'posted', J? instrument, String? purpose}) => {
  'factType': 'attempt',
  'attrs': {
    'status': status,
    if (direction != null) 'direction': direction,
    if (purpose != null) 'purpose': purpose,
  },
  if (rupees != null) 'amounts': [_amt(role, rupees)],
  if (instrument != null) 'instrument': instrument,
};

J _mandate(String phase, {String? merchant, num? ceiling, J? instrument, String? purpose}) => {
  'factType': 'mandate',
  'attrs': {
    'phase': phase,
    if (merchant != null) 'merchantName': merchant,
    if (purpose != null) 'mandatePurpose': purpose,
  },
  if (ceiling != null) 'amounts': [_amt('ceiling', ceiling)],
  if (instrument != null) 'instrument': instrument,
};

J _billDue(num total, String dueDate, {num? minimum, String? statementDate, J? instrument, String? biller}) => {
  'factType': 'bill_due',
  'attrs': {
    'dueDate': dueDate,
    if (statementDate != null) 'statementDate': statementDate,
    if (biller != null) 'billerName': biller,
  },
  'amounts': [_amt('due_total', total), if (minimum != null) _amt('due_minimum', minimum)],
  if (instrument != null) 'instrument': instrument,
};

J _reward(String pointsRole, int points, {num? cashValue, J? instrument}) => {
  'factType': 'reward',
  'amounts': [
    _amt(pointsRole, points, unit: 'POINTS'),
    if (cashValue != null) _amt('cash_value', cashValue),
  ],
  if (instrument != null) 'instrument': instrument,
};

J _limit(num limit, String reason, {J? instrument}) => {
  'factType': 'limit_change',
  'attrs': {'reason': reason},
  'amounts': [_amt('credit_limit', limit)],
  if (instrument != null) 'instrument': instrument,
};

class _Seed {
  _Seed(this.id, this.sender, this.body, this.facts, {this.ignore = false, this.note});
  final String id;
  final String sender;
  final String body;
  final List<J> facts;
  final bool ignore;
  final String? note;
}

const _hdfc = 'hdfc';

/// Expectations for the 35 probes (ids from probe_cases.json).
Map<String, (List<J>, bool, String?)> _probeExpect() {
  J bank(String issuer, String mask) => _inst('bank_account', issuer: issuer, mask: mask);
  J card(String issuer, String mask) => _inst('credit_card', issuer: issuer, mask: mask);
  return {
    'ipo_asba_block': ([_hold('placed', 'ipo_asba', 'held', 14250, instrument: bank(_hdfc, '1234'))], false, null),
    'ipo_upi_mandate_block': ([
      _hold('placed', 'upi_mandate_block', 'held', 14250, instrument: bank('icici', '1234')),
      _mandate('created', purpose: 'ipo'),
    ], false, 'An IPO mandate is a hold plus a one-time mandate; it never becomes a subscription.'),
    'ipo_unblock': ([_hold('released', 'ipo_asba', 'released', 14250, instrument: bank(_hdfc, '1234'))], false, null),
    'ipo_allotment_debit': ([
      _mov('debit', 'investment', 14250, instrument: bank(_hdfc, '1234')),
      _balance('available_balance', 52310.40, instrument: bank(_hdfc, '1234')),
    ], false, null),
    'ipo_mandate_executed': ([_mov('debit', 'investment', 14250, instrument: bank('icici', '1234'))], false, null),
    'groww_sip_upi': ([
      _mov('debit', 'investment', 5000, instrument: bank(_hdfc, '1234'), rail: 'upi'),
      _balance('available_balance', 47310.40, instrument: bank(_hdfc, '1234')),
    ], false, null),
    'cc_bill_bank_side': ([_mov('debit', 'card_payment', 25000, instrument: bank(_hdfc, '1234'))], false, 'Bank side of a card bill payment; the card side is cc_bill_card_side.'),
    'cc_bill_card_side': ([_mov('credit', 'card_payment', 25000, instrument: card(_hdfc, '5678'))], false, null),
    'cc_bill_via_cred': ([
      _mov('debit', 'card_payment', 25000, instrument: bank('icici', '1234'), rail: 'upi', counterparty: {'kind': 'own'}),
    ], false, 'A CRED payment is a card payment, not money received.'),
    'cc_payment_amex': ([_mov('credit', 'card_payment', 12000, instrument: card('amex', '10005'))], false, 'Amex "ending 10005 on 10 Nov 2026": the mask is 10005, never the year.'),
    'cc_payment_axis': ([_mov('credit', 'card_payment', 8500, instrument: card('axis', '9012'))], false, null),
    'spend_avl_lmt_hdfc': ([
      _mov('debit', 'purchase', 499, instrument: card(_hdfc, '5678')),
      _balance('available_credit', 45000, instrument: card(_hdfc, '5678')),
    ], false, null),
    'spend_avl_limit_icici': ([
      _mov('debit', 'purchase', 1299, instrument: card('icici', '9012')),
      _balance('available_credit', 148701, instrument: card('icici', '9012')),
    ], false, null),
    'limit_enhanced': ([_limit(300000, 'increase', instrument: card(_hdfc, '5678'))], false, null),
    'limit_offer': ([], true, 'A limit offer is a promotion, never a review item.'),
    'sbi_card_spend': ([_mov('debit', 'purchase', 799, instrument: card('sbi', '3456'))], false, null),
    'paytm_wallet_spend': ([
      _mov('debit', 'purchase', 120, instrument: _inst('wallet', issuer: 'paytm')),
      _balance('available_balance', 380, instrument: _inst('wallet', issuer: 'paytm')),
    ], false, null),
    'paytm_wallet_load_bank': ([
      _mov('debit', 'wallet_topup', 500, instrument: bank(_hdfc, '1234'), rail: 'upi', counterparty: {'kind': 'own'}),
    ], false, 'A wallet top-up is a transfer; the wallet purchase is the spend.'),
    'zomato_money_spend': ([
      _mov('debit', 'purchase', 350, instrument: _inst('wallet')),
      _balance('available_balance', 650, instrument: _inst('wallet')),
    ], false, null),
    'amazon_pay_balance_spend': ([
      _mov('debit', 'purchase', 499, instrument: _inst('wallet'), evidenceOnly: true),
      _balance('available_balance', 1201, instrument: _inst('wallet')),
    ], false, 'Amazon Pay is a partial-visibility wallet: the top-up counted as a purchase, so a balance payment is wallet activity only and never counts.'),
    'amazon_pay_cashback': ([_mov('credit', 'cashback', 25, instrument: _inst('wallet'))], false, null),
    'reward_points_earned': ([
      _reward('points_earned', 50, cashValue: 50, instrument: _inst('credit_card', issuer: 'icici')),
      {
        'factType': 'balance_snapshot',
        'amounts': [_amt('points_balance', 1250, unit: 'POINTS')],
      },
    ], false, '"Earned 50 points worth Rs 50" is a reward, not a Rs 50 transfer.'),
    'reward_points_redeemed': ([_reward('points_redeemed', 2000, cashValue: 500, instrument: card(_hdfc, '5678'))], false, null),
    'cashback_on_card': ([_mov('credit', 'cashback', 150, instrument: card(_hdfc, '5678'))], false, null),
    'refund_on_card': ([_mov('credit', 'refund', 499, instrument: card(_hdfc, '5678'))], false, null),
    'netflix_upi_autopay_debit': ([
      _mov('debit', 'purchase', 649, instrument: bank(_hdfc, '1234'), references: {'umrn': '9876'}),
      _balance('available_balance', 51661.40, instrument: bank(_hdfc, '1234')),
    ], false, null),
    'spotify_card_si': ([
      _mov('debit', 'purchase', 119, instrument: card('icici', '9012')),
      _balance('available_credit', 148582, instrument: card('icici', '9012')),
    ], false, null),
    'mandate_registered': ([_mandate('created', merchant: 'NETFLIX', ceiling: 1499)], false, null),
    'upcoming_autopay': ([_attempt('scheduled', direction: 'debit', rupees: 649, role: 'scheduled', instrument: bank(_hdfc, '1234'))], false, null),
    'sbi_upi_p2p': ([_mov('debit', 'p2p', 250, instrument: bank('sbi', '1234'), rail: 'upi')], false, null),
    'axis_multiline': ([_mov('debit', 'purchase', 1500, instrument: bank('axis', '123456'), rail: 'upi')], false, 'Axis prints a 6-digit mask (A/c no. XX123456).'),
    'kotak_sent': ([_mov('debit', null, 300, instrument: bank('kotak', '1234'), rail: 'upi')], false, null),
    'salary_neft': ([
      _mov('credit', 'salary', 85000, instrument: bank(_hdfc, '1234'), rail: 'neft'),
      _balance('available_balance', 137661.40, instrument: bank(_hdfc, '1234')),
    ], false, null),
    'cheque_cleared': ([_mov('debit', null, 5000, instrument: bank(_hdfc, '1234'), rail: 'cheque', references: {'chequeNo': '000123'})], false, null),
    'self_transfer_imps': ([
      _mov('debit', 'transfer', 20000, instrument: bank(_hdfc, '1234'), rail: 'imps', counterparty: {'kind': 'own', 'accountMask': '9999'}),
    ], false, null),
  };
}

/// Expectations for sms_family_corpus.json (ids from that file).
Map<String, (List<J>, bool, String?)> _corpusExpect() {
  J bank(String issuer, String mask) => _inst('bank_account', issuer: issuer, mask: mask);
  J card(String issuer, String mask) => _inst('credit_card', issuer: issuer, mask: mask);
  return {
    'send_debit_with_balance': ([
      _mov('debit', 'purchase', 1250.50, instrument: bank(_hdfc, '1234'), rail: 'upi'),
      _balance('available_balance', 8750.25, instrument: bank(_hdfc, '1234')),
    ], false, null),
    'balance_only': ([_balance('available_balance', 9000, instrument: bank('sbi', '9876'))], false, null),
    'card_statement': ([
      _billDue(3000, '2026-11-05', minimum: 600, statementDate: '2026-10-12', instrument: card('axis', '4321')),
    ], false, 'Statement total, minimum due and due date stay separate roles.'),
    'bill_with_offer': ([_billDue(1500, '2026-10-18', biller: 'TNEB')], false, 'A real bill wins over appended marketing.'),
    'autopay_mandate': ([_mandate('created', merchant: 'NETFLIX', ceiling: 2000, instrument: bank(_hdfc, '1797'))], false, null),
    'autopay_scheduled': ([_attempt('scheduled', direction: 'debit', rupees: 799, role: 'scheduled')], false, null),
    'autopay_failed': ([_attempt('failed', direction: 'debit')], false, 'No amount is printed; contracts.md requires a posted or scheduled amount on an attempt. Contract gap to resolve in WP-03c.'),
    'mandate_cancelled': ([_mandate('revoked', merchant: 'NETFLIX', instrument: bank(_hdfc, '1797'))], false, null),
    'refund_with_offer': ([_mov('credit', 'refund', 499, instrument: card(_hdfc, '4321'))], false, 'A refund is neither earned income nor a promotion.'),
    'card_bill_payment': ([_mov('debit', 'card_payment', 12000, instrument: bank('axis', '8801'))], false, null),
    'outstanding_reminder': ([_billDue(4000, '2026-11-15', instrument: card(_hdfc, '4321'))], false, null),
    'kotak_settlement': ([_attempt('pending', direction: 'credit')], false, 'Broker payout initiated, not yet received; never consumer spend or income.'),
    'hdfc_txn_check_alert': ([], true, null),
    'reversed_credit': ([_mov('credit', 'reversal', 500, instrument: bank(_hdfc, '1234'))], false, null),
    'upi_person_spend': ([_mov('debit', null, 250, instrument: bank(_hdfc, '1234'), rail: 'upi')], false, null),
    'salary_income': ([_mov('credit', 'salary', 50000, instrument: bank(_hdfc, '1234'))], false, null),
    'atm_withdrawal': ([_mov('debit', 'atm', 20000, instrument: _inst('debit_card', issuer: _hdfc, mask: '8406'))], false, null),
    'call_forwarding_vicare': ([], true, null),
    'cashback_offer_only': ([], true, null),
    'otp_security': ([], true, null),
    'declined_attempt': ([_attempt('declined', direction: 'debit', rupees: 500, instrument: card('icici', '4321'))], false, null),
    'ambiguous_suffix_two_banks': ([_mov('debit', 'transfer', 3000, instrument: bank(_hdfc, '9080'))], false, 'Same last four at two banks must stay separate instruments.'),
    'ambiguous_suffix_two_banks_second': ([_mov('credit', null, 3000, instrument: bank('canara', '9080'))], false, null),
  };
}

/// Expectations for local_sms_cases.json, by index.
List<(String sender, List<J>, bool, String?)> _localExpect() {
  J bank(String mask) => _inst('bank_account', mask: mask);
  J card(String mask, {String? issuer}) => _inst('credit_card', issuer: issuer, mask: mask);
  return [
    ('HDFCBK', [_mov('debit', 'purchase', 1499, instrument: card('4321', issuer: _hdfc)), _balance('available_credit', 85000)], false, null),
    ('ICICIT', [_mov('debit', 'purchase', 250, instrument: card('7788', issuer: 'icici'))], false, null),
    ('HDFCBK', [_mov('debit', 'purchase', 500, instrument: bank('1234'), rail: 'upi')], false, null),
    ('HDFCBK', [_mov('debit', 'purchase', 100, instrument: _inst('debit_card', mask: '1234'), rail: 'card')], false, null),
    ('HDFCBK', [_mov('credit', 'salary', 50000, instrument: bank('1234'))], false, null),
    ('HDFCBK', [_mov('debit', 'card_payment', 1200)], false, null),
    ('HDFCBK', [_mov('debit', 'investment', 5000, instrument: bank('1797'))], false, null),
    ('HDFCBK', [], true, null),
    ('HDFCBK', [_attempt('declined', direction: 'debit', rupees: 500, instrument: card('4321'))], false, null),
    ('HDFCBK', [_mov('credit', 'refund', 500, instrument: card('4321'))], false, null),
    ('HDFCBK', [_billDue(3000, '2026-10-20', instrument: card('4321'))], false, null),
    ('HDFCBK', [], true, null),
    ('HDFCBK', [_balance('available_balance', 3000, instrument: bank('1234'))], false, null),
    ('HDFCBK', [_mov('credit', 'p2p', 2500, rail: 'upi')], false, null),
    ('HDFCBK', [_mov('credit', 'refund', 500, instrument: bank('1234'))], false, null),
    ('HDFCBK', [_mov('credit', 'reversal', 200, instrument: bank('1234'))], false, null),
    ('HDFCBK', [_mov('credit', 'wallet_topup', 1200, instrument: _inst('wallet'))], false, null),
    ('HDFCBK', [_mov('credit', 'p2p', 4500, instrument: bank('1234'))], false, null),
    ('HDFCBK', [_attempt('pending', direction: 'credit', instrument: bank('1234'))], false, null),
    ('HDFCBK', [_attempt('failed', direction: 'credit', instrument: bank('1234'))], false, null),
    ('HDFCBK', [_attempt('pending', direction: 'credit', purpose: 'refund', instrument: bank('1234'))], false, null),
    ('HDFCBK', [_attempt('failed', direction: 'credit', instrument: bank('1234'))], false, null),
    ('HDFCBK', [_attempt('pending', direction: 'credit', purpose: 'refund')], false, null),
    ('HDFCBK', [], true, null),
  ];
}

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : '../..';
  final outDir = '$root/tools/sms_golden/cases';
  final written = <String>[];
  final usedNames = <String>{};

  void emit(String id, String source, String sender, String body, DateTime at, List<J> facts, bool ignore, String? note) {
    final brand = smsTemplateBrand(sender);
    final hash = smsTemplateHash(brand, smsSkeleton(body));
    var file = '$outDir/$brand/$hash.json';
    var n = 1;
    while (usedNames.contains(file)) {
      n++;
      file = '$outDir/$brand/$hash-$n.json';
    }
    usedNames.add(file);
    final c = <String, Object?>{
      'id': id,
      'templateHash': hash,
      'weight': 1,
      'source': 'synthetic',
      'messages': [
        {'sender': sender, 'body': body, 'observedAt': at.toIso8601String()},
      ],
      'expect': {
        if (facts.isNotEmpty) 'facts': facts,
        if (ignore) 'ignore': true,
      },
      if (note != null) 'note': note,
      'origin': source,
    };
    Directory('$outDir/$brand').createSync(recursive: true);
    File(file).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(c)}\n');
    written.add(id);
  }

  // Probes
  final probes = jsonDecode(File('$root/docs/sms-pipeline-v2/seed/probe_cases.json').readAsStringSync()) as List;
  final pe = _probeExpect();
  for (final p in probes.cast<Map<String, dynamic>>()) {
    final id = p['id'] as String;
    final e = pe[id];
    if (e == null) throw StateError('no expectation for probe $id');
    emit('probe:$id', 'probe_cases.json', p['sender'] as String, p['body'] as String,
        DateTime.utc(2026, 12, 1, 9), e.$1, e.$2, e.$3);
  }
  if (pe.length != probes.length) throw StateError('probe expectations ${pe.length} != ${probes.length}');

  // Family corpus
  final corpus = jsonDecode(File('$root/app/test/fixtures/sms_family_corpus.json').readAsStringSync()) as Map<String, dynamic>;
  final ce = _corpusExpect();
  for (final c in (corpus['cases'] as List).cast<Map<String, dynamic>>()) {
    final id = c['id'] as String;
    final e = ce[id];
    if (e == null) throw StateError('no expectation for corpus case $id');
    emit('corpus:$id', 'sms_family_corpus.json', c['sender'] as String, c['body'] as String,
        DateTime.utc(2026, 11, 20, 9), e.$1, e.$2, e.$3);
  }
  if (ce.length != (corpus['cases'] as List).length) throw StateError('corpus expectation count mismatch');

  // Local cases
  final local = jsonDecode(File('$root/app/test/fixtures/local_sms_cases.json').readAsStringSync()) as List;
  final le = _localExpect();
  if (le.length != local.length) throw StateError('local expectation count ${le.length} != ${local.length}');
  for (var i = 0; i < local.length; i++) {
    final c = local[i] as Map<String, dynamic>;
    emit('local:${i.toString().padLeft(2, '0')}', 'local_sms_cases.json', le[i].$1, c['body'] as String,
        DateTime.utc(2026, 11, 20, 9), le[i].$2, le[i].$3, le[i].$4);
  }
  stdout.writeln('wrote ${written.length} cases to $outDir');
}
