import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/gen_template_hash_vectors.dart' as gen;

/// The server recomputes templateHash at intake and reads this fixture in api/test/sms_v2/template_hash_pg.test.js.
/// If the phone's redaction, skeleton or hash changes, regenerate it: dart run tool/gen_template_hash_vectors.dart
void main() {
  test('template_hash_vectors.json is what the phone code produces', () {
    final dir = gen.contractsDir().path;
    final stored = jsonDecode(File('$dir/fixtures/template_hash_vectors.json').readAsStringSync());
    expect(stored, jsonDecode(gen.render(dir)));
  });

  test('a header with punctuation is uploaded and hashed under its letters and digits only', () {
    final dir = gen.contractsDir().path;
    final brands = {for (final v in (jsonDecode(File('$dir/fixtures/template_hash_vectors.json').readAsStringSync()) as Map)['vectors'] as List) (v as Map)['senderBrand']};
    expect(brands, containsAll(['SBIUPI', 'AXHDFCBK', 'HDFCBK', 'ICICIT']));
    expect(brands.every((b) => RegExp(r'^[A-Z0-9]{1,32}$').hasMatch(b as String)), isTrue, reason: 'the shape the server accepts');
  });
}
