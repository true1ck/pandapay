import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/bundle_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'only verified compatible newer downloads replace the last good bundle',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      SmsV2Schema.ensure(db);
      final fixture =
          (jsonDecode(
                    File(
                      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, Object?>();
      String body(
        int version, {
        String engine = '2.0.0',
        String expires = '2026-12-01T00:00:00Z',
      }) => jsonEncode({
        ...fixture,
        'bundleVersion': version,
        'minEngineVersion': engine,
        'expiresAt': expires,
      });
      final trusted = {
        body(1),
        body(2),
        body(3, engine: '99.0.0'),
        body(3, expires: '2026-11-01T00:00:00Z'),
      };
      final store = BundleStore(
        db,
        clock: () => DateTime.utc(2026, 11, 5),
        verify: (encoded) async => trusted.contains(encoded)
            ? RuleBundle.fromJson(
                (jsonDecode(encoded) as Map).cast<String, Object?>(),
              )
            : null,
      );
      final baseline = File(
        'assets/sms_rules/baseline_bundle.json',
      ).readAsStringSync();
      expect((await store.load(shippedJson: baseline)).bundleVersion, 0);
      expect(await store.install(body(1)), isTrue);
      expect(await store.install(body(2)), isTrue);
      expect(await store.install(body(1)), isFalse);
      expect(await store.install(body(3, engine: '99.0.0')), isFalse);
      expect(
        await store.install(body(3, expires: '2026-11-01T00:00:00Z')),
        isFalse,
      );
      expect(await store.install('{}'), isFalse);
      expect((await store.load(shippedJson: baseline)).bundleVersion, 2);
      db.execute('UPDATE v2_rule_bundle SET json=? WHERE bundle_version=2', [
        '{}',
      ]);
      expect((await store.load(shippedJson: baseline)).bundleVersion, 1);
    },
  );
}
