import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

final Directory _contracts = () {
  // Tests run with the package as the working directory.
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('contracts/sms/v2 not found above ${Directory.current.path}');
}();

Object? _read(File f) => jsonDecode(f.readAsStringSync());

List<File> _files(String sub) => Directory('${_contracts.path}/$sub')
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.json'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

String _base(File f) => f.uri.pathSegments.last;

List<String> _dirs(String sub) => Directory('${_contracts.path}/$sub')
    .listSync()
    .whereType<Directory>()
    .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
    .toList()
  ..sort();

/// Fixture directories the Dart side validates. Request and response bodies are
/// validated by the server only.
const _dartDirs = ['fact', 'instrument', 'event', 'ledger_entry', 'bundle'];

ValidationResult _validate(String dir, Object? json) => switch (dir) {
      'fact' => validateFactJson(json),
      'instrument' => validateInstrumentJson(json),
      'event' => validateEventJson(json),
      'ledger_entry' => validateLedgerEntryJson(json),
      'bundle' => validateBundleJson(json),
      _ => throw ArgumentError(dir),
    };

Object? _roundTrip(String dir, Map<String, Object?> json) => switch (dir) {
      'fact' => Fact.fromJson(json).toJson(),
      'instrument' => Instrument.fromJson(json).toJson(),
      'event' => Event.fromJson(json).toJson(),
      'ledger_entry' => LedgerEntry.fromJson(json).toJson(),
      'bundle' => RuleBundle.fromJson(json).toJson(),
      _ => throw ArgumentError(dir),
    };

void main() {
  group('valid fixtures', () {
    for (final dir in _dartDirs) {
      for (final f in _files('fixtures/valid/$dir')) {
        test('$dir/${_base(f)} validates and round-trips exactly', () {
          final json = _read(f) as Map<String, Object?>;
          final r = _validate(dir, json);
          expect(r.errors, isEmpty);
          expect(jsonDeepEquals(_roundTrip(dir, json), json), isTrue,
              reason: 'toJson(fromJson(x)) differs from the fixture');
        });
      }
    }
  });

  group('invalid fixtures', () {
    for (final dir in _dartDirs) {
      for (final f in _files('fixtures/invalid/$dir')) {
        final expected = _base(f).replaceAll(RegExp(r'\.json$'), '').split('~').first;
        test('$dir/${_base(f)} fails with exactly $expected', () {
          final r = _validate(dir, _read(f));
          expect(r.codes, [expected], reason: r.toString());
        });
        test('$dir/${_base(f)} is rejected by fromJson', () {
          final json = _read(f) as Map<String, Object?>;
          expect(() => _roundTrip(dir, json), throwsA(isA<ContractException>()));
        });
      }
    }
  });

  test('fixture coverage: at least 3 valid fixtures per fact type', () {
    final byType = <String, int>{};
    for (final f in _files('fixtures/valid/fact')) {
      final t = (_read(f) as Map)['factType'] as String;
      byType[t] = (byType[t] ?? 0) + 1;
    }
    for (final t in FactType.values) {
      expect(byType[t.wire] ?? 0, greaterThanOrEqualTo(3), reason: t.wire);
    }
  });

  test('every error code in error_codes.json has an invalid fixture', () {
    final codes = (_read(File('${_contracts.path}/error_codes.json')) as Map).keys.toSet();
    final used = <String>{};
    for (final d in _dirs('fixtures/invalid')) {
      for (final f in _files('fixtures/invalid/$d')) {
        used.add(_base(f).replaceAll(RegExp(r'\.json$'), '').split('~').first);
      }
    }
    expect(codes.difference(used), isEmpty);
    expect(used.difference(codes), isEmpty);
  });

  test('embedded schemas match contracts/sms/v2 (run embed_dart.js if this fails)', () {
    final onDisk = <String, Object?>{};
    for (final f in _files('')) {
      if (_base(f).endsWith('.schema.json')) onDisk[_base(f)] = _read(f);
    }
    for (final f in _files('api')) {
      if (_base(f).endsWith('.schema.json')) onDisk['api/${_base(f)}'] = _read(f);
    }
    expect(smsV2SchemaSources.keys.toSet(), onDisk.keys.toSet());
    smsV2SchemaSources.forEach((name, text) {
      expect(jsonDeepEquals(jsonDecode(text), onDisk[name]), isTrue, reason: name);
    });
  });

  test('later contract additions are accepted', () {
    final movement = _read(File('${_contracts.path}/fixtures/valid/fact/movement.card_spend.json'))
        as Map<String, Object?>;
    final attrs = Map<String, Object?>.from(movement['attrs'] as Map)
      ..['purpose'] = 'dividend'
      ..['evidenceOnly'] = true;
    final f = Fact.fromJson({...movement, 'attrs': attrs}) as MovementFact;
    expect(f.purpose, MovementPurpose.dividend);
    expect(f.evidenceOnly, isTrue);
    expect(EventType.values.map((e) => e.wire),
        containsAll(['investment_withdrawal', 'dividend']));
    expect(LegRole.duplicateNotice.wire, 'duplicate_notice');
    expect(LedgerEndpoint.fromJson({'ownUnresolved': 'credit_card'}),
        isA<OwnUnresolvedEndpoint>());
  });
}
