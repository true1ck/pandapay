import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'private_temporary_workspace.dart';

/// Generated OCR copies share a marked app-owned root. No gallery/picker
/// source path is ever passed to recursive cleanup. Failure to obtain private
/// storage fails preparation rather than falling back to a public directory.
class AppPrivateTemporaryStorage {
  static Future<Directory> root() async => Directory(
    path.join(
      (await getTemporaryDirectory()).path,
      'pandapay-private-workspaces-v1',
    ),
  );

  static Future<PrivateTemporaryWorkspace> create() async {
    final directory = await root();
    // Also cover restarts that do not reach the normal app entrypoint.
    await PrivateTemporaryWorkspace.reapStale(directory);
    return PrivateTemporaryWorkspace.create(directory);
  }

  static Future<void> reapOnStartup() async {
    try {
      await PrivateTemporaryWorkspace.reapStale(await root());
    } on Object {
      // Missing/locked temporary storage must not interrupt ordinary sign-in.
      // The next OCR operation retries cleanup and reports preparation errors.
    }
  }
}
