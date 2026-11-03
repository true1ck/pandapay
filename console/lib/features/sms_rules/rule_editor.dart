import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../../data/sms_v2_admin_api.dart';
import '../../widgets/confirm_dialog.dart';
import 'golden_runner.dart';
import 'metric_chart.dart';

class SmsRuleEditor extends StatefulWidget {
  const SmsRuleEditor({
    super.key,
    required this.api,
    required this.ruleId,
    this.initialDraft,
    this.runner,
  });
  final SmsV2AdminApi api;
  final String ruleId;
  final Map<String, dynamic>? initialDraft;
  final Future<BrowserGoldenRunner> Function()? runner;
  @override
  State<SmsRuleEditor> createState() => _SmsRuleEditorState();
}

class _SmsRuleEditorState extends State<SmsRuleEditor> {
  final _json = TextEditingController();
  final _message = TextEditingController();
  final _sender = TextEditingController();
  final _reason = TextEditingController();
  Map<String, dynamic>? _detail;
  Map<String, dynamic>? _saved;
  BrowserGoldenResult? _report;
  String _cohort = 'testers';
  String? _error, _notice, _facts;
  bool _busy = false;
  int? _selectedVersion;
  List<dynamic> _senders = const [];
  BrowserGoldenRunner? _runner;
  List<String> _coverage = [];
  List<String> get _issues => validateEditor(_json.text, senders: _senders);
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_json, _message, _sender, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final runner =
          await (widget.runner?.call() ?? BrowserGoldenRunner.load());
      _runner = runner;
      _senders = runner.contextBundle['senders'] as List? ?? const [];
      final detail = await widget.api.detail(widget.ruleId);
      if (!mounted) return;
      final versions = (detail['versions'] as List).cast<Map>();
      final latest = versions.last;
      final original = (latest['body'] as Map).cast<String, dynamic>();
      final guidance = widget.initialDraft;
      final body = guidance == null || guidance['match'] is Map
          ? guidance ?? original
          : {
              ...original,
              'status': 'draft',
              'match': {
                ...original['match'] as Map,
                if (guidance['pattern'] is String)
                  'pattern': guidance['pattern'],
              },
            };
      setState(() {
        _detail = detail;
        _selectedVersion = latest['version'] as int;
        _setEditor(body);
      });
    } catch (_) {
      if (!mounted) return;
      if (widget.initialDraft != null) {
        setState(() {
          _detail = {'versions': <Object?>[]};
          _setEditor(widget.initialDraft!);
        });
      } else {
        setState(() {
          _error = 'The rule could not be loaded. Retry.';
        });
      }
    }
  }

  void _setEditor(Map<String, dynamic> body) {
    _json.text = const JsonEncoder.withIndent('  ').convert(body);
    final senders = body['senders'] as List?;
    _sender.text = senders?.firstOrNull?.toString() ?? '';
    _saved = null;
    _report = null;
    _coverage = [];
    try {
      final bundle = RuleBundle.fromJson({
        ...?_runner?.contextBundle,
        ...editorBundle({...body, 'status': 'active'}),
        'senders': _senders,
      });
      for (final c in _runner?.cases.cases ?? []) {
        if (c.messages.any(
          (message) => RuleEngine()
              .interpret(
                SmsMessage(
                  sender: message.sender,
                  body: message.body,
                  observedAt: message.observedAt,
                  sourceKey: 'coverage:${c.id}',
                ),
                bundle,
                appVersion: 'console',
              )
              .facts
              .any((fact) => fact.envelope.provenance.ruleId == widget.ruleId),
        )) {
          _coverage.add(c.id);
        }
      }
    } catch (_) {
      /* Invalid drafts display their validation errors below. */
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _save() => _act(() async {
    final body = (jsonDecode(_json.text) as Map).cast<String, dynamic>();
    if (body['id'] != widget.ruleId) {
      throw StateError('The rule ID must remain ${widget.ruleId}.');
    }
    final saved = await widget.api.save(body);
    if (mounted) {
      setState(() {
        _saved = saved;
        _report = null;
        _notice = 'Draft version ${saved['version']} saved.';
      });
    }
  });
  Future<void> _golden() => _act(() async {
    final saved = _saved!;
    final candidate = await widget.api.candidate(
      widget.ruleId,
      saved['version'] as int,
      _cohort,
    );
    await Future<void>.delayed(Duration.zero);
    final runner = await (widget.runner?.call() ?? BrowserGoldenRunner.load());
    final result = await runner.run(
      (candidate['bundle'] as Map).cast<String, dynamic>(),
    );
    if (result.report['bundleSha256'] != candidate['contentSha256']) {
      throw StateError(
        'Candidate content changed. Save and run the golden set again.',
      );
    }
    if (mounted) {
      setState(() {
        _report = result;
        _notice = result.passed
            ? 'The golden set passed.'
            : 'The golden set found failures.';
      });
    }
  });
  Future<void> _publish() => _act(() async {
    if (_report?.passed != true || _reason.text.trim().isEmpty) return;
    final report = {..._report!.report, 'reason': _reason.text.trim()};
    await widget.api.publish(
      widget.ruleId,
      _saved!['version'] as int,
      _cohort,
      report,
    );
    if (mounted) {
      setState(() {
        _report = null;
        _notice = 'Published to $_cohort.';
      });
    }
  });
  void _testMessage() {
    try {
      final body = (jsonDecode(_json.text) as Map).cast<String, dynamic>();
      final bundle = RuleBundle.fromJson(
        editorBundle({...body, 'status': 'active'}),
      );
      final result = RuleEngine().interpret(
        SmsMessage(
          sender: _sender.text,
          body: _message.text,
          observedAt: DateTime.now().toUtc(),
          sourceKey: 'console:local',
        ),
        bundle,
        appVersion: 'console',
      );
      setState(() {
        _facts = const JsonEncoder.withIndent('  ').convert({
          'outcome': result.outcome.name,
          'facts': [for (final fact in result.facts) fact.toJson()],
        });
      });
    } catch (_) {
      setState(() {
        _facts = 'The editor contains an invalid rule.';
      });
    }
  }

  Future<void> _pause() async {
    if (!await confirmAdminAction(
      context,
      title: 'Pause this rule?',
      message: 'The affected cohort falls back to the prior live version.',
    )) {
      return;
    }
    await _act(() async {
      await widget.api.pause(
        widget.ruleId,
        _selectedVersion!,
        _reason.text.trim(),
      );
      if (mounted) {
        setState(() {
          _notice = 'Rule paused.';
        });
      }
    });
  }

  Future<void> _rollback() async {
    if (!await confirmAdminAction(
      context,
      title: 'Roll back to version $_selectedVersion?',
      message:
          'This creates a new version from the selected version and publishes it to all cohorts.',
    )) {
      return;
    }
    await _act(() async {
      await widget.api.rollback(
        widget.ruleId,
        _selectedVersion!,
        _reason.text.trim(),
      );
      if (mounted) {
        setState(() {
          _notice = 'Rollback published.';
        });
      }
    });
  }

  String _diff(Map? before, Map after) {
    final keys = {...?before?.keys, ...after.keys};
    return keys
        .where((key) => jsonEncode(before?[key]) != jsonEncode(after[key]))
        .map(
          (key) =>
              '$key\n  ${jsonEncode(before?[key])}\n→ ${jsonEncode(after[key])}',
        )
        .join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final versions = (_detail?['versions'] as List? ?? const []).cast<Map>();
    if (_detail == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.ruleId)),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : TextButton(onPressed: _load, child: Text(_error!)),
        ),
      );
    }
    final selected = versions
        .where((v) => v['version'] == _selectedVersion)
        .firstOrNull;
    final previous = versions
        .where((v) => (v['version'] as int) < (_selectedVersion ?? 0))
        .lastOrNull;
    final issues = _issues;
    return Scaffold(
      appBar: AppBar(title: Text(widget.ruleId)),
      body: ListView(
        key: const Key('rule-editor-scroll'),
        padding: const EdgeInsets.all(24),
        children: [
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_notice != null) Text(_notice!),
          if (_busy) const LinearProgressIndicator(),
          if (versions.isNotEmpty) ...[
            DropdownButton<int>(
              value: _selectedVersion,
              items: [
                for (final version in versions)
                  DropdownMenuItem(
                    value: version['version'] as int,
                    child: Text(
                      'Version ${version['version']} · ${version['status']}',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _selectedVersion = value;
                      _setEditor(
                        (versions.firstWhere(
                                  (v) => v['version'] == value,
                                )['body']
                                as Map)
                            .cast<String, dynamic>(),
                      );
                    }),
            ),
            Text(
              'Changed by ${selected?['createdBy'] ?? 'Unknown'} · ${selected?['createdAt'] ?? ''}',
            ),
            Text('7-day metrics  ${jsonEncode(selected?['metrics7d'] ?? {})}'),
            Text(
              '30-day metrics  ${jsonEncode(selected?['metrics30d'] ?? {})}',
            ),
            for (final days in [7, 30])
              ExpansionTile(
                title: Text('$days-day activity'),
                children: [
                  RuleMetricChart(
                    rows: (selected?['dailyMetrics'] as List? ?? const [])
                        .cast<Map>(),
                    days: days,
                  ),
                ],
              ),
            Text('Cohorts  ${jsonEncode(selected?['cohorts'] ?? [])}'),
            ExpansionTile(
              title: const Text('Changes from previous version'),
              children: [
                SelectableText(
                  _diff(
                    (previous?['body'] as Map?),
                    (selected?['body'] as Map?) ?? {},
                  ),
                ),
              ],
            ),
          ],
          ExpansionTile(
            title: Text(
              'Golden cases covering this rule (${_coverage.length})',
            ),
            children: [for (final id in _coverage) ListTile(title: Text(id))],
          ),
          ExpansionTile(
            title: const Text('Examples'),
            children: [
              for (final example
                  in selected?['body']?['examples'] as List? ?? const [])
                ListTile(
                  title: Text('${example['sender']}'),
                  subtitle: Text(
                    '${example['body']} → ${example['expectFactTypes']}',
                  ),
                ),
              const Text(
                'Edit the examples array in the Rule JSON to add or remove examples.',
              ),
            ],
          ),
          if (widget.initialDraft != null)
            ExpansionTile(
              title: const Text('Correction guidance'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(widget.initialDraft),
                ),
              ],
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('rule-json'),
            controller: _json,
            minLines: 10,
            maxLines: 22,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Rule JSON',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _saved = null;
              _report = null;
            }),
          ),
          if (issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                issues.take(6).join('\n'),
                key: const Key('editor-errors'),
              ),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('save-draft'),
                onPressed: _busy || issues.isNotEmpty ? null : _save,
                child: const Text('Save draft'),
              ),
              DropdownButton<String>(
                value: _cohort,
                items: [
                  for (final cohort in ['testers', 'pct5', 'pct25', 'all'])
                    DropdownMenuItem(value: cohort, child: Text(cohort)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _cohort = value!;
                        _report = null;
                      }),
              ),
              OutlinedButton(
                key: const Key('run-golden'),
                onPressed: _busy || _saved == null ? null : _golden,
                child: const Text('Run golden set'),
              ),
            ],
          ),
          if (_report != null)
            ExpansionTile(
              initiallyExpanded: true,
              title: Text(
                _report!.passed ? 'Golden set passed' : 'Golden set failed',
              ),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(_report!.report),
                ),
              ],
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('publish-reason'),
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason for publishing or changing rollout',
            ),
            onChanged: (_) => setState(() {}),
          ),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                key: const Key('publish-rule'),
                onPressed:
                    _busy ||
                        _report?.passed != true ||
                        _reason.text.trim().isEmpty
                    ? null
                    : _publish,
                child: Text('Publish to $_cohort'),
              ),
              TextButton(
                onPressed:
                    _busy ||
                        _selectedVersion == null ||
                        _reason.text.trim().isEmpty
                    ? null
                    : _pause,
                child: const Text('Pause'),
              ),
              TextButton(
                onPressed:
                    _busy ||
                        _selectedVersion == null ||
                        _reason.text.trim().isEmpty
                    ? null
                    : _rollback,
                child: const Text('Roll back'),
              ),
            ],
          ),
          const Divider(height: 40),
          const Text(
            'Synthetic or redacted text only. The message tester runs in this browser.',
          ),
          TextField(
            key: const Key('test-sender'),
            controller: _sender,
            decoration: const InputDecoration(labelText: 'Sender'),
          ),
          TextField(
            key: const Key('test-message'),
            controller: _message,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Test message'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: issues.isEmpty ? _testMessage : null,
              child: const Text('Test locally'),
            ),
          ),
          if (_facts != null) SelectableText(_facts!),
        ],
      ),
    );
  }
}
