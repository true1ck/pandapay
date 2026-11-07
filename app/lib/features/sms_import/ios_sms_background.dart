import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/app_database.dart';
import '../../data/local/database_key.dart';
import '../../data/local/financial_store.dart';
import '../../data/local/ios_sms_acquisition_receipts.dart';
import '../../data/local/sms_import_store.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/secure_storage/install_guard.dart';
import 'ios_shortcut_sms.dart';
import 'ios_sms_intake_service.dart';

/// A cold background launch drains only durable, account-labelled input. It
/// never restores credentials, searches Messages, launches Shortcuts or uploads.
class IosSmsBackgroundDrain {
  final IosSmsIntakeService service;
  final Future<AppDatabase> Function() openDatabase;
  final Future<String?> Function() readNamespace;
  bool stopped = false;

  IosSmsBackgroundDrain({
    required this.service,
    required this.openDatabase,
    required this.readNamespace,
  });

  Future<Map<String, Object?>> run() async {
    final initial = Map<String, Object?>.from(
      (await service.call('snapshot'))! as Map,
    );
    final namespace = initial['namespace'] as String?;
    final generation = initial['generation'] as String?;
    if (initial['enabled'] != true ||
        namespace == null ||
        generation == null ||
        !namespace.startsWith('user:') ||
        await readNamespace() != namespace) {
      return {'success': false};
    }
    AppDatabase? database;
    FinancialStore? store;
    try {
      while (!stopped) {
        final snapshot = Map<String, Object?>.from(
          (await service.call('snapshot'))! as Map,
        );
        if (snapshot['namespace'] != namespace ||
            snapshot['generation'] != generation ||
            snapshot['enabled'] != true ||
            await readNamespace() != namespace) {
          return {'success': false};
        }
        final rows =
            ((await service.call('pending', {'generation': generation}))!
                    as List)
                .map((r) => Map<Object?, Object?>.from(r as Map))
                .toList();
        if (rows.isEmpty) return {'success': true};
        if (stopped) break;
        try {
          database ??= await openDatabase();
        } on DatabaseKeyUnavailable {
          // The phone has not been unlocked since boot, so the key is not
          // readable yet. Leave every message in the native spool.
          return {'success': false};
        }
        // Opening storage can await a plugin while account restoration or
        // logout proceeds on the UI engine. Recheck before any mutation.
        final owner = Map<String, Object?>.from(
          (await service.call('snapshot'))! as Map,
        );
        if (stopped ||
            owner['namespace'] != namespace ||
            owner['generation'] != generation ||
            owner['enabled'] != true ||
            await readNamespace() != namespace) {
          return {'success': false};
        }
        store ??= FinancialStore(database);
        final batch = IosShortcutSmsBatch.fromRows(
          rows,
          allowSenderInference: false,
        );
        if (batch.messages.length + batch.sensitive != rows.length) {
          throw StateError('Shortcut input needs attention');
        }
        SmsImportStore(store).captureBatch(namespace, batch.messages);
        final outcomes = IosSmsAcquisitionReceipts(
          store,
        ).record(namespace, generation, rows);
        // Native generation checks reject a late acknowledgement after logout.
        await service.call('acknowledge', {
          'generation': generation,
          'outcomes': outcomes,
        });
        // Give expiration and account-change callbacks a turn between commits.
        await Future<void>.delayed(Duration.zero); // perf-ok: iOS background isolate, not the UI isolate
      }
      return {'success': false};
    } finally {
      store?.dispose();
      database?.close();
    }
  }
}

class _BackgroundIntakeService extends IosSmsIntakeService {
  static const backgroundChannel = MethodChannel('pandapay/ios_sms_background');
  @override
  Future<Object?> call(String method, [Map<String, Object?>? arguments]) =>
      backgroundChannel.invokeMethod<Object?>(method, arguments);
}

@pragma('vm:entry-point')
Future<void> iosSmsBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A reinstall can leave Keychain items behind; clear them before the
  // database key is read.
  try {
    await InstallGuard.ensure();
  } catch (_) {
    // Keychain not readable yet (no unlock since boot). The drain then fails
    // to open the database and leaves every message in the spool.
  }
  final drain = IosSmsBackgroundDrain(
    service: _BackgroundIntakeService(),
    openDatabase: AppDatabase.open,
    readNamespace: () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(smsCaptureNamespaceKey);
    },
  );
  _BackgroundIntakeService.backgroundChannel.setMethodCallHandler((call) async {
    if (call.method == 'stop') {
      drain.stopped = true;
      return null;
    }
    if (call.method == 'drain') {
      try {
        return await drain.run();
      } catch (_) {
        return {'success': false};
      }
    }
    return null;
  });
  await _BackgroundIntakeService.backgroundChannel.invokeMethod<void>('ready');
}
