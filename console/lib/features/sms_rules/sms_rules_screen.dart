import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/sms_v2_admin_api.dart';
import 'providers.dart';
import 'rule_editor.dart';
import 'category_editor.dart';
import 'golden_runner.dart';
import 'settings_tab.dart';
import 'learning_tab.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';

class SmsRulesScreen extends ConsumerWidget {
  const SmsRulesScreen({super.key, this.runner, this.onDownload});
  final Future<BrowserGoldenRunner> Function()? runner;
  final void Function(String, String)? onDownload;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(smsV2AdminApiProvider);
    if (api == null) {
      return const Center(child: Text('Sign in to review SMS rules.'));
    }
    void open(String id, {Map<String, dynamic>? draft}) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SmsRuleEditor(
            api: api,
            ruleId: id,
            initialDraft: draft,
            runner: runner,
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SMS pipeline rules'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Learning'),
              Tab(text: 'Rules'),
              Tab(text: 'Templates'),
              Tab(text: 'Categories'),
              Tab(text: 'Corrections'),
              Tab(text: 'Metrics'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            Builder(
              builder: (tabs) => SmsLearningTab(
                api: api,
                onCreateCategoryRule: (key, category) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SmsCategoryEditor(
                      api: api,
                      id: learningDraftId(key),
                      initialRule: learnedCategoryRule(key, category),
                      runner: runner,
                    ),
                  ),
                ),
                onCreateName: (alias, name) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SmsCategoryEditor(
                      api: api,
                      part: SharedPart.alias,
                      id: learningDraftId(alias),
                      initialRule: learnedAlias(alias, name),
                      runner: runner,
                    ),
                  ),
                ),
                // The Corrections tab is the sixth: Learning, Rules, Templates,
                // Categories, then Corrections.
                onOpenCorrections: () => DefaultTabController.of(tabs).animateTo(4),
              ),
            ),
            ref
                .watch(smsV2RulesProvider)
                .when(
                  data: (rows) =>
                      SmsRulesTable(rows: rows, onOpen: (id) => open(id)),
                  error: (_, _) => Center(
                    child: TextButton(
                      onPressed: () => ref.invalidate(smsV2RulesProvider),
                      child: const Text('Unable to load rules. Retry'),
                    ),
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                ),
            _RemotePanel(
              load: api.templates,
              builder: (rows) => ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return ExpansionTile(
                    title: Text('${row['sender_brand']} · ${row['ai_status']}'),
                    subtitle: Text(
                      [
                        '${row['redacted_body']}',
                        '${row['seen_count']} sightings · ${row['distinct_profiles']} profiles',
                        ?templateStatusReason(row),
                      ].join('\n'),
                    ),
                    trailing: TextButton(
                      onPressed: row['ai_status'] == 'ready'
                          ? () async {
                              try {
                                final draft = await api.templateDraft(
                                  row['template_hash'] as String,
                                );
                                open(draft['ruleId'] as String);
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(error.toString())),
                                  );
                                }
                              }
                            }
                          : null,
                      child: const Text('Create draft'),
                    ),
                    children: [
                      if (row['ai_draft'] != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            const JsonEncoder.withIndent(
                              '  ',
                            ).convert(row['ai_draft']),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            _RemotePanel(
              load: () async => [await api.categories()],
              builder: (rows) => ListView(
                children: [
                  const ListTile(
                    title: Text('Reviewed category drafts'),
                    subtitle: Text(
                      'Publishing a category changes shared bundle parts in every cohort.',
                    ),
                  ),
                  for (final draft in rows.first['drafts'] as List? ?? const [])
                    ListTile(
                      title: Text(
                        '${draft['body']['merchantKey']} → ${draft['body']['category']}',
                      ),
                      subtitle: Text(
                        'Revision ${draft['revision']} · ${draft['status']}',
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SmsCategoryEditor(
                            api: api,
                            id: draft['id'] as String,
                            initialRule: (draft['body'] as Map)
                                .cast<String, dynamic>(),
                            revision: draft['status'] == 'draft'
                                ? draft['revision'] as int
                                : null,
                            runner: runner,
                          ),
                        ),
                      ),
                    ),
                  const Divider(),
                  const ListTile(title: Text('Published category rules')),
                  for (final rule in rows.first['rules'] as List? ?? const [])
                    ListTile(
                      title: Text(
                        '${rule['merchantKey']} → ${rule['category']}',
                      ),
                      subtitle: Text(
                        '${rule['match']} · ${rule['source']} · ${(rule['senders'] as List).join(', ')}',
                      ),
                    ),
                ],
              ),
            ),
            _CorrectionsTab(
              api: api,
              onOpen: open,
              onCategory: (id, rule) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SmsCategoryEditor(
                    api: api,
                    id: id,
                    initialRule: rule,
                    runner: runner,
                  ),
                ),
              ),
              onDownload: onDownload ?? downloadJson,
            ),
            _RemotePanel(
              load: () async => [
                {...await api.metrics(), 'bundles': await api.bundles()},
              ],
              builder: (rows) => ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text(
                    'Bundle golden scores',
                    style: TextStyle(fontSize: 20),
                  ),
                  for (final bundle
                      in rows.firstOrNull?['bundles'] as List? ?? const [])
                    ListTile(
                      title: Text(
                        'Bundle ${bundle['bundleVersion']} · ${bundle['cohort']} · ${bundle['status']}',
                      ),
                      subtitle: Text(
                        bundle['goldenSummary'] == null
                            ? 'Imported bundle: no publish report'
                            : jsonEncode(bundle['goldenSummary']),
                      ),
                    ),
                  const Divider(),
                  const Text('AI usage by day', style: TextStyle(fontSize: 20)),
                  ?templateSubmissionsLine(rows.firstOrNull),
                  for (final row
                      in (rows.firstOrNull?['ai'] as List? ?? const []))
                    ListTile(
                      title: Text('${row['day']} · ${row['model']}'),
                      subtitle: Text(
                        '${row['calls']} calls · ${row['total_tokens']} tokens',
                      ),
                      trailing: Text(
                        row['cost_usd'] == null
                            ? 'Price unavailable'
                            : 'USD ${row['cost_usd']}',
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text('Automatically paused rules'),
                  ref
                      .watch(smsV2RulesProvider)
                      .when(
                        data: (rules) => Column(
                          children: [
                            for (final row in rules.where(
                              (r) => r['autoPaused'] == true,
                            ))
                              ListTile(
                                title: Text(row['ruleId'] as String),
                                subtitle: const Text(
                                  'Correction rate exceeded the rollout threshold',
                                ),
                              ),
                          ],
                        ),
                        loading: () => const LinearProgressIndicator(),
                        error: (_, _) =>
                            const Text('Rule metrics unavailable.'),
                      ),
                ],
              ),
            ),
            SmsSettingsTab(api: api),
          ],
        ),
      ),
    );
  }
}

/// Why a shared layout is not drafted: held ones never reach the AI, failed
/// ones carry the worker's failure code. Null for every other status.
String? templateStatusReason(Map row) => switch (row['ai_status']) {
  'held' =>
    'Held: sent without a valid App Check token, so it was not sent to the AI',
  'failed' => 'Failed: ${row['failure_code'] ?? 'unknown'}',
  _ => null,
};

/// "Layouts sent to the AI: n · Held: m" from the metrics' template counts.
Widget? templateSubmissionsLine(Map? metrics) {
  final counts = (metrics?['attestation'] as Map?)?['templateSubmissions'];
  if (counts is! Map) return null;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      'Layouts sent to the AI: ${counts['verified'] ?? 0} · Held: ${counts['unverified'] ?? 0}',
    ),
  );
}

class SmsRulesTable extends StatefulWidget {
  const SmsRulesTable({super.key, required this.rows, required this.onOpen});
  final List<Map<String, dynamic>> rows;
  final void Function(String) onOpen;
  @override
  State<SmsRulesTable> createState() => _SmsRulesTableState();
}

class _SmsRulesTableState extends State<SmsRulesTable> {
  String _search = '', _status = '', _family = '', _sender = '', _sort = 'hits';
  double _metric(Map row, String field) =>
      (row['metrics7d']?[field] as num?)?.toDouble() ?? 0;
  double _rate(Map row) => _metric(row, 'hits') == 0
      ? 0
      : _metric(row, 'corrected') / _metric(row, 'hits');
  @override
  Widget build(BuildContext context) {
    final rows =
        widget.rows
            .where(
              (row) =>
                  (_status.isEmpty || row['status'] == _status) &&
                  (_family.isEmpty || row['family'] == _family) &&
                  (_sender.isEmpty ||
                      (row['senders'] as List? ?? const []).contains(
                        _sender,
                      )) &&
                  jsonEncode(row).toLowerCase().contains(_search.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => _sort == 'hits'
                ? _metric(b, 'hits').compareTo(_metric(a, 'hits'))
                : _rate(b).compareTo(_rate(a)),
          );
    Widget filter(
      String label,
      String value,
      Iterable<String> values,
      ValueChanged<String> update,
    ) => DropdownButton<String>(
      key: Key('filter-$label'),
      value: value,
      items: [
        DropdownMenuItem(value: '', child: Text('All $label')),
        for (final item in values.toSet().toList()..sort())
          DropdownMenuItem(value: item, child: Text(item)),
      ],
      onChanged: (next) => setState(() => update(next!)),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                key: const Key('rules-search'),
                decoration: const InputDecoration(
                  labelText: 'Search rules and senders',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _search = value),
              ),
              Wrap(
                spacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  filter(
                    'status',
                    _status,
                    widget.rows.map((row) => row['status'] as String),
                    (v) => _status = v,
                  ),
                  filter(
                    'family',
                    _family,
                    widget.rows.map((row) => row['family'] as String),
                    (v) => _family = v,
                  ),
                  filter(
                    'sender',
                    _sender,
                    widget.rows.expand(
                      (row) => (row['senders'] as List).cast<String>(),
                    ),
                    (v) => _sender = v,
                  ),
                  DropdownButton<String>(
                    key: const Key('rules-sort'),
                    value: _sort,
                    items: const [
                      DropdownMenuItem(value: 'hits', child: Text('Most hits')),
                      DropdownMenuItem(
                        value: 'corrected',
                        child: Text('Highest correction rate'),
                      ),
                    ],
                    onChanged: (value) => setState(() => _sort = value!),
                  ),
                  Text('${rows.length} rules'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No matching rules'))
              : ListView.builder(
                  itemExtent: 154,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index],
                        hits = _metric(rows[index], 'hits');
                    final review = hits == 0
                        ? 0
                        : _metric(row, 'toReview') / hits;
                    return ListTile(
                      key: ValueKey(row['ruleId']),
                      title: Text(
                        '${row['ruleId']} · v${row['latestVersion']}',
                      ),
                      subtitle: Text(
                        '${(row['senders'] as List).join(', ')} · ${row['family']} · ${row['status']} · ${row['cohort'] ?? 'unreleased'}\n${row['positiveExample'] is String ? smsSkeleton(row['positiveExample'] as String) : ''}\n${hits.toInt()} hits · ${(review * 100).toStringAsFixed(1)}% review · ${(_rate(row) * 100).toStringAsFixed(1)}% corrected\n${(row['factTypes'] as List? ?? const []).join(', ')} · ${row['source'] ?? 'unknown source'} · ${row['exampleCount'] ?? 0} examples\n${row['changedBy'] ?? ''} · ${row['updatedAt'] ?? ''}',
                      ),
                      subtitleTextStyle: Theme.of(context).textTheme.bodySmall,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => widget.onOpen(row['ruleId'] as String),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RemotePanel extends StatefulWidget {
  const _RemotePanel({super.key, required this.load, required this.builder});
  final Future<List<Map<String, dynamic>>> Function() load;
  final Widget Function(List<Map<String, dynamic>>) builder;
  @override
  State<_RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends State<_RemotePanel> {
  late Future<List<Map<String, dynamic>>> _future = widget.load();
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton(
            onPressed: () => setState(() => _future = widget.load()),
            child: const Text('Unable to load data. Retry'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.data!.isEmpty) {
        return const Center(child: Text('Nothing waiting for review.'));
      }
      return widget.builder(snapshot.data!);
    },
  );
}

class _CorrectionsTab extends StatefulWidget {
  const _CorrectionsTab({
    required this.api,
    required this.onOpen,
    required this.onDownload,
    required this.onCategory,
  });
  final SmsV2AdminApi api;
  final void Function(String, {Map<String, dynamic>? draft}) onOpen;
  final void Function(String, String) onDownload;
  final void Function(String, Map<String, dynamic>) onCategory;
  @override
  State<_CorrectionsTab> createState() => _CorrectionsTabState();
}

class _CorrectionsTabState extends State<_CorrectionsTab> {
  int _revision = 0;
  Future<String?> _reason(String action) => showDialog<String>(
    context: context,
    builder: (_) => _ReviewInputDialog(title: action),
  );

  Future<void> _decide(Map row, String decision) async {
    final reason = await _reason(switch (decision) {
      'data_fix' => 'Prepare a data fix',
      'code_fix' => 'Export a code fix',
      _ => 'Mark as not a bug',
    });
    if (reason == null) return;
    try {
      final id = row['case_id'] as String;
      if (decision == 'code_fix') {
        final example = await _syntheticExample();
        if (example == null) return;
        await widget.api.prepareExample(id, example);
      }
      final result = await widget.api.decide(id, decision, reason);
      if (!mounted) return;
      setState(() => _revision++);
      if (decision == 'data_fix') {
        final category = result['categoryDraft'];
        if (category is Map) {
          final keys = category['counterpartyKeys'] as List? ?? const [];
          widget.onCategory(id, {
            'merchantKey': keys.firstOrNull ?? '',
            'match': 'exact',
            'senders': [if (row['sender_brand'] is String) row['sender_brand']],
            'context': <String>[],
            'category': category['category'],
            'priority': category['priority'] ?? 100,
            'source': 'shared',
          });
          return;
        }
        final draft = result['ruleDraft'];
        final ruleId = row['trace']?['ruleId'] as String?;
        if (draft is Map && ruleId != null) {
          widget.onOpen(ruleId, draft: draft.cast<String, dynamic>());
        } else {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Draft needs review'),
              content: SingleChildScrollView(
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(draft ?? result),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        }
      }
      if (decision == 'code_fix') {
        final golden = await widget.api.exportCase(id);
        widget.onDownload(
          '$id.json',
          const JsonEncoder.withIndent('  ').convert(golden),
        );
        await Clipboard.setData(ClipboardData(text: 'sms-fix-case $id'));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Golden case downloaded. The fix command is on the clipboard.',
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<Map<String, dynamic>?> _syntheticExample() =>
      showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => const _ReviewInputDialog(
          synthetic: true,
          title: 'Review the synthetic golden example',
        ),
      );

  @override
  Widget build(BuildContext context) => _RemotePanel(
    key: ValueKey(_revision),
    load: widget.api.correctionGroups,
    builder: (groups) => ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index],
            cases = (groups[index]['cases'] as List).cast<Map>();
        return ExpansionTile(
          title: Text('${group['key']} · ${cases.length} cases'),
          subtitle: Text(
            '${cases.where((row) => row['is_tester'] == true).length} tester cases',
          ),
          children: [
            for (final row in cases)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${row['correction_kind']} · ${row['stage']} · ${row['status']}',
                    ),
                    SelectableText(
                      row['redacted_template']?.toString() ??
                          'No shared template',
                    ),
                    Text('Trace ${jsonEncode(row['trace'])}'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (action, label) in [
                          ('data_fix', 'Data fix'),
                          ('code_fix', 'Code fix'),
                          ('not_a_bug', 'Not a bug'),
                        ])
                          TextButton(
                            key: ValueKey('${row['case_id']}-$action'),
                            onPressed: row['status'] == 'open'
                                ? () => _decide(row, action)
                                : null,
                            child: Text(label),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _ReviewInputDialog extends StatefulWidget {
  const _ReviewInputDialog({required this.title, this.synthetic = false});
  final String title;
  final bool synthetic;
  @override
  State<_ReviewInputDialog> createState() => _ReviewInputDialogState();
}

class _ReviewInputDialogState extends State<_ReviewInputDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.synthetic
        ? const JsonEncoder.withIndent('  ').convert({
            'source': 'synthetic',
            'body': '',
            'observedAt': '2026-11-01T12:00:00Z',
            'expect': {'facts': <Object?>[]},
          })
        : '',
  );
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: widget.synthetic ? 600 : 400,
      child: TextField(
        key: Key(widget.synthetic ? 'synthetic-example' : 'correction-reason'),
        controller: _text,
        minLines: widget.synthetic ? 10 : 1,
        maxLines: widget.synthetic ? 20 : 3,
        decoration: InputDecoration(
          labelText: widget.synthetic ? 'Example JSON' : 'Reason',
          helperText: widget.synthetic
              ? 'Use invented values and explicit expected facts.'
              : null,
          errorText: _error,
        ),
        onChanged: (_) => setState(() {}),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty
            ? null
            : () {
                if (!widget.synthetic) {
                  Navigator.pop(context, _text.text.trim());
                  return;
                }
                try {
                  Navigator.pop(
                    context,
                    (jsonDecode(_text.text) as Map).cast<String, dynamic>(),
                  );
                } catch (_) {
                  setState(() => _error = 'Enter valid example JSON.');
                }
              },
        child: Text(widget.synthetic ? 'Save example' : 'Continue'),
      ),
    ],
  );
}
