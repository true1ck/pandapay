import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A "choose one" field that opens a bottom sheet instead of a menu floating
/// over the form. Looks like the other filled inputs; the sheet matches the
/// Category and "Paid with -> More" sheets (paper, drag handle, check on the
/// current choice). Use for short lists in forms.
class SheetSelectField<T> extends StatelessWidget {
  const SheetSelectField({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.optionLabel,
    this.sheetTitle,
    this.hint,
    this.helperText,
    this.enabled = true,
  });

  final String label;
  final List<T> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  /// Text for an option; defaults to `toString()`.
  final String Function(T)? optionLabel;
  final String? sheetTitle;
  final String? hint;
  final String? helperText;
  final bool enabled;

  String _text(T v) => optionLabel?.call(v) ?? v.toString();

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<_Pick<T>>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Text(
                  sheetTitle ?? label,
                  style: BambooFonts.heading(18, color: BambooInk.ink900),
                ),
              ),
              for (final option in options)
                ListTile(
                  title: Text(_text(option)),
                  trailing: option == value
                      ? const Icon(
                          Icons.check_circle,
                          color: BambooInk.slate,
                          semanticLabel: 'Selected',
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(_Pick(option)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onChanged?.call(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final current = value;
    final active = enabled && onChanged != null;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: active ? () => _open(context) : null,
        child: InputDecorator(
          isEmpty: current == null,
          decoration: InputDecoration(
            labelText: label,
            helperText: helperText,
            helperMaxLines: 2,
            hintText: hint,
            labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
            filled: true,
            fillColor: BambooInk.glassFillOnPaper,
            suffixIcon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: BambooInk.ink500,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
          ),
          child: current == null
              ? null
              : Text(
                  _text(current),
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ),
    );
  }
}

// Wraps the pick so choosing an option whose value is null-like still returns
// a non-null route result (a dismissed sheet returns plain null).
class _Pick<T> {
  const _Pick(this.value);
  final T value;
}
