import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// UA-5.3/AD-4.3 follow-up (Chunk 35): admin CRUD for `parser_patterns`,
/// the table `sms_parser.js` (Chunk 31) reads at parse time to turn a raw
/// bank SMS into a structured transaction. The API routes were built and
/// curl-verified in Chunk 31 but had no console screen — without one, an
/// admin has no way to add a real pattern, so the SMS-import feature had
/// no data to match against even once wired into app/ navigation.
class ParserPatternsScreen extends ConsumerWidget {
  const ParserPatternsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patterns = ref.watch(parserPatternsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: _NewPatternForm(),
        ),
        const Divider(height: 1),
        Expanded(
          child: patterns.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text('Failed to load parser patterns: $err')),
            data: (rows) => rows.isEmpty
                ? const Center(child: Text('No parser patterns yet — add one above.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _PatternTile(rows[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _PatternTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> pattern;
  const _PatternTile(this.pattern);

  @override
  ConsumerState<_PatternTile> createState() => _PatternTileState();
}

class _PatternTileState extends ConsumerState<_PatternTile> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(parserPatternsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pattern;
    final isActive = p['is_active'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text('${p['channel']} · ${p['sender_pattern'] ?? '(any sender)'} · v${p['version']}'),
        subtitle: Text(
          '${p['success_count']} matched · ${p['failure_count']} failed'
          '${isActive ? '' : ' · INACTIVE'}',
          style: TextStyle(color: isActive ? null : Colors.orange),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('regex: ${p['regex']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 4),
                Text('fieldMap: ${jsonEncode(p['field_map'])}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                if (p['sample_text'] != null) ...[
                  const SizedBox(height: 4),
                  Text('sample: ${p['sample_text']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() => ref
                              .read(adminApiProvider)!
                              .updateParserPattern(p['id'] as String, isActive: !isActive)),
                      child: Text(_busy ? '...' : (isActive ? 'Deactivate' : 'Activate')),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() => ref.read(adminApiProvider)!.deleteParserPattern(p['id'] as String)),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NewPatternForm extends ConsumerStatefulWidget {
  const _NewPatternForm();
  @override
  ConsumerState<_NewPatternForm> createState() => _NewPatternFormState();
}

class _NewPatternFormState extends ConsumerState<_NewPatternForm> {
  String _channel = 'sms';
  final _senderController = TextEditingController();
  final _regexController = TextEditingController();
  final _fieldMapController = TextEditingController(text: '{"amount": 1, "merchant": 2}');
  final _sampleController = TextEditingController();
  bool _adding = false;
  String? _error;

  static const _channels = ['sms', 'sms_bulk', 'email', 'statement', 'imported'];

  Future<void> _add() async {
    Map<String, dynamic> fieldMap;
    try {
      fieldMap = jsonDecode(_fieldMapController.text) as Map<String, dynamic>;
    } catch (_) {
      setState(() => _error = 'fieldMap must be valid JSON, e.g. {"amount": 1, "merchant": 2}');
      return;
    }
    if (_regexController.text.trim().isEmpty) {
      setState(() => _error = 'regex is required');
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await ref.read(adminApiProvider)!.createParserPattern(
            channel: _channel,
            regex: _regexController.text.trim(),
            fieldMap: fieldMap,
            senderPattern: _senderController.text.trim().isEmpty ? null : _senderController.text.trim(),
            sampleText: _sampleController.text.trim().isEmpty ? null : _sampleController.text.trim(),
            reason: 'Console: new parser pattern',
          );
      _senderController.clear();
      _regexController.clear();
      _sampleController.clear();
      ref.invalidate(parserPatternsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Add a parser pattern', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            DropdownButton<String>(
              value: _channel,
              items: [for (final c in _channels) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) => setState(() => _channel = v ?? _channel),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _senderController,
                decoration: const InputDecoration(labelText: 'Sender pattern (optional)', isDense: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _regexController,
          decoration: const InputDecoration(labelText: 'Regex', isDense: true),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _fieldMapController,
          decoration: const InputDecoration(labelText: 'Field map (JSON: field -> capture group index)', isDense: true),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _sampleController,
          decoration: const InputDecoration(labelText: 'Sample SMS text (optional)', isDense: true),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: _adding ? null : _add,
              child: Text(_adding ? '...' : 'Add pattern'),
            ),
            if (_error != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
