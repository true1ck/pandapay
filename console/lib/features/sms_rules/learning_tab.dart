import 'package:flutter/material.dart';
import 'package:pandapay_domain/sms_v2_template.dart' show smsTemplateHash;
import '../../data/admin_api.dart';
import '../../data/sms_v2_admin_api.dart';
import 'reason_dialog.dart';

/// The category names the console shows for the canonical slugs.
const _categoryNames = <String, String>{
  'groceries': 'Groceries',
  'fuel': 'Fuel',
  'dining': 'Dining',
  'online': 'Online shopping',
  'travel': 'Travel',
  'bills': 'Bills',
  'rent': 'Rent',
  'insurance': 'Insurance',
  'education': 'Education',
  'government': 'Government',
  'wallet': 'Wallet',
  'entertainment': 'Entertainment',
  'health': 'Health',
  'emi': 'EMI',
  'other': 'Other',
};
String categoryName(Object? slug) =>
    _categoryNames['$slug'] ?? '$slug';

/// The draft id for a shop key. The draft tables key on a UUID, so the id is a
/// name-based (version 5 style) UUID built from a hash of the key: the same
/// shop always opens the same draft.
String learningDraftId(String merchantKey) {
  final hex = smsTemplateHash('LEARN', merchantKey);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-5${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}

/// The rule the category editor opens with for a shop and category.
Map<String, dynamic> learnedCategoryRule(String merchantKey, String category) => {
  'merchantKey': merchantKey,
  'match': 'token',
  'senders': ['*'],
  'context': <String>[],
  'category': category,
  'priority': 100,
  'source': 'shared',
};

/// The shop name the editor opens with: [alias] is what the SMS prints and
/// [name] is what people say the shop is called.
Map<String, dynamic> learnedAlias(String alias, String name) => {
  'alias': alias,
  'merchantKey': name,
  'kind': 'learned',
};

/// "12 people chose Dining · 2 chose Groceries" from a split, leader first.
String splitSentence(Map split, {required Object? leader}) {
  final entries = split.entries.toList()
    ..sort((a, b) {
      if (a.key == leader) return -1;
      if (b.key == leader) return 1;
      return (b.value as num).compareTo(a.value as num);
    });
  return [
    for (final (index, entry) in entries.indexed)
      '${entry.value} ${index == 0 ? (entry.value == 1 ? 'person chose' : 'people chose') : 'chose'} ${categoryName(entry.key)}',
  ].join(' · ');
}

/// The Learning page: what phones reported, counted across people, with the
/// controls to turn a group into a draft rule or to dismiss it. Nothing here
/// publishes anything.
class SmsLearningTab extends StatefulWidget {
  const SmsLearningTab({
    super.key,
    required this.api,
    required this.onCreateCategoryRule,
    this.onCreateName,
    this.onOpenCorrections,
  });
  final SmsV2AdminApi api;

  /// Opens the category draft for a shop (the existing editor and publish flow).
  final void Function(String merchantKey, String category) onCreateCategoryRule;

  /// Opens the shop-name draft (Task A8). Without it the name rows only offer Dismiss.
  final void Function(String alias, String name)? onCreateName;
  final VoidCallback? onOpenCorrections;

  @override
  State<SmsLearningTab> createState() => _SmsLearningTabState();
}

class _SmsLearningTabState extends State<SmsLearningTab> {
  late Future<_Learning> _future = _load();

  Future<_Learning> _load() async {
    final api = widget.api;
    final summary = await api.learningSummary();
    final categories = await api.learningCategories();
    final names = await api.learningMerchantNames();
    final uncategorised = await api.learningUncategorised();
    return _Learning(summary, categories, names, uncategorised);
  }

  void _reload() => setState(() {
    _future = _load();
  });

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _failure(Object error) =>
      error is AdminApiException ? error.message : error.toString();

  Future<void> _dismiss(String kind, Map row, String value) async {
    final answer = await askReason(
      context,
      title: 'Dismiss ${row['merchantKey']}?',
      message:
          'It comes back only if many more people report it. Nothing changes on phones.',
      label: 'Why are you dismissing it?',
      confirmLabel: 'Dismiss',
    );
    if (answer == null) return;
    try {
      await widget.api.recordLearningDecision(
        kind: kind,
        merchantKey: row['merchantKey'] as String,
        value: value,
        decision: 'dismissed',
        reason: answer.reason,
      );
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  Future<void> _drafted(String kind, Map row, String value, String reason) async {
    try {
      await widget.api.recordLearningDecision(
        kind: kind,
        merchantKey: row['merchantKey'] as String,
        value: value,
        decision: 'drafted',
        reason: reason,
      );
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
  }

  Future<void> _createRule(Map row, String category) async {
    await _drafted(
      'category_choice',
      row,
      category,
      'Opened the category draft',
    );
    widget.onCreateCategoryRule(row['merchantKey'] as String, category);
    if (mounted) _reload();
  }

  Future<void> _createName(Map row) async {
    await _drafted(
      'merchant_name',
      row,
      row['name'] as String,
      'Opened the shop name draft',
    );
    widget.onCreateName!(row['merchantKey'] as String, row['name'] as String);
    if (mounted) _reload();
  }

  Future<void> _pickCategory(Map row) async {
    final category = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text('Category for ${row['merchantKey']}'),
        children: [
          for (final entry in _categoryNames.entries)
            if (entry.key != 'other')
              SimpleDialogOption(
                key: Key('pick-${entry.key}'),
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
        ],
      ),
    );
    if (category == null || !mounted) return;
    await _drafted(
      'uncategorised',
      row,
      '',
      'Opened the category draft',
    );
    widget.onCreateCategoryRule(row['merchantKey'] as String, category);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Learning>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton(
            onPressed: _reload,
            child: const Text('Unable to load the Learning page. Retry'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final data = snapshot.data!;
      final k = data.summary['minUsers'];
      final theme = Theme.of(context);
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Shops and names appear only when at least $k different people reported them.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _SummaryCards(summary: data.summary),
          const SizedBox(height: 24),
          _Section(
            title: 'Categories',
            empty: 'No shop has $k people agreeing yet.',
            children: [
              for (final row in data.categories)
                _CategoryRow(
                  row: row,
                  onCreate: () => _createRule(row, row['category'] as String),
                  onDismiss: () =>
                      _dismiss('category_choice', row, row['category'] as String),
                ),
            ],
          ),
          _Section(
            title: 'Shop names',
            empty: 'No shop name has $k people agreeing yet.',
            children: [
              for (final row in data.names)
                _NameRow(
                  row: row,
                  onCreate: widget.onCreateName == null ? null : () => _createName(row),
                  onDismiss: () => _dismiss('merchant_name', row, row['name'] as String),
                ),
            ],
          ),
          _Section(
            title: 'Shops in Other',
            empty: 'No shop left in Other has $k people yet.',
            children: [
              for (final row in data.uncategorised)
                _OtherRow(
                  row: row,
                  onPick: () => _pickCategory(row),
                  onDismiss: () => _dismiss('uncategorised', row, ''),
                ),
            ],
          ),
          _Section(
            title: 'Fixes by layout',
            empty: 'No fixes reported in this period.',
            trailing: widget.onOpenCorrections == null
                ? null
                : TextButton(
                    key: const Key('open-corrections'),
                    onPressed: widget.onOpenCorrections,
                    child: const Text('Open Corrections'),
                  ),
            children: [
              for (final row in (data.summary['corrections'] as List? ?? const []))
                ListTile(
                  dense: true,
                  title: Text('${(row as Map)['kind']}'.replaceAll('_', ' ')),
                  subtitle: Text('${row['cases']} reports · ${row['users']} people'),
                ),
            ],
          ),
        ],
      );
    },
  );
}

class _Learning {
  const _Learning(this.summary, this.categoriesPayload, this.namesPayload, this.otherPayload);
  final Map<String, dynamic> summary;
  final Map<String, dynamic> categoriesPayload, namesPayload, otherPayload;
  List<Map> get categories => _rows(categoriesPayload);
  List<Map> get names => _rows(namesPayload);
  List<Map> get uncategorised => _rows(otherPayload);
  static List<Map> _rows(Map<String, dynamic> payload) => [
    for (final row in (payload['candidates'] as List? ?? const [])) row as Map,
  ];
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.empty, required this.children, this.trailing});
  final String title, empty;
  final List<Widget> children;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      key: Key('section-$title'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
            ?trailing,
          ],
        ),
        if (children.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(empty))
        else
          ...children,
      ],
    ),
  );
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.summary});
  final Map<String, dynamic> summary;

  String _percent(Object? value) =>
      value is num ? '${(value * 100).round()}%' : 'n/a';

  @override
  Widget build(BuildContext context) {
    final optIn = (summary['optIn'] as Map?) ?? const {};
    final layouts = (summary['layouts'] as Map?) ?? const {};
    final ai = (summary['ai'] as Map?) ?? const {};
    final coverage = (summary['coverage'] as Map?) ?? const {};
    final candidates = (summary['candidates'] as Map?) ?? const {};
    final signals = [for (final row in (summary['signals'] as List? ?? const [])) row as Map];
    final below = signals.fold<int>(0, (n, row) => n + ((row['belowThreshold'] as num?)?.toInt() ?? 0));
    final trend = [for (final row in (summary['trend'] as List? ?? const [])) row as Map];
    final cards = <(String, String, String)>[
      ('People sharing', '${optIn['sharingNow'] ?? 0}', '${_percent(optIn['shareOfSynced'])} of ${optIn['synced30d'] ?? 0} active accounts'),
      ('Waiting for you', '${candidates['total'] ?? 0}', '${candidates['categories'] ?? 0} categories · ${candidates['merchantNames'] ?? 0} names · ${candidates['uncategorised'] ?? 0} in Other'),
      ('Message layouts', '${layouts['new'] ?? 0} new', '${layouts['queued'] ?? 0} queued · ${layouts['ready'] ?? 0} ready · ${layouts['failed'] ?? 0} failed · ${layouts['covered'] ?? 0} covered'),
      ('AI calls', '${ai['calls'] ?? 0}', 'USD ${(ai['costUsd'] as num?)?.toStringAsFixed(2) ?? '0.00'} · ${ai['approvedRules'] ?? 0} approved rules'),
      ('Read by rules', _percent(coverage['readByRulesShare']), '${coverage['hits'] ?? 0} read · ${coverage['toReview'] ?? 0} sent to review · ${coverage['corrected'] ?? 0} corrected'),
      ('Below the threshold', '$below', 'Shops reported by fewer than ${summary['minUsers']} people (not shown)'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          key: const Key('summary-cards'),
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (title, value, caption) in cards)
              SizedBox(
                width: 260,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.labelMedium),
                        Text(value, style: Theme.of(context).textTheme.headlineSmall),
                        Text(caption, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (trend.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'AI calls per day vs new layouts (is AI use falling?): ${[
                for (final day in trend.reversed.take(7).toList().reversed) '${day['day'].toString().substring(5)} ${day['aiCalls']}/${day['newLayouts']}',
              ].join(' · ')}',
              key: const Key('trend'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status, {this.decision});
  final String status;
  final String? decision;
  @override
  Widget build(BuildContext context) {
    final label = decision == 'drafted' && status == 'new'
        ? 'Drafted'
        : switch (status) {
            'covered' => 'Covered',
            'conflict' => 'Conflict',
            _ => 'New',
          };
    return Chip(
      key: Key('status-$label'),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.row, required this.onCreate, required this.onDismiss});
  final Map row;
  final VoidCallback onCreate, onDismiss;
  @override
  Widget build(BuildContext context) {
    final agreement = (row['agreement'] as num?)?.toDouble() ?? 0;
    final senders = (row['senders'] as List? ?? const []).join(', ');
    return Card(
      key: Key('category-${row['merchantKey']}'),
      child: ListTile(
        title: Row(children: [
          Expanded(child: Text('${row['merchantKey']}')),
          _StatusChip('${row['status']}', decision: row['decision'] as String?),
        ]),
        subtitle: Text(
          '${splitSentence(row['split'] as Map, leader: row['category'])} · ${(agreement * 100).round()}% agree · senders $senders'
          '${agreement < 0.7 ? '\nPeople disagree: consider leaving this unruled' : ''}',
        ),
        isThreeLine: agreement < 0.7,
        trailing: Wrap(spacing: 4, children: [
          TextButton(key: Key('create-${row['merchantKey']}'), onPressed: onCreate, child: const Text('Create rule')),
          TextButton(key: Key('dismiss-${row['merchantKey']}'), onPressed: onDismiss, child: const Text('Dismiss')),
        ]),
      ),
    );
  }
}

class _NameRow extends StatelessWidget {
  const _NameRow({required this.row, required this.onCreate, required this.onDismiss});
  final Map row;
  final VoidCallback? onCreate;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) => Card(
    key: Key('name-${row['merchantKey']}'),
    child: ListTile(
      title: Row(children: [
        Expanded(child: Text('${row['merchantKey']} → ${row['name']}')),
        _StatusChip('${row['status']}', decision: row['decision'] as String?),
      ]),
      subtitle: Text('${row['users']} ${row['users'] == 1 ? 'person' : 'people'}'),
      trailing: Wrap(spacing: 4, children: [
        if (onCreate != null)
          TextButton(key: Key('create-name-${row['merchantKey']}'), onPressed: onCreate, child: const Text('Create name')),
        TextButton(key: Key('dismiss-name-${row['merchantKey']}'), onPressed: onDismiss, child: const Text('Dismiss')),
      ]),
    ),
  );
}

class _OtherRow extends StatelessWidget {
  const _OtherRow({required this.row, required this.onPick, required this.onDismiss});
  final Map row;
  final VoidCallback onPick, onDismiss;
  @override
  Widget build(BuildContext context) => Card(
    key: Key('other-${row['merchantKey']}'),
    child: ListTile(
      title: Row(children: [
        Expanded(child: Text('${row['merchantKey']} · ${row['users']} people')),
        _StatusChip('${row['status']}', decision: row['decision'] as String?),
      ]),
      subtitle: Text('Senders ${(row['senders'] as List? ?? const []).join(', ')}'),
      trailing: Wrap(spacing: 4, children: [
        TextButton(key: Key('pick-${row['merchantKey']}'), onPressed: onPick, child: const Text('Pick category')),
        TextButton(key: Key('dismiss-other-${row['merchantKey']}'), onPressed: onDismiss, child: const Text('Dismiss')),
      ]),
    ),
  );
}
