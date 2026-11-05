import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import 'shared_components.dart';

/// One-field bottom sheet used to name a new friend or group. It replaces the
/// small pop-up dialogs: same Bamboo fields and one slate primary action, and
/// it follows the keyboard. Returns the trimmed name, or null if dismissed.
class SharedNameSheet extends StatefulWidget {
  final String title, label, hint, action;
  const SharedNameSheet({
    super.key,
    required this.title,
    required this.label,
    required this.hint,
    required this.action,
  });

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String label,
    required String hint,
    String action = 'Add',
  }) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: BambooInk.paper,
    builder: (_) =>
        SharedNameSheet(title: title, label: label, hint: hint, action: action),
  );

  @override
  State<SharedNameSheet> createState() => _SharedNameSheetState();
}

class _SharedNameSheetState extends State<SharedNameSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      16,
      12,
      16,
      MediaQuery.viewInsetsOf(context).bottom + 16,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.title, style: BambooFonts.heading(18))),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 120,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          style: BambooFonts.ui(15),
          decoration: InputDecoration(labelText: widget.label),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        Text(widget.hint, style: BambooFonts.ui(12, color: BambooInk.ink700)),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clayInk)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          style: sharedPrimaryButtonStyle(),
          onPressed: _submit,
          child: Text(
            widget.action,
            style: BambooFonts.ui(
              15,
              weight: FontWeight.w600,
              color: BambooInk.lime,
            ),
          ),
        ),
      ],
    ),
  );
}
