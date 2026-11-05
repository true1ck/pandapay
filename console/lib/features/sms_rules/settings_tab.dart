import 'package:flutter/material.dart';
import '../../data/admin_api.dart';
import '../../data/sms_v2_admin_api.dart';
import 'reason_dialog.dart';

/// What each setting is called in the console. A setting the server adds
/// without a name here still gets a row (its key is shown).
const smsSettingLabels = <String, String>{
  'templates_per_user_per_day': 'Message layouts per person per day',
  'corrections_per_user_per_day': 'Fixes per person per day',
  'signals_per_user_per_day': 'Shop signals per person per day',
  'signals_min_distinct_users': 'People needed before a shop or name is shown',
  'signals_retention_days': 'Days to keep shop signals',
  'intake_enabled': 'Accept layouts and signals from phones',
  'ai_enabled': 'AI drafting',
  'ai_merchant_suggestions_enabled': 'AI category suggestions for shops',
  'ai_model': 'AI model',
  'ai_rpm': 'AI requests per minute',
  'ai_tpm': 'AI tokens per minute',
  'ai_temperature': 'AI temperature',
  'ai_max_output_tokens': 'AI answer length limit (tokens)',
  'ai_monthly_budget_usd': 'AI monthly budget (USD)',
  'auto_pause_min_hits': 'Auto-pause: hits needed before judging a rule',
  'auto_pause_min_rate': 'Auto-pause: correction rate that pauses a rule',
};

/// Month-to-date AI spend from the metrics' per-day rows (`ai[].day`,
/// `ai[].cost_usd`) for the month of [now].
double aiSpendThisMonth(Map<String, dynamic>? metrics, DateTime now) {
  final prefix =
      '${now.toUtc().year.toString().padLeft(4, '0')}-${now.toUtc().month.toString().padLeft(2, '0')}';
  var total = 0.0;
  for (final row in (metrics?['ai'] as List? ?? const [])) {
    if (row is Map && '${row['day']}'.startsWith(prefix)) {
      total += double.tryParse('${row['cost_usd'] ?? 0}') ?? 0;
    }
  }
  return total;
}

class SmsSettingsTab extends StatefulWidget {
  const SmsSettingsTab({super.key, required this.api, this.now});
  final SmsV2AdminApi api;

  /// Test hook for the month used by the budget banner.
  final DateTime Function()? now;
  @override
  State<SmsSettingsTab> createState() => _SmsSettingsTabState();
}

class _SmsSettingsTabState extends State<SmsSettingsTab> {
  late Future<_Loaded> _future = _load();

  Future<_Loaded> _load() async {
    final settings = await widget.api.settings();
    final limits = await widget.api.userLimits();
    Map<String, dynamic>? metrics;
    try {
      metrics = await widget.api.metrics();
    } catch (_) {
      metrics = null; // The banner is optional; the settings are not.
    }
    List<Map<String, dynamic>> audit;
    try {
      audit = await widget.api.audit(limit: 50);
    } catch (_) {
      audit = const [];
    }
    return _Loaded(settings, limits, metrics, audit);
  }

  void _reload() => setState(() {
    _future = _load();
  });

  void _say(String text) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(text)));

  String _failure(Object error) {
    if (error is AdminApiException) {
      if (error.statusCode == 409) {
        return 'Someone else changed this first. The list has been reloaded.';
      }
      if (error.statusCode == 422) return 'That value is not allowed.';
      return error.message;
    }
    return error.toString();
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final answer = await showDialog<_SettingEdit>(
      context: context,
      builder: (_) => _EditSettingDialog(row: row),
    );
    if (answer == null) return;
    try {
      await widget.api.saveSetting(
        row['key'] as String,
        answer.value,
        answer.reason,
        row['updatedAt'] as String?,
      );
      if (!mounted) return;
      _say('Saved. Phones and the AI worker pick this up within a minute.');
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  Future<void> _removeLimit(Map<String, dynamic> row) async {
    final answer = await askReason(
      context,
      title: 'Remove this limit?',
      message:
          'The person goes back to the shared limit. Their override was: ${row['value']} per day.',
      label: 'Why are you removing it?',
      confirmLabel: 'Remove',
    );
    if (answer == null) return;
    try {
      await widget.api.deleteUserLimit(
        row['profileId'] as String,
        row['key'] as String,
        answer.reason,
      );
    } catch (error) {
      if (mounted) _say(_failure(error));
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Loaded>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton(
            onPressed: _reload,
            child: const Text('Unable to load settings. Retry'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final data = snapshot.data!;
      Object? valueOf(String key) =>
          data.settings.where((row) => row['key'] == key).firstOrNull?['value'];
      final budget = (valueOf('ai_monthly_budget_usd') as num?)?.toDouble();
      final spent = aiSpendThisMonth(data.metrics, (widget.now ?? DateTime.now)());
      final paused = valueOf('ai_enabled') == false;
      final overBudget = budget != null && spent >= budget;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (valueOf('intake_enabled') == false)
            const _Banner(
              key: Key('banner-intake'),
              text:
                  'Intake is paused: phones keep their layouts and signals and try again later.',
            ),
          if (paused)
            const _Banner(
              key: Key('banner-ai-paused'),
              text: 'AI drafting is paused',
            )
          else if (overBudget)
            const _Banner(
              key: Key('banner-ai-budget'),
              text: 'AI drafting is paused until next month: budget reached',
            ),
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final row in data.settings) _SettingRow(row: row, onEdit: _edit),
          const SizedBox(height: 24),
          Text('Per-user limits', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Temporary changes for one person. They end by themselves within 90 days.',
          ),
          if (data.limits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No per-user limits are set.'),
            ),
          for (final row in data.limits)
            ListTile(
              key: Key('limit-${row['profileId']}-${row['key']}'),
              title: Text(
                '${smsSettingLabels[row['key']] ?? row['key']}: ${row['value']}',
              ),
              subtitle: Text(
                'Person ${row['profileId']} · ${row['active'] == true ? 'ends' : 'ended'} ${row['expiresAt']}\n${row['reason'] ?? ''}',
              ),
              isThreeLine: true,
              trailing: TextButton(
                onPressed: () => _removeLimit(row),
                child: const Text('Remove'),
              ),
            ),
          const SizedBox(height: 24),
          Text('Recent changes', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Who changed what, when and why. Read-only.'),
          if (data.audit.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No changes recorded yet.'),
            ),
          for (final entry in data.audit)
            ListTile(
              dense: true,
              key: Key('audit-${entry['at']}-${entry['action']}'),
              title: Text(smsAuditActionLabels['${entry['action']}'] ?? '${entry['action']}'),
              subtitle: Text('${entry['at']} · admin ${'${entry['adminId']}'.length > 8 ? '${entry['adminId']}'.substring(0, 8) : entry['adminId']}\n${entry['reason'] ?? ''}'),
              isThreeLine: true,
            ),
        ],
      );
    },
  );
}

class _Loaded {
  const _Loaded(this.settings, this.limits, this.metrics, this.audit);
  final List<Map<String, dynamic>> settings;
  final List<Map<String, dynamic>> limits;
  final Map<String, dynamic>? metrics;
  final List<Map<String, dynamic>> audit;
}

/// What an audit action is called in "Recent changes".
const smsAuditActionLabels = <String, String>{
  'sms_v2_setting': 'Setting changed',
  'sms_v2_user_limit': 'Per-user limit changed',
  'sms_v2_learning_decision': 'Learning decision',
  'sms_v2_template_reject': 'Draft rejected',
  'sms_v2_template_approve': 'Draft approved',
  'sms_v2_template_requeue': 'Layout requeued',
  'sms_v2_template_block': 'Layout blocked',
  'sms_v2_suggestion_ask_again': 'AI asked again',
  'sms_v2_category_draft': 'Category draft saved',
  'sms_v2_category_publish': 'Category rule published',
  'sms_v2_alias_draft': 'Shop name draft saved',
  'sms_v2_alias_publish': 'Shop name published',
  'sms_v2_rule_pause': 'Rule paused',
};

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.pause_circle_outline),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    ),
  );
}

String _describe(Object? value) =>
    value == null ? 'Use the configured model' : '$value';

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.row, required this.onEdit});
  final Map<String, dynamic> row;
  final void Function(Map<String, dynamic>) onEdit;

  String _range() {
    final min = row['min'], max = row['max'], ceiling = row['ceiling'];
    if (row['type'] == 'bool') return 'On or off';
    if (row['type'] == 'model') {
      final allowed = (row['allowed'] as List? ?? const []).join(', ');
      return allowed.isEmpty ? 'No other models allowed' : 'Allowed: $allowed';
    }
    final top = ceiling ?? max;
    return top == null ? 'From $min' : 'From $min to $top';
  }

  @override
  Widget build(BuildContext context) {
    final key = row['key'] as String;
    return ListTile(
      key: Key('setting-$key'),
      title: Text(smsSettingLabels[key] ?? key),
      subtitle: Text(
        'Default ${_describe(row['default'])} · ${_range()}'
        '${row['reason'] == null ? '' : '\nLast change: ${row['reason']}'}',
      ),
      isThreeLine: row['reason'] != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _describe(row['value']),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          TextButton(
            key: Key('edit-$key'),
            onPressed: () => onEdit(row),
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }
}

class _SettingEdit {
  const _SettingEdit(this.value, this.reason);
  final Object? value;
  final String reason;
}

class _EditSettingDialog extends StatefulWidget {
  const _EditSettingDialog({required this.row});
  final Map<String, dynamic> row;
  @override
  State<_EditSettingDialog> createState() => _EditSettingDialogState();
}

class _EditSettingDialogState extends State<_EditSettingDialog> {
  late Object? _value = widget.row['value'];
  late final TextEditingController _number = TextEditingController(
    text: '${widget.row['value'] ?? ''}',
  );
  final _reason = TextEditingController();
  String? _error;

  String get _type => widget.row['type'] as String;

  @override
  void dispose() {
    _number.dispose();
    _reason.dispose();
    super.dispose();
  }

  Object? _parsed() {
    if (_type == 'bool' || _type == 'model') return _value;
    final number = num.tryParse(_number.text.trim());
    if (number == null) return null;
    if (_type == 'int') return number == number.roundToDouble() ? number.toInt() : null;
    return number.toDouble();
  }

  String? _problem() {
    if (_type == 'bool' || _type == 'model') return null;
    final parsed = _parsed();
    if (parsed == null) {
      return _type == 'int' ? 'Enter a whole number.' : 'Enter a number.';
    }
    final min = widget.row['min'] as num?;
    final top = (widget.row['ceiling'] ?? widget.row['max']) as num?;
    if (min != null && (parsed as num) < min) return 'At least $min.';
    if (top != null && (parsed as num) > top) return 'At most $top.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final label = smsSettingLabels[widget.row['key']] ?? '${widget.row['key']}';
    final problem = _problem();
    final ready = problem == null && _reason.text.trim().length >= 3;
    return AlertDialog(
      title: Text(label),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_type == 'bool')
              SwitchListTile(
                key: const Key('setting-switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(_value == true ? 'On' : 'Off'),
                value: _value == true,
                onChanged: (value) => setState(() => _value = value),
              )
            else if (_type == 'model')
              DropdownButtonFormField<Object?>(
                key: const Key('setting-model'),
                initialValue: _value,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Model'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Use the configured model'),
                  ),
                  for (final model in (widget.row['allowed'] as List? ?? const []))
                    DropdownMenuItem(value: model, child: Text('$model')),
                ],
                onChanged: (value) => setState(() => _value = value),
              )
            else
              TextField(
                key: const Key('setting-number'),
                controller: _number,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'New value',
                  errorText: _error ?? problem,
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reason-text'),
              controller: _reason,
              minLines: 1,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Why are you changing this?',
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
          key: const Key('setting-save'),
          onPressed: ready
              ? () => Navigator.pop(
                  context,
                  _SettingEdit(_parsed(), _reason.text.trim()),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
