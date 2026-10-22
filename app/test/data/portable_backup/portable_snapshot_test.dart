import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';

void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('portable-snapshot-');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await staging.exists()) return;
        await staging.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test('capture refuses to export while an outbox is pending', () async {
    final coordinator = PortableLocalSnapshotCoordinator(_FakeSource(
      pending: {'transactions_sync': 3, 'attachments_upload': 1},
    ));
    await expectLater(
      coordinator.capture(stagingDirectory: staging),
      throwsA(isA<PortablePendingOutboxException>()),
    );
  });

  test('capture coordinates drain -> sections -> attachments order', () async {
    final order = <String>[];
    final sectionFile = File('${staging.path}${Platform.pathSeparator}cards.ndjson');
    final coordinator = PortableLocalSnapshotCoordinator(_FakeSource(
      pending: const {},
      calls: order,
      sectionsBuilder: () => {
        'cards': sectionFile..writeAsBytesSync([]),
      },
    ));
    final snapshot = await coordinator.capture(stagingDirectory: staging);
    expect(order, ['drainAndVerifyOutboxes', 'capturePortableSections', 'listPortableAttachments']);
    expect(snapshot.outboxStatus.isDrained, isTrue);
    expect(snapshot.sectionFiles, same(snapshot.sectionFiles));
    expect(snapshot.attachmentSources, isEmpty);
  });

  test('capture surfaces cancellation before mutating the source', () async {
    final order = <String>[];
    final coordinator = PortableLocalSnapshotCoordinator(_FakeSource(
      pending: const {},
      calls: order,
    ));
    await expectLater(
      coordinator.capture(
        stagingDirectory: staging,
        isCancelled: () async => true,
      ),
      throwsA(isA<PortableBackupCancelled>()),
    );
    expect(order, isEmpty);
  });

  test('capture surfaces cancellation between drain and sections', () async {
    final order = <String>[];
    var calls = 0;
    final coordinator = PortableLocalSnapshotCoordinator(_FakeSource(
      pending: const {},
      calls: order,
      interceptor: () => ++calls,
    ));
    await expectLater(
      coordinator.capture(
        stagingDirectory: staging,
        isCancelled: () async => calls >= 1,
      ),
      throwsA(isA<PortableBackupCancelled>()),
    );
    expect(order, ['drainAndVerifyOutboxes']);
  });
}

class _FakeSource implements PortableLocalSnapshotSource {
  final Map<String, int> pending;
  final List<String>? calls;
  final Map<String, File> Function()? sectionsBuilder;
  final void Function()? interceptor;

  const _FakeSource({
    required this.pending,
    this.calls,
    this.sectionsBuilder,
    this.interceptor,
  });

  @override
  Future<PortableOutboxStatus> drainAndVerifyOutboxes({
    Future<bool> Function()? isCancelled,
  }) async {
    if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
    calls?.add('drainAndVerifyOutboxes');
    interceptor?.call();
    return PortableOutboxStatus(pending);
  }

  @override
  Future<Map<String, File>> capturePortableSections({
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
    calls?.add('capturePortableSections');
    interceptor?.call();
    return sectionsBuilder?.call() ?? const {};
  }

  @override
  Future<List<PortableAttachmentSource>> listPortableAttachments() async {
    calls?.add('listPortableAttachments');
    return const [];
  }
}

