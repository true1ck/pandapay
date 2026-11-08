import 'package:flutter/material.dart';
import '../app/design/bamboo_components.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme.dart';
import 'providers.dart';
import '../data/catalogue_repository.dart';

const addCategoryPickerValue = '__add_user_category__';

Future<String?> showAddCategoryDialog(
  BuildContext context,
  WidgetRef ref,
  List<SpendCategory> categories, {
  String? initialParentId,
}) async {
  final controller = TextEditingController();
  final termsController = TextEditingController();
  String? parentId = initialParentId;
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(initialParentId == null ? 'Add category' : 'Add subcategory'),
      content: StatefulBuilder(
        builder: (context, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Category name',
                hintText: 'e.g. Office or Pet care',
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: parentId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Parent category'),
              items: [
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('Top-level category'),
                ),
                for (final category in categories.where(
                  (category) => !category.isSubcategory,
                ))
                  DropdownMenuItem<String>(
                    value: category.id,
                    child: Text(_categoryLabel(category, categories)),
                  ),
              ],
              onChanged: (value) => setDialogState(
                () => parentId = value == null || value.isEmpty ? null : value,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: termsController,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Import keywords (optional)',
                hintText: 'office, work, coworking',
                helperText: 'Used to recognise this category in imports',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: BambooButtons.primary,
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  final terms = termsController.text
      .split(',')
      .map((term) => term.trim())
      .where((term) => term.length >= 2)
      .toSet()
      .toList();
  termsController.dispose();
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  try {
    final category = await addCustomCategory(
      ref,
      trimmed,
      parentId: parentId,
      matchTerms: terms,
    );
    return category?.id;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add category: $error')),
      );
    }
    return null;
  }
}

String _categoryLabel(SpendCategory category, List<SpendCategory> categories) {
  if (!category.isSubcategory) return category.name;
  final parent = categories
      .where(
        (item) =>
            item.id == category.parentCategoryId ||
            item.id == category.parentUserCategoryId,
      )
      .firstOrNull;
  return parent == null ? category.name : '${parent.name} · ${category.name}';
}

/// A tall sheet with a fixed search box above a scrolling, grouped list, and
/// "Add category" pinned below it so it never needs a scroll to reach. The list
/// uses the sheet's own scroll controller, so dragging the list and dragging
/// the sheet no longer fight each other.
Future<String?> showCategoryBottomSheet(
  BuildContext context,
  WidgetRef ref,
  List<SpendCategory> categories, {
  String? selectedId,
  String title = 'Choose a category',
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: BambooInk.paper,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => _CategorySheet(
        categories: categories,
        selectedId: selectedId,
        title: title,
        scrollController: scrollController,
        onPick: (id) => Navigator.of(sheetContext).pop(id),
        onAdd: () async {
          final id = await showAddCategoryDialog(sheetContext, ref, categories);
          if (id != null && sheetContext.mounted) {
            Navigator.of(sheetContext).pop(id);
          }
        },
      ),
    ),
  );
}

class _CategorySheet extends StatefulWidget {
  const _CategorySheet({
    required this.categories,
    required this.selectedId,
    required this.title,
    required this.scrollController,
    required this.onPick,
    required this.onAdd,
  });
  final List<SpendCategory> categories;
  final String? selectedId;
  final String title;
  final ScrollController scrollController;
  final ValueChanged<String> onPick;
  final VoidCallback onAdd;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

/// One line of the list: a heading, or a category (indented under its parent).
class _Line {
  const _Line.heading(this.text) : category = null, indented = false;
  const _Line.category(this.category, {this.indented = false}) : text = null;
  final String? text;
  final SpendCategory? category;
  final bool indented;
}

class _CategorySheetState extends State<_CategorySheet> {
  String _query = '';

  String _parentId(SpendCategory c) =>
      c.parentCategoryId ?? c.parentUserCategoryId ?? '';

  List<_Line> _lines() {
    final all = widget.categories;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      // Searching is a flat list; a subcategory shows its parent so it is clear.
      return [
        for (final c in all)
          if (_categoryLabel(c, all).toLowerCase().contains(q))
            _Line.category(c),
      ];
    }
    final ids = {for (final c in all) c.id};
    final childrenOf = <String, List<SpendCategory>>{};
    final tops = <SpendCategory>[];
    for (final c in all) {
      if (c.isSubcategory && ids.contains(_parentId(c))) {
        childrenOf.putIfAbsent(_parentId(c), () => []).add(c);
      } else {
        tops.add(c);
      }
    }
    final out = <_Line>[];
    void section(String? heading, Iterable<SpendCategory> group) {
      if (group.isEmpty) return;
      if (heading != null) out.add(_Line.heading(heading));
      for (final top in group) {
        out.add(_Line.category(top));
        for (final child in childrenOf[top.id] ?? const <SpendCategory>[]) {
          out.add(_Line.category(child, indented: true));
        }
      }
    }

    section(null, tops.where((c) => !c.isCustom));
    section('Your categories', tops.where((c) => c.isCustom));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.title,
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: const Key('category-search'),
            onChanged: (value) => setState(() => _query = value),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search categories',
              prefixIcon: Icon(Icons.search_rounded),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: widget.scrollController,
            thumbVisibility: true,
            child: lines.isEmpty
                ? ListView(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        'No category matches “${_query.trim()}”. You can add it below.',
                        style: BambooFonts.ui(14, color: BambooInk.ink700),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      final line = lines[index];
                      final category = line.category;
                      if (category == null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
                          child: Text(
                            line.text!,
                            style: BambooFonts.ui(
                              12,
                              color: BambooInk.ink500,
                              weight: FontWeight.w700,
                            ),
                          ),
                        );
                      }
                      final selected = widget.selectedId == category.id;
                      return ListTile(
                        key: Key('category-${category.id}'),
                        contentPadding: EdgeInsets.only(
                          left: line.indented ? 40 : 8,
                          right: 8,
                        ),
                        dense: line.indented,
                        leading: line.indented
                            ? null
                            : CircleAvatar(
                                backgroundColor: BambooInk.slate.withValues(
                                  alpha: 0.08,
                                ),
                                child: Icon(
                                  category.isCustom
                                      ? Icons.label_outline_rounded
                                      : Icons.category_outlined,
                                  color: BambooInk.ink700,
                                ),
                              ),
                        title: Text(
                          _query.trim().isEmpty
                              ? category.name
                              : _categoryLabel(category, widget.categories),
                        ),
                        trailing: selected
                            ? const Icon(
                                Icons.check_circle,
                                color: BambooInk.slate,
                              )
                            : null,
                        onTap: () => widget.onPick(category.id),
                      );
                    },
                  ),
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const CircleAvatar(
              backgroundColor: BambooInk.lime,
              child: Icon(Icons.add_rounded, color: BambooInk.slate),
            ),
            title: const Text('Add category or subcategory'),
            subtitle: const Text('Create a category just for you'),
            onTap: widget.onAdd,
          ),
        ),
      ],
    );
  }
}

class CategoryPickerField extends ConsumerWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final String label;

  const CategoryPickerField({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.label = 'Category',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final validSelectedId = categories.any((item) => item.id == selectedId)
        ? selectedId
        : null;
    return DropdownButtonFormField<String>(
      initialValue: validSelectedId,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final category in categories)
          DropdownMenuItem(
            value: category.id,
            child: Text(
              _categoryLabel(category, categories),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const DropdownMenuItem(
          value: addCategoryPickerValue,
          child: Text('＋ Add category or subcategory'),
        ),
      ],
      onChanged: (value) async {
        if (value != addCategoryPickerValue) {
          onSelected(value);
          return;
        }
        final id = await showAddCategoryDialog(context, ref, categories);
        if (id != null) onSelected(id);
      },
    );
  }
}
