import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/ios_sms_acquisition_receipts.dart';
import 'ios_sms_intake_controller.dart';
import 'ios_sms_intake_service.dart';

final iosSmsIntakeServiceProvider = Provider<IosSmsIntakeService>(
  (ref) => IosSmsIntakeService(),
);

final iosSmsIntakeControllerProvider =
    ChangeNotifierProvider<IosSmsIntakeController>((ref) {
      final service = ref.watch(iosSmsIntakeServiceProvider);
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => ref.read(cacheNamespaceProvider),
        requestUpload: () => ref.read(smsFlushTriggerProvider.notifier).state++,
        capture: (namespace, generation, rows) async {
          final owner = ref.read(smsAutoImportProvider);
          final batch = await owner.captureShortcutMessages(
            expectedNamespace: namespace,
            records: rows,
          );
          if (batch.messages.length != rows.length ||
              ref.read(cacheNamespaceProvider) != namespace) {
            throw StateError('Shortcut input needs attention');
          }
          final cache = await ref.read(responseCacheProvider.future);
          if (ref.read(cacheNamespaceProvider) != namespace) {
            throw StateError('Account changed');
          }
          return IosSmsAcquisitionReceipts(
            cache.financialStore,
          ).record(namespace, generation, rows);
        },
      );
      ref.listen<String>(cacheNamespaceProvider, (previous, next) {
        if (!service.supported || previous == next) return;
        unawaited(
          controller
              .accountChanged()
              .then((_) => controller.refresh())
              .catchError((Object _) {}),
        );
      });
      return controller;
    });

/// Mounted by the shell after its first usable frame, also used by SMS setup
/// during onboarding. It never waits for SMS work before displaying the app.
final iosSmsIntakeLifecycleProvider = Provider<void>((ref) {
  final service = ref.watch(iosSmsIntakeServiceProvider);
  if (!service.supported) return;
  final controller = ref.read(iosSmsIntakeControllerProvider);
  void refresh() => unawaited(controller.refresh());
  final listener = AppLifecycleListener(onResume: refresh);
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    listener.dispose();
  });
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!disposed) refresh();
  });
});
