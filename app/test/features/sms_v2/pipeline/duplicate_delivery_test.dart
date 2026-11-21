// Duplicate probe: one real purchase delivered through different paths
// (live broadcast vs inbox scan, carrier prefix, whitespace, resend later)
// must stay ONE transaction. Synthetic data only.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';

import '../support/rules.dart';
import '../support/sync_harness.dart';

const _body =
    'Rs.156.44 spent on your SBI Credit Card ending with 2837 at '
    'EXAMPLESHOPPRIV on 07-11-26 via UPI (Ref No. 603112342487). '
    'Trxn. not done by you? Report at https://sbicard.com/Dispute';

Future<int> countAfter(
  List<({String sender, String body, DateTime at})> deliveries,
) async {
  final bundle = testRuleBundle();
  final device = Device('dup');
  addTearDown(device.dispose);
  final encoded = jsonEncode(bundle.toJson());
  final runtime = SmsV2Runtime(
    financial: device.financial,
    namespace: harnessNamespace,
    client: MockClient((_) async => throw StateError('offline')),
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'dup',
    appVersion: '2',
    headers: () async => {},
    verify: (value) async => value == encoded ? bundle : null,
    loadShippedBundle: () async => encoded,
    accountIsCurrent: () => true,
    clock: () => DateTime.utc(2026, 11, 30),
  );
  for (final d in deliveries) {
    await runtime.capture([
      QueuedSms(sender: d.sender, body: d.body, receivedAt: d.at),
    ]);
  }
  final rows = device.financial.entities(harnessNamespace, 'transactions');
  // ignore: avoid_print
  print('rows=${rows.length} facts=${device.facts.since(DateTime.utc(1900)).length}');
  return rows.length;
}

void main() {
  final t = DateTime.utc(2026, 11, 7, 8, 22, 33);
  test('baseline: one SMS is one row', () async {
    expect(await countAfter([(sender: 'SBICRD-S', body: _body, at: t)]), 1);
  });
  test('same SMS, carrier-prefixed sender on the second path', () async {
    expect(
      await countAfter([
        (sender: 'SBICRD-S', body: _body, at: t),
        (sender: 'VM-SBICRD-S', body: _body, at: t),
      ]),
      1,
    );
  });
  test('same SMS, different whitespace', () async {
    expect(
      await countAfter([
        (sender: 'SBICRD-S', body: _body, at: t),
        (sender: 'SBICRD-S', body: '$_body ', at: t),
        (sender: 'SBICRD-S', body: _body.replaceAll(' ', '  '), at: t),
      ]),
      1,
    );
  });
  test('prefixed twin arriving hours later is a separate purchase', () async {
    expect(
      await countAfter([
        (sender: 'SBICRD-S', body: _body, at: t),
        (
          sender: 'VM-SBICRD-S',
          body: _body,
          at: t.add(const Duration(hours: 5)),
        ),
      ]),
      2,
    );
  });
  test('prefixed twin a few seconds apart is one SMS', () async {
    expect(
      await countAfter([
        (sender: 'SBICRD-S', body: _body, at: t),
        (
          sender: 'VM-SBICRD-S',
          body: _body,
          at: t.add(const Duration(seconds: 4)),
        ),
      ]),
      1,
    );
  });
  test('same SMS re-delivered hours later', () async {
    expect(
      await countAfter([
        (sender: 'SBICRD-S', body: _body, at: t),
        (sender: 'SBICRD-S', body: _body, at: t.add(const Duration(hours: 5))),
      ]),
      1,
    );
  });
}
