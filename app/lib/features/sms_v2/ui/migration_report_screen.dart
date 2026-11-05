import 'dart:convert';
import '../../../app/local_sms_rig_build.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../../app/providers.dart' as app;
import '../providers/runtime_provider.dart';
import '../migration/legacy_replay.dart';
import '../storage/sync_state_store.dart';
import 'screen_parts.dart';
import 'history_update_panel.dart';

final migrationReportProvider = FutureProvider<ReplayReport?>((ref) async {
  ref.watch(app.financialStoreRevisionProvider('transactions'));
  final runtime = await ref.watch(smsV2RuntimeProvider.future);
  return runtime?.migration(await runtime.activeBundle()).savedReport();
});

final migrationPromptProvider = FutureProvider<ReplayReport?>((ref) async {
  final report = await ref.watch(migrationReportProvider.future);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  return SyncStateStore(
            cache.financialStore.database.db,
            namespace: namespace,
          ).get('migration:report-seen') ==
          '1'
      ? null
      : report;
});

class MigrationReportScreen extends ConsumerStatefulWidget {
  const MigrationReportScreen({super.key});
  @override
  ConsumerState<MigrationReportScreen> createState() =>
      _MigrationReportScreenState();
}

class _MigrationReportScreenState extends ConsumerState<MigrationReportScreen> {
  @override
  void initState() {
    super.initState();
    final namespace = ref.read(app.cacheNamespaceProvider);
    Future<void>(() async {
      final cache = await ref.read(app.responseCacheProvider.future);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      SyncStateStore(
        cache.financialStore.database.db,
        namespace: namespace,
      ).put('migration:report-seen', '1');
      ref.invalidate(migrationPromptProvider);
    });
  }

  ReplayReport? _preview;
  bool _busy = false;
  String? _error;
  Future<void> _dryRun() async {
    final namespace = ref.read(app.cacheNamespaceProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      if (runtime == null) throw StateError('No signed-in account');
      final report = await runtime.migrationDryRun();
      if (mounted && namespace == ref.read(app.cacheNamespaceProvider)) {
        setState(() => _preview = report);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t finish the dry run. Your history has not been changed.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your history update')),
    body: AppBackground(
      child: ref
          .watch(migrationReportProvider)
          .when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const SmsLoading(),
            error: (_, _) => SmsError(
              onRetry: () => ref.invalidate(migrationReportProvider),
            ),
            data: (saved) => ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.xxl,
              ),
              children: [
                if (LocalSmsRigBuild.controlsEnabled) ...[
                  HistoryUpdatePanel(
                    key: ValueKey(ref.watch(app.cacheNamespaceProvider)),
                    onApplied: () => ref.invalidate(migrationReportProvider),
                  ),
                  const SizedBox(height: AppSpace.xl),
                ],
                BambooTitleBlock(
                  title: _preview == null
                      ? 'Your retained history'
                      : 'Dry-run preview',
                  subtitle:
                      'Original entries are kept on this phone. Manual entries and messages without retained text stay as they were.',
                  icon: Icons.history_rounded,
                ),
                if (_preview ?? saved case final report?) ...[
                  const SizedBox(height: AppSpace.lg),
                  BambooPanel(
                    child: Column(
                      children: [
                        BambooFigureRow(
                          'Retained messages',
                          '${report.retainedBodies}',
                        ),
                        BambooFigureRow(
                          'Duplicate entries merged',
                          '${report.duplicatesMerged}',
                        ),
                        BambooFigureRow(
                          'IPO holds removed from spending',
                          '${report.holdsRemoved}',
                        ),
                        BambooFigureRow(
                          'Transfers removed from the count',
                          '${report.data['transfersRemoved']}',
                        ),
                        BambooFigureRow(
                          'Entries without text, kept as they were',
                          '${report.legacyWithoutBody}',
                        ),
                        BambooFigureRow(
                          'Messages still needing a reading',
                          '${report.data['uncheckedMessages']}',
                        ),
                      ],
                    ),
                  ),
                  const BambooSectionLabel(
                    'Month-by-month totals',
                    asTitle: true,
                  ),
                  BambooPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                      vertical: AppSpace.sm,
                    ),
                    child: Column(
                      children: [
                        for (final month in {
                          ...(report.data['beforeByMonth'] as Map).keys,
                          ...(report.data['afterByMonth'] as Map).keys,
                        }.cast<String>().toList()..sort())
                          BambooFigureRow(
                            month,
                            '${smsMoney(((report.data['beforeByMonth'] as Map)[month] as Map?)?['spendMinor'] as int? ?? 0)} → ${smsMoney(((report.data['afterByMonth'] as Map)[month] as Map?)?['spendMinor'] as int? ?? 0)}',
                          ),
                      ],
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: AppSpace.lg),
                  const BambooNote(
                    'No legacy migration report yet.',
                    icon: Icons.info_outline,
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: AppSpace.lg),
                  const ClipRRect(
                    borderRadius: BorderRadius.all(
                      Radius.circular(AppRadius.pill),
                    ),
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  BambooAlertNote(_error!),
                ],
                if (LocalSmsRigBuild.controlsEnabled) ...[
                  const SizedBox(height: AppSpace.lg),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _dryRun,
                    icon: const Icon(Icons.science_outlined, size: 18),
                    label: const Text('Dry run without changing history'),
                  ),
                ],
                if (LocalSmsRigBuild.controlsEnabled && _preview != null)
                  TextButton(
                    style: BambooButtons.quiet,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Local dry-run report'),
                        content: SingleChildScrollView(
                          child: SelectableText(
                            const JsonEncoder.withIndent(
                              '  ',
                            ).convert(_preview!.toJson()),
                            style: BambooFonts.ui(12, color: BambooInk.ink700),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('View report details'),
                  ),
              ],
            ),
          ),
    ),
  );
}
