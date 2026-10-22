/// Interfaces shared by the portable-backup export screen and the archive
/// coordinator.
///
/// The coordinator owns the archive, local snapshot, encryption and staging
/// details. The screen only needs a small, testable interface: progress,
/// cancellation and a verified artifact that can be handed to the platform
/// share sheet.
library;

enum PortableBackupExportStage {
  preparing,
  drainingSync,
  snapshotting,
  assembling,
  encrypting,
  verifying,
  ready,
}

extension PortableBackupExportStageLabel on PortableBackupExportStage {
  String get label => switch (this) {
    PortableBackupExportStage.preparing => 'Preparing secure backup',
    PortableBackupExportStage.drainingSync => 'Finishing pending sync',
    PortableBackupExportStage.snapshotting => 'Capturing your data',
    PortableBackupExportStage.assembling => 'Assembling backup sections',
    PortableBackupExportStage.encrypting => 'Encrypting backup',
    PortableBackupExportStage.verifying => 'Checking backup',
    PortableBackupExportStage.ready => 'Backup ready',
  };
}

class PortableBackupProgress {
  final PortableBackupExportStage stage;
  final double? fraction;
  final String? detail;

  const PortableBackupProgress({
    required this.stage,
    this.fraction,
    this.detail,
  });
}

/// Cooperative cancellation shared with the archive writer. A writer should
/// check [isCancelled] between bounded reads/writes and clean its private
/// staging directory before completing with [PortableBackupCancelled].
class PortableBackupCancellation {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

class PortableBackupArtifact {
  final String path;
  final String fileName;
  final int sectionCount;
  final int recordCount;
  final int encryptedBytes;
  final List<String> exclusions;
  final String verificationDigest;
  final DateTime snapshotAt;

  const PortableBackupArtifact({
    required this.path,
    required this.fileName,
    required this.sectionCount,
    required this.recordCount,
    required this.encryptedBytes,
    required this.exclusions,
    required this.verificationDigest,
    required this.snapshotAt,
  });
}

typedef PortableBackupProgressCallback = void Function(
  PortableBackupProgress progress,
);

abstract interface class PortableBackupExporter {
  Future<PortableBackupArtifact> export({
    required String passphrase,
    required PortableBackupCancellation cancellation,
    required PortableBackupProgressCallback onProgress,
  });
}

class PortableBackupCancelled implements Exception {
  const PortableBackupCancelled();

  @override
  String toString() => 'Portable backup cancelled';
}

class PortableBackupUnavailable implements Exception {
  const PortableBackupUnavailable();

  @override
  String toString() => 'Portable backup is not available';
}

