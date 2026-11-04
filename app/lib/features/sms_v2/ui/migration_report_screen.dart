import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    body: ref
        .watch(migrationReportProvider)
        .when(
          loading: () => const SmsLoading(),
          error: (_, _) =>
              SmsError(onRetry: () => ref.invalidate(migrationReportProvider)),
          data: (saved) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (kDebugMode)
                HistoryUpdatePanel(
                  key: ValueKey(ref.watch(app.cacheNamespaceProvider)),
                  onApplied: () => ref.invalidate(migrationReportProvider),
                ),
              Text(
                _preview == null ? 'Your retained history' : 'Dry-run preview',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Original entries are kept on this phone. Manual entries and messages without retained text stay as they were.',
              ),
              if (_preview ?? saved case final report?) ...[
                const SizedBox(height: 24),
                Text('${report.retainedBodies} retained messages'),
                Text('${report.duplicatesMerged} duplicate entries merged'),
                Text('${report.holdsRemoved} IPO holds removed from spending'),
                Text(
                  '${report.data['transfersRemoved']} transfers removed from the count',
                ),
                Text(
                  '${report.legacyWithoutBody} entries without text kept as they were',
                ),
                Text(
                  '${report.data['uncheckedMessages']} messages still need a reading',
                ),
                const SizedBox(height: 24),
                Text(
                  'Month-by-month totals',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final month in {
                  ...(report.data['beforeByMonth'] as Map).keys,
                  ...(report.data['afterByMonth'] as Map).keys,
                }.cast<String>().toList()..sort())
                  Card(
                    child: ListTile(
                      title: Text(month),
                      subtitle: Text(
                        'Spending ${smsMoney(((report.data['beforeByMonth'] as Map)[month] as Map?)?['spendMinor'] as int? ?? 0)} → ${smsMoney(((report.data['afterByMonth'] as Map)[month] as Map?)?['spendMinor'] as int? ?? 0)}',
                      ),
                    ),
                  ),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No legacy migration report yet.'),
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              if (kDebugMode)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _dryRun,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Dry run without changing history'),
                ),
              if (kDebugMode && _preview != null)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Local dry-run report'),
                      content: SingleChildScrollView(
                        child: SelectableText(
                          const JsonEncoder.withIndent(
                            '  ',
                          ).convert(_preview!.toJson()),
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
  );
}
