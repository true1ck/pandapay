import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pandapay/data/secure_storage/flutter_secure_key_value_store.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native secure storage retains and binds local DB key metadata', (
    tester,
  ) async {
    final installId = 'integration-${DateTime.now().microsecondsSinceEpoch}';
    final adapter = FlutterSecureKeyValueStore(
      prefix: 'pandapay.integration.localdb.$installId.',
    );
    final custody = LocalDatabaseKeyCustody(adapter);
    try {
      final created = await custody.openKey(
        installId: installId,
        encryptedManifestExists: false,
      );
      expect(created.status, LocalKeyStatus.provisioned);
      final expected = created.handle!.withKeyBytes(base64Encode);
      created.handle!.dispose();
      final reopened = await LocalDatabaseKeyCustody(
        adapter,
      ).openKey(installId: installId, encryptedManifestExists: true);
      expect(reopened.status, LocalKeyStatus.existing);
      expect(reopened.handle!.withKeyBytes(base64Encode), expected);
      reopened.handle!.dispose();
    } finally {
      await adapter.delete('pandapay.localdb.key_metadata.v1');
      await adapter.delete('pandapay.localdb.key.v1.1');
    }
  });
}
