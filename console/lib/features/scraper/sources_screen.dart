import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-3.1/AD-3.2 scraper source registry — previously read-only-at-the-
/// schema-level (sources existed since 0008_admin_console.sql, the 12
/// candidate rows in scraper/CANDIDATE_SOURCES.md sit there right now with
/// tos_reviewed=false/is_enabled=false), but nothing in the console let an
/// operator actually review and flip those flags, or register a new
/// candidate source. This screen is that missing surface: list every
/// source, mark ToS-reviewed (with a note), enable/disable (blocked by the
/// DB's own CHECK constraint from ever enabling before review — this UI
/// just reflects that, doesn't reimplement it), and add a new one.
class SourcesScreen extends ConsumerWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSourceDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add source'),
      ),
      body: sources.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Failed to load sources: $err')),
        data: (sourceList) {
          if (sourceList.isEmpty) {
            return const Center(child: Text('No sources registered.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: sourceList.length,
            itemBuilder: (context, index) => _SourceTile(sourceList[index]),
          );
        },
      ),
    );
  }

  void _showAddSourceDialog(BuildContext context, WidgetRef ref) {
    showDialog(context: context, builder: (_) => _AddSourceDialog(ref: ref));
  }
}

class _SourceTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> source;
  const _SourceTile(this.source);

  @override
  ConsumerState<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends ConsumerState<_SourceTile> {
  bool _busy = false;
  String? _error;
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.source['tos_note'] as String? ?? '');
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(sourcesProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final tosReviewed = source['tos_reviewed'] as bool? ?? false;
    final isEnabled = source['is_enabled'] as bool? ?? false;
    final api = ref.read(adminApiProvider);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          isEnabled ? Icons.check_circle : (tosReviewed ? Icons.pause_circle_outline : Icons.warning_amber_rounded),
          color: isEnabled ? Colors.green : (tosReviewed ? Colors.grey : Colors.orange),
        ),
        title: Text(source['name'] as String? ?? ''),
        subtitle: Text('${source['kind']} · ${source['base_url']} · ${source['page_count']} pages'
            '${tosReviewed ? ' · ToS reviewed' : ' · ToS NOT reviewed'}'
            '${isEnabled ? ' · enabled' : ' · disabled'}'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _noteController,
                  decoration: const InputDecoration(labelText: 'ToS review note', isDense: true),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (!tosReviewed)
                      FilledButton(
                        onPressed: _busy || api == null
                            ? null
                            : () => _act(() => api.updateSource(
                                  source['id'] as String,
                                  tosReviewed: true,
                                  tosNote: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
                                  reason: 'Console: ToS reviewed',
                                )),
                        child: const Text('Mark ToS reviewed'),
                      ),
                    if (tosReviewed)
                      OutlinedButton(
                        onPressed: _busy || api == null
                            ? null
                            : () => _act(() => api.updateSource(
                                  source['id'] as String,
                                  isEnabled: !isEnabled,
                                  reason: isEnabled ? 'Console: disabled' : 'Console: enabled',
                                )),
                        child: Text(isEnabled ? 'Disable' : 'Enable'),
                      ),
                    OutlinedButton(
                      onPressed: _busy || api == null
                          ? null
                          : () => _act(() => api.updateSource(
                                source['id'] as String,
                                tosNote: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
                                reason: 'Console: updated ToS note',
                              )),
                      child: const Text('Save note'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AddSourceDialog extends StatefulWidget {
  final WidgetRef ref;
  const _AddSourceDialog({required this.ref});

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  String _kind = 'bank_official';
  bool _saving = false;
  String? _error;

  static const _kinds = ['bank_official', 'news_review', 'regulator', 'other'];

  Future<void> _save() async {
    final api = widget.ref.read(adminApiProvider);
    if (api == null) return;
    if (_nameController.text.trim().isEmpty || _urlController.text.trim().isEmpty) {
      setState(() => _error = 'Name and URL are required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await api.createSource(
        kind: _kind,
        name: _nameController.text.trim(),
        baseUrl: _urlController.text.trim(),
        reason: 'Console: new candidate source',
      );
      widget.ref.invalidate(sourcesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add candidate source'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: _urlController, decoration: const InputDecoration(labelText: 'Base URL')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [for (final k in _kinds) DropdownMenuItem(value: k, child: Text(k))],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? '...' : 'Create')),
      ],
    );
  }
}
