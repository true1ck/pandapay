import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/local_snapshot_source.dart';
import 'package:pandapay/data/portable_backup/local_restore_writer.dart';
import 'package:pandapay/data/portable_backup/portable_attachments.dart';

const account = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const namespace = 'user:$account';
void main() {
  test('pending encrypted import blocks portable completion and account capture/restore without changing data', () async {
    final root = await Directory.systemTemp.createTemp('import-recovery-guard-');
    final database = AppDatabase.openUnencryptedFileForTesting('${root.path}/fixture.sqlite');
    try {
      database.db.execute('CREATE TABLE statement_import_batches(namespace TEXT,ciphertext BLOB)');
      database.db.execute('INSERT INTO statement_import_batches VALUES (?,?)',[namespace,Uint8List.fromList([1,2,3])]);
      final source=LocalPortableSnapshotSource(appDb:database,namespace:namespace);
      final status=await source.drainAndVerifyOutboxes();
      expect(status.isDrained,isFalse);
      final target=LocalPortableRestoreTargetInspector(appDb:database,namespace:namespace);
      expect((await target.inspectFreshNamespace()).hasPortableRows,isTrue);
      final writer=LocalPortableRestoreWriter(appDb:database,namespace:namespace,receipts:_NoReceipts());
      await expectLater(writer.beginFreshNamespace(),throwsStateError);
      expect(database.db.select('SELECT hex(ciphertext) AS data FROM statement_import_batches').single['data'],'010203');
      database.db.execute('INSERT INTO profile_name_cache(namespace,display_name) VALUES (?,?)',[namespace,'Writer still available']);
    } finally {database.close();await root.delete(recursive:true);}
  });
}

/// This test installs no attachments; any use is a test failure.
final class _NoReceipts implements PortableReceiptVault {
  @override
  Future<Uint8List> readPlaintext(PortableAttachmentSource source) =>
      throw UnimplementedError();

  @override
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  }) => throw UnimplementedError();
}
