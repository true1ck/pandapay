import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';

void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('portable-ndjson-');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await staging.exists()) return;
        await staging.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  group('canonicalJsonEncode', () {
    test('sorts object keys recursively and keeps array order', () {
      final encoded = canonicalJsonEncode(<String, dynamic>{
        'zebra': 1,
        'apple': {'y': 2, 'x': 1, 'nest': {'b': 2, 'a': 1}},
        'list': [3, 1, 2],
      });
      expect(encoded, '{"apple":{"nest":{"a":1,"b":2},"x":1,"y":2},"list":[3,1,2],"zebra":1}');
    });

    test('encodes UTC datetimes and rejects local timestamps', () {
      expect(
        canonicalJsonEncode({
          'at': DateTime.utc(2026, 10, 23, 1, 2, 3),
        }),
        '{"at":"2026-10-23T01:02:03.000Z"}',
      );
      expect(
        () => canonicalJsonEncode({
          'at': DateTime(2026, 10, 23, 10),
        }),
        throwsFormatException,
      );
    });

    test('rejects non-JSON scalar payloads instead of guessing', () {
      expect(
        () => canonicalJsonEncode({'bad': DateTime(2026, 10, 23)}),
        throwsFormatException,
      );
      expect(
        () => canonicalJsonEncode({'bad': [Uri.parse('https://x')]}),
        throwsFormatException,
      );
    });
  });

  group('writeCanonicalNdjson', () {
    test('writes LF-terminated rows and reports counts, bytes and digest', () async {
      final records = <Map<String, dynamic>>[
        {'id': 'a', 'amount': '250.00'},
        {'id': 'b', 'amount': '125.50'},
      ];
      final destination = File('${staging.path}${Platform.pathSeparator}transactions.ndjson');
      final result = await writeCanonicalNdjson(Stream.fromIterable(records), destination);
      final bytes = destination.readAsBytesSync();
      expect(utf8.decode(bytes), '{"amount":"250.00","id":"a"}\n{"amount":"125.50","id":"b"}\n');
      expect(result.recordCount, 2);
      expect(result.byteLength, bytes.length);
      expect(result.sha256, digest(bytes));
    });

    test('an empty section is a valid zero-record section', () async {
      final destination = File('${staging.path}${Platform.pathSeparator}empty.ndjson');
      final result = await writeCanonicalNdjson(const Stream.empty(), destination);
      expect(result.recordCount, 0);
      expect(result.byteLength, 0);
      final bytes = await destination.readAsBytes();
      expect(bytes, isEmpty);
    });

    test('cancellation throws before the caller learns success', () async {
      final destination = File('${staging.path}${Platform.pathSeparator}cancelled.ndjson');
      await expectLater(
        writeCanonicalNdjson(
          Stream.fromIterable([<String, dynamic>{'id': 'a'}]),
          destination,
          isCancelled: () async => true,
        ),
        throwsA(isA<PortableBackupCancelled>()),
      );
    });
  });

  group('PortableSha256Accumulator', () {
    test('chunked digest equals whole-input digest', () async {
      final whole = List<int>.generate(70000, (i) => (i * 31 + 7) & 0xFF);
      final cumulative = PortableSha256Accumulator();
      for (var offset = 0; offset < whole.length; offset += 4096) {
        final end = offset + 4096 > whole.length ? whole.length : offset + 4096;
        cumulative.add(whole.sublist(offset, end));
      }
      final sum = cumulative.close();
      expect(sum, digest(whole));
    });

    test('adding after close is a programming error', () {
      final accumulator = PortableSha256Accumulator()
        ..add([1, 2, 3])
        ..close();
      expect(() => accumulator.add([4]), throwsStateError);
    });
  });
}

String digest(List<int> bytes) => sha256.convert(bytes).toString();

