import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import '../../data/sms_v2_admin_api.dart';
import '../../widgets/confirm_dialog.dart';
import 'golden_runner.dart';

List<String> categoryEditorIssues(String source) {
  try {
    final rule = (jsonDecode(source) as Map).cast<String, dynamic>();
    final check = validateBundleJson({
      ...editorBundle({}),
      'rules': <Object?>[],
      'categoryRules': [rule],
    });
    if (!check.ok) {
      return check.errors.map((error) => error.toString()).toList();
    }
    if (rule['source'] != 'shared') {
      return ['Reviewed category rules use source "shared".'];
    }
    if (TaxonomyRegistry.v1.canonicalSlug(rule['category'] as String) == null) {
      return ['Choose a category in taxonomy v1.'];
    }
    return [];
  } catch (_) {
    return ['Enter a valid CategoryRule JSON object.'];
  }
}

/// Which shared bundle part an editor changes. Both go through the same draft,
/// four-cohort golden check and publish steps.
enum SharedPart { category, alias }

/// What is wrong with a shop-name draft before it is sent, or an empty list.
List<String> aliasEditorIssues(String source) {
  try {
    final rule = (jsonDecode(source) as Map).cast<String, dynamic>();
    final alias = rule['alias'], key = rule['merchantKey'];
    if (rule.keys.toSet().difference({'alias', 'merchantKey', 'kind'}).isNotEmpty ||
        alias is! String ||
        key is! String ||
        rule['kind'] != 'learned') {
      return ['A shop name has an alias, a merchantKey and kind "learned".'];
    }
    if (alias.trim().toUpperCase() == key.trim().toUpperCase()) {
      return ['The alias must differ from the shop name it points to.'];
    }
    if (RegExp(r'\d{4,}').hasMatch(alias) || RegExp(r'\d{4,}').hasMatch(key)) {
      return ['A name with a run of four or more digits is never shared.'];
    }
    return [];
  } catch (_) {
    return ['Enter a valid shop name JSON object.'];
  }
}

class SmsCategoryEditor extends StatefulWidget {
  const SmsCategoryEditor({
    super.key,
    required this.api,
    required this.id,
    required this.initialRule,
    this.revision,
    this.runner,
    this.part = SharedPart.category,
  });
  final SharedPart part;
  final SmsV2AdminApi api;
  final String id;
  final Map<String, dynamic> initialRule;
  final int? revision;
  final Future<BrowserGoldenRunner> Function()? runner;
  @override
  State<SmsCategoryEditor> createState() => _SmsCategoryEditorState();
}

class _SmsCategoryEditorState extends State<SmsCategoryEditor> {
  late final _json = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(widget.initialRule),
  );
  final _reason = TextEditingController();
  late int? _revision = widget.revision;
  Map<String, BrowserGoldenResult> _reports = {};
  bool _busy = false;
  String? _error, _notice;
  @override
  void dispose() {
    _json.dispose();
    _reason.dispose();
    super.dispose();
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
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _act(() async {
    final body = (jsonDecode(_json.text) as Map).cast<String, dynamic>();
    final saved = _alias
        ? await widget.api.saveAlias(widget.id, body)
        : await widget.api.saveCategory(widget.id, body);
    if (mounted) {
      setState(() {
        _revision = saved['revision'] as int;
        _reports = {};
        _notice = '$_noun draft revision $_revision saved.';
      });
    }
  });
  Future<void> _run() => _act(() async {
    setState(() => _reports = {});
    final candidates =
        (await (_alias
                ? widget.api.aliasCandidates(widget.id, _revision!)
                : widget.api.categoryCandidates(widget.id, _revision!)))['candidates']
            as List;
    if (candidates.length != 4 ||
        !candidates.map((row) => row['cohort']).toSet().containsAll({
          'testers',
          'pct5',
          'pct25',
          'all',
        })) {
      throw StateError('All four cohort candidates are required.');
    }
    final runner = await (widget.runner?.call() ?? BrowserGoldenRunner.load());
    final reports = <String, BrowserGoldenResult>{};
    for (final candidate in candidates) {
      final result = await runner.run(
        (candidate['bundle'] as Map).cast<String, dynamic>(),
      );
      if (result.report['bundleSha256'] != candidate['contentSha256']) {
        throw StateError('Candidate changed. Run all golden checks again.');
      }
      reports[candidate['cohort'] as String] = result;
    }
    if (mounted) {
      setState(() {
        _reports = reports;
        _notice = reports.values.every((report) => report.passed)
            ? 'All four cohort golden checks passed.'
            : 'A cohort golden check failed.';
      });
    }
  });
  Future<void> _publish() async {
    if (!await confirmAdminAction(
      context,
      title: 'Publish this ${_noun.toLowerCase()} to every cohort?',
      message:
          'This updates shared ${_alias ? 'shop names' : 'category rules'} in testers, pct5, pct25 and all together. Reason: ${_reason.text.trim()}',
    )) {
      return;
    }
    await _act(() async {
      final reports = {
        for (final entry in _reports.entries) entry.key: entry.value.report,
      };
      await (_alias
          ? widget.api.publishAlias(widget.id, _revision!, _reason.text.trim(), reports)
          : widget.api.publishCategory(widget.id, _revision!, _reason.text.trim(), reports));
      if (mounted) {
        setState(() {
          _revision = null;
          _reports = {};
          _notice = '$_noun published to every cohort.';
        });
      }
    });
  }

  bool get _alias => widget.part == SharedPart.alias;
  String get _noun => _alias ? 'Shop name' : 'Category rule';

  @override
  Widget build(BuildContext context) {
    final issues = _alias
            ? aliasEditorIssues(_json.text)
            : categoryEditorIssues(_json.text),
        passed =
            _reports.length == 4 &&
            _reports.values.every((report) => report.passed);
    return Scaffold(
      appBar: AppBar(title: Text(_alias ? 'Review shop name' : 'Review category rule')),
      body: ListView(
        key: const Key('category-editor-scroll'),
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _alias
                ? 'Shop names are shared by every cohort. Saving a draft changes no live bundle. Publication requires passing golden reports for all four prospective bundles.'
                : 'Category rules are shared by every cohort. Saving a draft changes no live bundle. Publication requires passing golden reports for all four prospective bundles.',
          ),
          Text('Draft ${widget.id} · revision ${_revision ?? 'unsaved'}'),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_notice != null) Text(_notice!),
          const SizedBox(height: 16),
          TextField(
            key: const Key('category-json'),
            controller: _json,
            minLines: 10,
            maxLines: 18,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              labelText: _alias ? 'Shop name JSON' : 'CategoryRule JSON',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _revision = null;
              _reports = {};
            }),
          ),
          if (issues.isNotEmpty) Text(issues.join('\n')),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                key: const Key('save-category'),
                onPressed: _busy || issues.isNotEmpty ? null : _save,
                child: Text(_alias ? 'Save shop name draft' : 'Save category draft'),
              ),
              OutlinedButton(
                key: const Key('run-category-golden'),
                onPressed: _busy || _revision == null ? null : _run,
                child: const Text('Run all cohort golden checks'),
              ),
            ],
          ),
          for (final entry in _reports.entries)
            ExpansionTile(
              title: Text(
                '${entry.key}: ${entry.value.passed ? 'passed' : 'failed'}',
              ),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(entry.value.report),
                ),
              ],
            ),
          TextField(
            key: const Key('category-reason'),
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason for publication',
            ),
            onChanged: (_) => setState(() {}),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('publish-category'),
              onPressed: _busy || !passed || _reason.text.trim().isEmpty
                  ? null
                  : _publish,
              child: Text(_alias ? 'Publish shop name to every cohort' : 'Publish category to every cohort'),
            ),
          ),
        ],
      ),
    );
  }
}
