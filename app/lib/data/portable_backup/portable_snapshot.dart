import 'dart:async';
import 'dart:io';

import 'canonical_ndjson.dart';
import 'portable_attachments.dart';

/// All queues that can make a local export incomplete report their pending
/// counts through this value. A single nonzero count blocks `complete: true`.
class PortableOutboxStatus {
  final Map<String, int> pendingByQueue;

  const PortableOutboxStatus(this.pendingByQueue);

  int get totalPending => pendingByQueue.values.fold(0, (sum, count) => sum + count);

  bool get isDrained => totalPending == 0;

  Map<String, int> get nonZeroQueues => Map.unmodifiable(
        <String, int>{
          for (final entry in pendingByQueue.entries)
            if (entry.value != 0) entry.key: entry.value,
        },
      );

  void requireDrained() {
    if (!isDrained) throw PortablePendingOutboxException(nonZeroQueues);
  }
}

class PortablePendingOutboxException implements Exception {
  final Map<String, int> pendingByQueue;

  const PortablePendingOutboxException(this.pendingByQueue);

  int get totalPending => pendingByQueue.values.fold(0, (sum, count) => sum + count);

  @override
  String toString() => 'portable backup requires drained queues: $pendingByQueue';
}

/// Adapter implemented by the integration layer around AppDatabase and sync.
/// This keeps backup code from bypassing existing outbox semantics.
abstract interface class PortableLocalSnapshotSource {
  Future<PortableOutboxStatus> drainAndVerifyOutboxes({
    Future<bool> Function()? isCancelled,
  });

  /// Returns canonical section files in private staging storage. Each file is
  /// complete before it is returned and must remain readable until assembly.
  Future<Map<String, File>> capturePortableSections({
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  });

  Future<List<PortableAttachmentSource>> listPortableAttachments();
}

/// Coordination contract for local capture. Server extraction and archive
/// assembly are supplied by the parent integration layer.
class PortableLocalSnapshotCoordinator {
  final PortableLocalSnapshotSource source;

  const PortableLocalSnapshotCoordinator(this.source);

  Future<PortableLocalSnapshot> capture({
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    await _throwIfCancelled(isCancelled);
    final status = await source.drainAndVerifyOutboxes(isCancelled: isCancelled);
    status.requireDrained();
    await _throwIfCancelled(isCancelled);
    final sections = await source.capturePortableSections(
      stagingDirectory: stagingDirectory,
      isCancelled: isCancelled,
    );
    await _throwIfCancelled(isCancelled);
    final attachments = await source.listPortableAttachments();
    return PortableLocalSnapshot(
      outboxStatus: status,
      sectionFiles: sections,
      attachmentSources: attachments,
    );
  }

  static Future<void> _throwIfCancelled(Future<bool> Function()? isCancelled) async {
    if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
  }
}

class PortableLocalSnapshot {
  final PortableOutboxStatus outboxStatus;
  final Map<String, File> sectionFiles;
  final List<PortableAttachmentSource> attachmentSources;

  const PortableLocalSnapshot({
    required this.outboxStatus,
    required this.sectionFiles,
    required this.attachmentSources,
  });
}
