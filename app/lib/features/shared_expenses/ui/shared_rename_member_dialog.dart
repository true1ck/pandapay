import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';

/// Asks for the name other people in the split will see for one person.
/// Completes with the cleaned name, or null when cancelled.
Future<String?> showSharedRenameMemberDialog(
  BuildContext context, {
  required String initialName,
  required String title,
}) => showDialog<String>(
  context: context,
  builder: (_) => SharedRenameMemberDialog(title: title, initial: initialName),
);

/// Validation shared by the dialog and tests: null means the name is fine.
String? sharedMemberNameError(String raw) {
  final clean = sharedCleanMemberName(raw);
  if (clean == null) return 'Enter a name.';
  if (clean.length > sharedMemberNameMax) {
    return 'Use $sharedMemberNameMax characters or fewer.';
  }
  return null;
}

class SharedRenameMemberDialog extends StatefulWidget {
  final String title, initial;
  const SharedRenameMemberDialog({
    super.key,
    required this.title,
    required this.initial,
  });
  @override
  State<SharedRenameMemberDialog> createState() => _RenameState();
}

class _RenameState extends State<SharedRenameMemberDialog> {
  late final _field = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _save() {
    final error = sharedMemberNameError(_field.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, sharedCleanMemberName(_field.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('rename-member-field'),
          controller: _field,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          style: BambooFonts.ui(15),
          decoration: InputDecoration(labelText: 'Name', errorText: _error),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Text(
          'Everyone in this split sees this name.',
          style: BambooFonts.ui(12, color: BambooInk.ink700),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
