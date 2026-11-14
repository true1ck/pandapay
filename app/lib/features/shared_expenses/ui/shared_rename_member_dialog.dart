import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/required_field.dart';
import '../data/shared_directory.dart';

/// Asks for the name other people in the split will see for one person.
/// Completes with the cleaned name, or null when cancelled.
Future<String?> showSharedRenameMemberDialog(
  BuildContext context, {
  required String initialName,
  required String title,
  SharedRenameSave? onSave,
}) => showDialog<String>(
  context: context,
  builder: (_) => SharedRenameMemberDialog(
    title: title,
    initial: initialName,
    onSave: onSave,
  ),
);

/// Tries to save [name]; returns a message to show under the field, or null
/// when it worked (the dialog then closes).
typedef SharedRenameSave = Future<String?> Function(String name);

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
  final SharedRenameSave? onSave;
  const SharedRenameMemberDialog({
    super.key,
    required this.title,
    required this.initial,
    this.onSave,
  });
  @override
  State<SharedRenameMemberDialog> createState() => _RenameState();
}

class _RenameState extends State<SharedRenameMemberDialog> {
  late final _field = TextEditingController(text: widget.initial);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  bool _closed = false;

  /// Pops once. The dialog stays mounted through its exit animation, and a
  /// second pop would close the sheet underneath it.
  void _close([String? name]) {
    if (_closed) return;
    _closed = true;
    Navigator.pop(context, name);
  }

  Future<void> _save() async {
    if (_saving || _closed) return;
    final error = sharedMemberNameError(_field.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final name = sharedCleanMemberName(_field.text)!;
    final save = widget.onSave;
    if (save == null) {
      _close(name);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    String? problem;
    try {
      problem = await save(name);
    } catch (_) {
      problem = 'Could not save the name yet. Try again.';
    }
    if (!mounted) return;
    if (problem == null) {
      _close(name);
    } else {
      setState(() {
        _saving = false;
        _error = problem;
      });
    }
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
          decoration: InputDecoration(
            label: requiredLabel('Name'),
            errorText: _error,
            errorMaxLines: 3,
          ),
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
        onPressed: _saving ? null : () => _close(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving…' : 'Save'),
      ),
    ],
  );
}
