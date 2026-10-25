import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';

void main() {
  test('preparation failure cleanup preserves gallery originals', () async {
    final root = await Directory.systemTemp.createTemp('pp-ocr-test-');
    final gallery = File('${root.path}/gallery.jpg');
    await gallery.writeAsString('original');
    final workspace = await PrivateTemporaryWorkspace.create(
      Directory('${root.path}/private'),
    );
    try {
      try {
        await workspace.file('first.jpg').writeAsString('generated');
        throw const FormatException('later preparation failed');
      } finally {
        await workspace.cleanup();
      }
    } on FormatException {
      expect(await gallery.readAsString(), 'original');
      expect(await workspace.directory.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test(
    'lost ownership marker preserves data and cleanup remains best effort',
    () async {
      final root = await Directory.systemTemp.createTemp('pp-marker-test-');
      try {
        final workspace = await PrivateTemporaryWorkspace.create(root);
        final copy = workspace.file('copy.jpg');
        await copy.writeAsString('copy');
        await File(
          '${workspace.directory.path}/${PrivateTemporaryWorkspace.markerName}',
        ).delete();
        expect(await workspace.cleanup(), isFalse);
        expect(await copy.readAsString(), 'copy');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'restart sweep caps deletion and preserves fresh, unmarked and linked data',
    () async {
      final root = await Directory.systemTemp.createTemp('pp-reap-test-');
      try {
        final gallery = Directory('${root.path}/gallery');
        await gallery.create();
        await File('${gallery.path}/original.jpg').writeAsString('original');
        final private = Directory('${root.path}/owned');
        await private.create();
        final unmarked = Directory('${private.path}/unmarked');
        await unmarked.create();
        for (var i = 0; i < 55; i++) {
          final token = i.toRadixString(16).padLeft(32, '0');
          final folder = Directory(
            '${private.path}/${PrivateTemporaryWorkspace.prefix}$token',
          );
          await folder.create();
          await File(
            '${folder.path}/${PrivateTemporaryWorkspace.markerName}',
          ).writeAsString(
            jsonEncode({
              'version': 1,
              'token': token,
              'created_at': DateTime.utc(2020).toIso8601String(),
            }),
          );
          await Link('${folder.path}/original-link').create(gallery.path);
        }
        final fresh = await PrivateTemporaryWorkspace.create(private);
        expect(await PrivateTemporaryWorkspace.reapStale(private), 50);
        expect(
          await File('${gallery.path}/original.jpg').readAsString(),
          'original',
        );
        expect(await unmarked.exists(), isTrue);
        expect(await fresh.directory.exists(), isTrue);
        expect(await PrivateTemporaryWorkspace.reapStale(private), 5);
        await fresh.cleanup();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
