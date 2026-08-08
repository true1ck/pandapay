import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// ui-spec.md F6 Data Export. "Your data is yours."
///
/// Judgment call: `share_plus` (the platform share sheet) is not a
/// pubspec.yaml dependency today, and this pass runs with no Flutter SDK
/// available to `pub get`/compile a newly-added native plugin against (see
/// PROGRESS.md). Rather than add an unverifiable dependency, this screen
/// scopes "share" down to a copy-to-clipboard action using
/// `package:flutter/services.dart` (already available everywhere) — the
/// generated export still round-trips through the real `GET /export`
/// route end to end, only the hand-off mechanism is narrower than a full
/// OS share sheet. Wiring an actual share sheet / file save is flagged as
/// a follow-up once a real device/toolchain can verify the dependency.
class DataExportScreen extends ConsumerStatefulWidget {
  const DataExportScreen({super.key});

  @override
  ConsumerState<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends ConsumerState<DataExportScreen> {
  String _scope = 'all';
  String _format = 'json';
  bool _generating = false;
  String? _preview;

  Future<void> _generate() async {
    final repo = ref.read(importRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _generating = true;
      _preview = null;
    });
    try {
      final (body, _, __) = await repo.fetchExport(scope: _scope, format: _format);
      setState(() => _preview = body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final repo = ref.watch(importRepositoryProvider);
    if (repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Export your data')),
        body: const EmptyState(icon: Icons.download_outlined, title: 'Sign in to export your data'),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Export your data')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your data is yours.', style: textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Export a copy of your transactions and/or cards. Nothing here is shared with anyone else.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpace.lg),
            Text('Scope', style: textTheme.labelLarge),
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                for (final s in const ['transactions', 'cards', 'all'])
                  ChoiceChip(label: Text(s), selected: _scope == s, onSelected: (_) => setState(() => _scope = s)),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            Text('Format', style: textTheme.labelLarge),
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                for (final f in const ['json', 'csv'])
                  ChoiceChip(
                    label: Text(f.toUpperCase()),
                    selected: _format == f,
                    onSelected: (_) => setState(() => _format = f),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            ElevatedButton.icon(
              icon: const Icon(Icons.download_outlined),
              label: Text(_generating ? 'Generating…' : 'Generate export'),
              onPressed: _generating ? null : _generate,
            ),
            const SizedBox(height: AppSpace.lg),
            if (_preview != null) ...[
              Row(
                children: [
                  Expanded(child: Text('Export ready (${_preview!.length} chars)', style: textTheme.titleSmall)),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    tooltip: 'Copy to clipboard',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _preview!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Copied — paste it wherever you want to save it')));
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
                  child: SingleChildScrollView(
                    child: Text(_preview!, style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
