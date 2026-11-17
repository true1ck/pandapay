import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// An AI draft for a layout that the signed rules already read must never be the
// reader: it would send a settled message back to Needs review. Synthetic
// messages only; the draft mirrors the shape of a real one (priority 500, bound
// to one layout, payee in the slot after a fixed word).

const _sender = 'JK-UNIONB-T';
const _body =
    'Union Bank of India A/c *1234 Debited Rs:81.00 on 25-10-2026 22:00:20 by Mob Bk '
    'ref no 100000000001, Fvg: Demo P Avl Bal Rs:1723.92. Not you?Call 18002333/SMS '
    'BLOCK 1234 to 9000000001';

SmsMessage _m(String body) => SmsMessage(
  sender: _sender,
  body: body,
  observedAt: DateTime.utc(2026, 11, 3, 10),
  sourceKey: 'sms:ai-review-only:${body.hashCode}',
);

Map<String, Object?> _aiRule(String hash) => {
  'id': 'AI-$hash:local:test',
  'version': 1,
  'family': 'upi_debit',
  'senders': ['UNIONB'],
  'priority': 500,
  'confidence': 0.95,
  'status': 'provisional',
  'createdBy': 'ai:synthetic',
  'updatedAt': '2026-11-16T13:19:25.530Z',
  'match': {
    'flags': 'i',
    'templateHash': hash,
    'pattern':
        r'^\s*Union\s+Bank\s+of\s+(?<party1>[\s\S]{1,60}?)\s+A/c\s+(?<mask1>[x*]{1,12}\d{2,6})\s+Debited\s+Rs:(?<amt1>\d[\d,]*(?:\.\d+)?)\s+on\s+(?<date1>\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})\s+\d\d:\d\d:\d\d\s+by\s+(?<party2>[\s\S]{1,60}?)\s+ref\s+no\s+(?<ref1>\d{6,}),\s+(?<party3>[\s\S]{1,60}?):\s+Demo\s+(?<party4>[\s\S]{1,60}?)\s+Avl\s+Bal\s+Rs:(?<amt2>\d[\d,]*(?:\.\d+)?)\.\s+Not\s+you\?Call\s+(?<phone1>\d+)/SMS\s+BLOCK\s+\d+\s+to\s+(?<phone2>\d+)\s*$',
  },
  'examples': [
    {
      'sender': 'UNIONB',
      'body': _body,
      'expectFactTypes': ['movement', 'balance_snapshot'],
    },
    {'sender': 'UNIONB', 'body': 'zqx Bank of India', 'expectFactTypes': <String>[]},
  ],
  'emit': [
    {
      'factType': 'movement',
      'attrs': {'rail': 'upi', 'purpose': 'purchase', 'direction': 'debit'},
      'amounts': [
        {'from': 'amt1', 'role': 'posted', 'unit': 'INR'},
      ],
      'instrument': {'kind': 'bank_account', 'maskFrom': 'mask1'},
      'occurredAt': {'from': 'date1'},
      'references': {'upiRef': 'ref1'},
      'counterparty': {'kind': 'merchant', 'nameFrom': 'party4'},
    },
    {
      'factType': 'balance_snapshot',
      'attrs': {
        'asOf': {'from': 'date1'},
      },
      'amounts': [
        {'from': 'amt2', 'role': 'available_balance', 'unit': 'INR'},
      ],
      'instrument': {'kind': 'bank_account', 'maskFrom': 'mask1'},
    },
  ],
};

void main() {
  // The live bundle does not carry the repo's brand rules for this layout (its Union rules are older), so the
  // generic labelled-payee rules read it; those rank below an AI draft's priority of 500.
  final full = testRuleBundle();
  final signed = RuleBundle.fromJson({
    ...full.toJson(),
    'rules': [
      for (final r in full.rules)
        if (!r.id.startsWith('UNION-')) r.toJson(),
    ],
  });
  final engine = RuleEngine();

  EngineOutcome read(RuleBundle b) =>
      engine.interpretDetailed(_m(_body), b, appVersion: 'x');

  test('a signed reading of the layout stands over an AI draft for it', () {
    final alone = read(signed);
    expect(alone.result.outcome, InterpretOutcome.matched, reason: alone.reason);
    final hash = alone.result.templateHash!;
    final withAi = RuleBundle.fromJson({
      ...signed.toJson(),
      'rules': [...signed.rules.map((r) => r.toJson()), _aiRule(hash)],
    });
    final out = read(withAi);
    expect(out.result.ruleId, alone.result.ruleId);
    expect(out.result.ruleId, isNot(startsWith('AI-')));
  });

  test('with no signed reading the AI draft reads it', () {
    final alone = read(signed);
    final hash = alone.result.templateHash!;
    final none = RuleBundle.fromJson({
      ...signed.toJson(),
      'rules': [_aiRule(hash)],
    });
    final out = read(none);
    expect(out.result.ruleId, startsWith('AI-'));
  });
}
