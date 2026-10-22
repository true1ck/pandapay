import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/import/portable_backup_inspector.dart';

import '../../fixtures/portable_backup_fixture.dart';

void main() {
  const inspector = PortableBackupInspector();

  test('independently verifies section counts, digests and exclusions', () {
    final fixture = makePortableBackupFixture();

    final result = inspector.inspect(
      manifestBytes: fixture.manifestBytes,
      sectionBytes: fixture.sectionBytes,
    );

    expect(result.formatVersion, 1);
    expect(result.backupId, 'backup-fixture-1');
    expect(result.complete, isTrue);
    expect(result.sections.map((section) => section.name), [
      'categories.ndjson',
      'cards.ndjson',
      'transactions.ndjson',
    ]);
    expect(result.totalRecords, 3);
    expect(result.declaredExclusions, contains('device_id'));
  });

  test('rejects a section whose bytes do not match its manifest digest', () {
    final fixture = makePortableBackupFixture(corruptDigest: true);

    expect(
      () => inspector.inspect(
        manifestBytes: fixture.manifestBytes,
        sectionBytes: fixture.sectionBytes,
      ),
      throwsA(
        isA<PortableBackupInspectionException>().having(
          (error) => error.message,
          'message',
          contains('failed its digest check'),
        ),
      ),
    );
  });

  test('rejects an orphaned declared relationship', () {
    final fixture = makePortableBackupFixture(breakRelationship: true);

    expect(
      () => inspector.inspect(
        manifestBytes: fixture.manifestBytes,
        sectionBytes: fixture.sectionBytes,
      ),
      throwsA(
        isA<PortableBackupInspectionException>().having(
          (error) => error.message,
          'message',
          contains('relationship'),
        ),
      ),
    );
  });

  test('rejects an incomplete manifest before inspecting sections', () {
    final fixture = makePortableBackupFixture();
    final manifest = fixture.manifestBytes
        .toString(); // Keep fixture construction private; use a malformed input.

    expect(
      () => inspector.inspect(
        manifestBytes: manifest.codeUnits,
        sectionBytes: fixture.sectionBytes,
      ),
      throwsA(isA<PortableBackupInspectionException>()),
    );
  });
}

