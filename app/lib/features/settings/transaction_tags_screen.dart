import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/transaction_tag_picker.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

class TransactionTagsScreen extends ConsumerStatefulWidget {
  const TransactionTagsScreen({super.key});

  @override
  ConsumerState<TransactionTagsScreen> createState() =>
      _TransactionTagsScreenState();
}

class _TransactionTagsScreenState extends ConsumerState<TransactionTagsScreen> {
  bool _busy = false;
  bool _showArchived = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([TransactionTag? tag]) async {
    final repository = ref.read(transactionTagsProvider);
    if (repository == null) return;
    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (_) => _TagEditorDialog(tag: tag),
    );
    if (result == null ||
        !mounted ||
        ref.read(transactionTagsProvider) != repository)
      return;
    await _run(() async {
      if (tag == null) {
        await repository.create(result.$1, result.$2);
      } else {
        await repository.rename(tag.id, result.$1, color: result.$2);
      }
    });
  }

  Future<void> _archive(TransactionTag tag) async {
    final repository = ref.read(transactionTagsProvider);
    if (repository == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive “${tag.name}”?'),
        content: const Text(
          'Existing transactions keep this tag. It will be hidden when choosing tags for new transactions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        ref.read(transactionTagsProvider) == repository) {
      await _run(() => repository.archive(tag.id));
    }
  }

  Future<void> _merge(TransactionTag source) async {
    final repository = ref.read(transactionTagsProvider);
    if (repository == null) return;
    final targets = repository.tags
        .where((tag) => tag.id != source.id)
        .toList();
    if (targets.isEmpty) return;
    String? targetId;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Merge “${source.name}”'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Move its ${repository.usageCount(source.id)} transactions to another tag, then archive “${source.name}”. Transactions already using both tags are counted once.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: targetId,
                decoration: const InputDecoration(labelText: 'Merge into'),
                items: [
                  for (final tag in targets)
                    DropdownMenuItem(
                      value: tag.id,
                      child: Text(tag.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => setDialogState(() => targetId = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: targetId == null
                  ? null
                  : () => Navigator.of(context).pop(targetId),
              child: const Text('Merge tags'),
            ),
          ],
        ),
      ),
    );
    if (selected != null &&
        mounted &&
        ref.read(transactionTagsProvider) == repository) {
      await _run(() => repository.merge(source.id, selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(transactionTagsProvider);
    final tags =
        (_showArchived ? repository?.allTags : repository?.tags) ??
        const <TransactionTag>[];
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        title: Text('Manage tags', style: BambooFonts.heading(18)),
        actions: [
          IconButton(
            tooltip: 'Create tag',
            onPressed: repository == null || _busy ? null : () => _edit(),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: AppBackground(
        child: repository == null
            ? const Center(
                child: Text('Tags are still loading. Try again shortly.'),
              )
            : ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  Text(
                    'Group transactions across categories with tags such as Office, Reimbursable, or Thailand trip.',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                  SwitchListTile.adaptive(
                    title: const Text('Show archived tags'),
                    value: _showArchived,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (value) => setState(() => _showArchived = value),
                  ),
                  if (repository.pendingCount > 0)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: Text(
                        '${repository.pendingCount} tag changes waiting to sync',
                      ),
                      subtitle: const Text(
                        'Saved on this device. Syncs when connected.',
                      ),
                      trailing: IconButton(
                        tooltip: 'Retry tag sync',
                        onPressed: _busy || repository.isSyncing
                            ? null
                            : () => _run(repository.sync),
                        icon: const Icon(Icons.sync_rounded),
                      ),
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (repository.lastError != null &&
                      repository.pendingCount > 0)
                    Text(
                      'Some tag changes need attention. A matching name may already exist on another device. Rename the local tag and retry sync.',
                      style: BambooFonts.ui(12, color: BambooInk.clay),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: BambooFonts.ui(13, color: BambooInk.clay),
                      ),
                    ),
                  if (tags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No tags yet. Create a tag to start grouping transactions.',
                      ),
                    ),
                  for (final tag in tags)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.label_rounded,
                        color: transactionTagColor(tag.color),
                      ),
                      title: Text(tag.name),
                      subtitle: Text(
                        '${repository.usageCount(tag.id)} transactions${tag.archivedAt == null ? '' : ' · Archived'}',
                      ),
                      onTap: _busy ? null : () => _edit(tag),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Manage ${tag.name}',
                        enabled: !_busy,
                        onSelected: (action) {
                          switch (action) {
                            case 'edit':
                              _edit(tag);
                            case 'archive':
                              _archive(tag);
                            case 'merge':
                              _merge(tag);
                            case 'restore':
                              _run(() => repository.archive(tag.id, false));
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Rename or change color'),
                          ),
                          if (tag.archivedAt == null)
                            const PopupMenuItem(
                              value: 'archive',
                              child: Text('Archive'),
                            ),
                          if (tag.archivedAt != null)
                            const PopupMenuItem(
                              value: 'restore',
                              child: Text('Restore'),
                            ),
                          if (repository.tags.any(
                            (other) => other.id != tag.id,
                          ))
                            const PopupMenuItem(
                              value: 'merge',
                              child: Text('Merge into another tag'),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _edit(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Create tag'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _TagEditorDialog extends StatefulWidget {
  final TransactionTag? tag;
  const _TagEditorDialog({this.tag});

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  late String? _color = widget.tag?.color;
  static const _colors = <String?, String>{
    null: 'Default',
    '#52796F': 'Green',
    '#3D6FA3': 'Blue',
    '#8A5BA6': 'Purple',
    '#B8515D': 'Rose',
    '#B6762F': 'Amber',
    '#61717B': 'Slate',
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.tag == null ? 'Create tag' : 'Edit tag'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Tag name',
              hintText: 'e.g. Thailand trip',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          const Text('Color'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in _colors.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  avatar: Icon(
                    Icons.circle,
                    size: 14,
                    color: transactionTagColor(entry.key),
                  ),
                  selected: _color == entry.key,
                  onSelected: (_) => setState(() => _color = entry.key),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop((_name.text.trim(), _color)),
        child: const Text('Save'),
      ),
    ],
  );
}
