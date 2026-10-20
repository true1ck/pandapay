import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_exception.dart';
import '../data/user_cards_repository.dart';
import 'design/app_theme.dart';
import 'providers.dart';

/// Cancel returns null; applying an empty set explicitly removes all tags.
Future<Set<String>?> showTransactionTagPicker(
  BuildContext context, {
  Set<String> selectedIds = const {},
  String title = 'Tags',
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: BambooInk.paper,
  builder: (_) => _TransactionTagPicker(selectedIds: selectedIds, title: title),
);

Color transactionTagColor(String? value) {
  final hex = value?.replaceFirst('#', '') ?? '';
  final parsed = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
  return parsed == null ? BambooInk.slate : Color(0xff000000 | parsed);
}

/// A compact, optional multi-select field shared by transaction/import forms.
class TransactionTagField extends ConsumerWidget {
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;
  final String label;

  const TransactionTagField({
    super.key,
    required this.selectedIds,
    required this.onChanged,
    this.enabled = true,
    this.label = 'Tags',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(transactionTagsProvider);
    final tags = repository?.allTags ?? const <TransactionTag>[];
    final selected = tags.where((tag) => selectedIds.contains(tag.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: BambooFonts.ui(13, weight: FontWeight.w600),
              ),
            ),
            Text(
              selectedIds.isEmpty
                  ? 'Optional'
                  : '${selectedIds.length} selected',
              style: BambooFonts.ui(11, color: BambooInk.ink500),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in selected)
              InputChip(
                label: Text(tag.name),
                avatar: Icon(
                  Icons.label_rounded,
                  size: 16,
                  color: transactionTagColor(tag.color),
                ),
                onDeleted: enabled && repository != null
                    ? () => onChanged({...selectedIds}..remove(tag.id))
                    : null,
                deleteButtonTooltipMessage: 'Remove ${tag.name}',
              ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                repository == null ? 'Tags unavailable' : 'Choose tags',
              ),
              onPressed: !enabled || repository == null
                  ? null
                  : () async {
                      final result = await showTransactionTagPicker(
                        context,
                        selectedIds: selectedIds,
                        title: label,
                      );
                      if (result != null && context.mounted) onChanged(result);
                    },
            ),
          ],
        ),
      ],
    );
  }
}

class _TransactionTagPicker extends ConsumerStatefulWidget {
  final Set<String> selectedIds;
  final String title;

  const _TransactionTagPicker({required this.selectedIds, required this.title});

  @override
  ConsumerState<_TransactionTagPicker> createState() =>
      _TransactionTagPickerState();
}

class _TransactionTagPickerState extends ConsumerState<_TransactionTagPicker> {
  final _search = TextEditingController();
  late final Set<String> _selected = {...widget.selectedIds};
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _search.text.trim();
    final repository = ref.read(transactionTagsProvider);
    if (name.isEmpty || repository == null || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final tag = await repository.create(name, null);
      if (!mounted || ref.read(transactionTagsProvider) != repository) return;
      setState(() {
        _selected.add(tag.id);
        _search.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(transactionTagsProvider);
    final query = _search.text.trim().toLowerCase();
    // Archived tags already selected remain visible and removable.
    final tags = (repository?.allTags ?? const <TransactionTag>[])
        .where((tag) => tag.archivedAt == null || _selected.contains(tag.id))
        .where((tag) => tag.name.toLowerCase().contains(query))
        .toList();
    final exactMatch =
        repository?.tags.any((tag) => tag.name.trim().toLowerCase() == query) ??
        false;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.title, style: BambooFonts.heading(18)),
                  ),
                  TextButton(
                    onPressed: _creating
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              TextField(
                controller: _search,
                maxLength: 60,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Search or create a tag',
                  hintText: 'e.g. Thailand trip or Office',
                  prefixIcon: Icon(Icons.search_rounded),
                  counterText: '',
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) {
                  if (!exactMatch) _create();
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_selected.length} selected',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ),
                  TextButton(
                    onPressed: _creating || _selected.isEmpty
                        ? null
                        : () => setState(_selected.clear),
                    child: const Text('Clear'),
                  ),
                ],
              ),
              if (_error != null)
                Text(_error!, style: BambooFonts.ui(12, color: BambooInk.clay)),
              Expanded(
                child: ListView(
                  children: [
                    if (repository == null)
                      const ListTile(
                        title: Text(
                          'Tags are still loading. Try again shortly.',
                        ),
                      ),
                    for (final tag in tags)
                      CheckboxListTile(
                        value: _selected.contains(tag.id),
                        controlAffinity: ListTileControlAffinity.trailing,
                        secondary: Icon(
                          Icons.label_rounded,
                          color: transactionTagColor(tag.color),
                        ),
                        title: Text(tag.name),
                        subtitle: Text(
                          [
                            if (tag.archivedAt != null) 'Archived',
                            '${repository!.usageCount(tag.id)} transactions',
                          ].join(' · '),
                        ),
                        onChanged: _creating
                            ? null
                            : (selected) => setState(() {
                                if (selected == true) {
                                  _selected.add(tag.id);
                                } else {
                                  _selected.remove(tag.id);
                                }
                              }),
                      ),
                    if (repository != null && query.isNotEmpty && !exactMatch)
                      ListTile(
                        leading: _creating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_rounded),
                        title: Text('Create “${_search.text.trim()}”'),
                        subtitle: const Text('Create a tag and select it'),
                        enabled: !_creating,
                        onTap: _create,
                      ),
                    if (repository != null && tags.isEmpty && query.isEmpty)
                      const ListTile(
                        title: Text('No tags yet'),
                        subtitle: Text(
                          'Type a name above to create your first tag.',
                        ),
                      ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: repository == null || _creating
                    ? null
                    : () => Navigator.of(context).pop({..._selected}),
                child: Text(
                  _selected.isEmpty
                      ? 'Apply without tags'
                      : 'Apply ${_selected.length} tags',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
