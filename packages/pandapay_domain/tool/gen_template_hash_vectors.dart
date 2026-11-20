// Writes contracts/sms/v2/fixtures/template_hash_vectors.json: for every message of the shared layout corpus
// (and a few Unicode ones) the exact {senderBrand, redactedBody, templateHash} the phone uploads, computed by the
// real phone code (TemplateUpload.drain: redactSms -> smsSkeleton -> smsTemplateHash). The server's intake check
// (pandapay.sms_v2_submit_templates) must accept every vector, and api/test/sms_v2/template_hash_pg.test.js reads
// them. All data is synthetic.
//
// Run from packages/pandapay_domain:
//   dart run tool/gen_template_hash_vectors.dart
// packages/pandapay_domain/test/sms_v2/template_hash_vectors_test.dart fails when the fixture drifts from the code.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart' show uploadSenderBrand;
import 'package:pandapay_domain/sms_v2_template.dart';

// Punctuated headers are here on purpose: the phone uploads the brand the server derives (letters and digits only,
// SBI-UPI is SBIUPI), and hashes that brand.
const _senders = [
  'VM-HDFCBK-S',
  'AX-ICICIT-P',
  'JM-iPaytm (smsft_fi)',
  'AMEXIN',
  'bz-sbiupi-t',
  'AD-SBI-UPI',
  'VK-AX-HDFCBK',
  'JM-HDFC_BK-S',
];

List<Map<String, String>> vectors(List<String> bodies) {
  final out = <Map<String, String>>[];
  final seen = <String>{};
  var n = 0;
  for (final body in bodies) {
    final sender = _senders[n++ % _senders.length];
    final redacted = redactSms(
      sender: sender,
      body: body,
      observedAt: DateTime.utc(2026, 11, 20, 9, 30),
      options: SmsRedactionOptions(salt: 'template-hash-vectors'),
    );
    final skeleton = smsSkeleton(redacted.body);
    final brand = uploadSenderBrand(smsTemplateBrand(sender)); // as TemplateUpload does
    final hash = smsTemplateHash(brand, skeleton);
    if (seen.add(hash)) out.add({'senderBrand': brand, 'redactedBody': skeleton, 'templateHash': hash});
  }
  return out;
}

List<String> bodiesFrom(String contractsDir) {
  final corpus = (jsonDecode(File('$contractsDir/fixtures/layout_corpus.json').readAsStringSync()) as Map)['entries'] as List;
  return [
    for (final entry in corpus.cast<Map>()) ...[entry['layout'] as String, ...(entry['messages'] as List).cast<String>()],
    // Non-ASCII text survives into a layout, so the server must hash the UTF-8 bytes exactly as the phone does.
    'Rs.450.00 debited from A/c XX1234 to राहुल शर्मा on 20-11-26. Ref 123456789012.',
    'Dear Customer, ₹1,250.00 spent on card XX4321 at CAFÉ NOIR – thank you.',
  ];
}

Directory contractsDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('contracts/sms/v2 not found above ${Directory.current.path}');
}

String render(String dir) => '${const JsonEncoder.withIndent('  ').convert({
      '_about': 'Synthetic. {senderBrand, redactedBody, templateHash} exactly as the phone uploads them (tool/gen_template_hash_vectors.dart). '
          'templateHash = sha256(senderBrand + "\\n" + redactedBody). The server recomputes it at intake.',
      'vectors': vectors(bodiesFrom(dir)),
    })}\n';

void main() {
  final dir = contractsDir();
  File('${dir.path}/fixtures/template_hash_vectors.json').writeAsStringSync(render(dir.path));
  stdout.writeln('wrote ${dir.path}/fixtures/template_hash_vectors.json');
}
