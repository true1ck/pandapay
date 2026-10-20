import 'package:flutter/material.dart';
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
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Text(
              title,
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
          ),
          for (final category in categories)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: BambooInk.slate.withValues(alpha: 0.08),
                child: Icon(
                  category.isCustom
                      ? Icons.label_outline_rounded
                      : Icons.category_outlined,
                  color: BambooInk.ink700,
                ),
              ),
              title: Text(_categoryLabel(category, categories)),
              trailing: selectedId == category.id
                  ? const Icon(Icons.check_circle, color: BambooInk.slate)
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(category.id),
            ),
          const Divider(height: 20),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: BambooInk.lime,
              child: Icon(Icons.add_rounded, color: BambooInk.slate),
            ),
            title: const Text('Add category or subcategory'),
            subtitle: const Text('Create a category just for you'),
            onTap: () async {
              final id = await showAddCategoryDialog(
                sheetContext,
                ref,
                categories,
              );
              if (id != null && sheetContext.mounted) {
                Navigator.of(sheetContext).pop(id);
              }
            },
          ),
        ],
      ),
    ),
  );
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
