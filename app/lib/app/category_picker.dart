import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme.dart';
import 'providers.dart';
import '../data/catalogue_repository.dart';

const addCategoryPickerValue = '__add_user_category__';

Future<String?> showAddCategoryDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add category'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Category name',
          hintText: 'e.g. Pet care',
        ),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
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
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  try {
    final category = await addCustomCategory(ref, trimmed);
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
              title: Text(category.name),
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
            title: const Text('Add category'),
            subtitle: const Text('Create a category just for you'),
            onTap: () async {
              final id = await showAddCategoryDialog(sheetContext, ref);
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
            child: Text(category.name, overflow: TextOverflow.ellipsis),
          ),
        const DropdownMenuItem(
          value: addCategoryPickerValue,
          child: Text('＋ Add category'),
        ),
      ],
      onChanged: (value) async {
        if (value != addCategoryPickerValue) {
          onSelected(value);
          return;
        }
        final id = await showAddCategoryDialog(context, ref);
        if (id != null) onSelected(id);
      },
    );
  }
}
