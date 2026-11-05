import 'package:flutter/material.dart';

/// The answer from [askReason]: the written reason, and the chosen option when
/// the dialog offers a list of reasons.
class ReasonAnswer {
  const ReasonAnswer(this.reason, {this.choice});
  final String reason;
  final String? choice;
}

/// A dialog that will not continue until the admin has written why. Every
/// control that changes what phones or the AI do goes through one of these, so
/// the reason lands in the audit log.
///
/// With [choices], the admin also picks one (for example a rejection reason);
/// [noteRequiredFor] lists the choices that need a written note.
Future<ReasonAnswer?> askReason(
  BuildContext context, {
  required String title,
  String? message,
  String label = 'Why are you changing this?',
  String confirmLabel = 'Continue',
  Map<String, String>? choices,
  Set<String> noteRequiredFor = const {},
}) => showDialog<ReasonAnswer>(
  context: context,
  builder: (_) => _ReasonDialog(
    title: title,
    message: message,
    label: label,
    confirmLabel: confirmLabel,
    choices: choices,
    noteRequiredFor: noteRequiredFor,
  ),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.message,
    required this.label,
    required this.confirmLabel,
    required this.choices,
    required this.noteRequiredFor,
  });
  final String title;
  final String? message;
  final String label;
  final String confirmLabel;
  final Map<String, String>? choices;
  final Set<String> noteRequiredFor;
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _text = TextEditingController();
  String? _choice;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _noteRequired =>
      widget.choices == null || widget.noteRequiredFor.contains(_choice);
  bool get _ready {
    if (widget.choices != null && _choice == null) return false;
    final length = _text.text.trim().length;
    return _noteRequired ? length >= 3 : true;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          if (widget.choices != null)
            DropdownButtonFormField<String>(
              key: const Key('reason-choice'),
              initialValue: _choice,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: [
                for (final entry in widget.choices!.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => _choice = value),
            ),
          if (widget.choices != null) const SizedBox(height: 8),
          TextField(
            key: const Key('reason-text'),
            controller: _text,
            minLines: 1,
            maxLines: 3,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: widget.choices == null
                  ? widget.label
                  : (_noteRequired ? 'Note (required)' : 'Note (optional)'),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reason-confirm'),
        onPressed: _ready
            ? () => Navigator.pop(
                context,
                ReasonAnswer(_text.text.trim(), choice: _choice),
              )
            : null,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
