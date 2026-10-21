import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

class ReferralOperationsScreen extends ConsumerStatefulWidget {
  const ReferralOperationsScreen({super.key});

  @override
  ConsumerState<ReferralOperationsScreen> createState() =>
      _ReferralOperationsScreenState();
}

class _ReferralOperationsScreenState
    extends ConsumerState<ReferralOperationsScreen> {
  String? _busyScope;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(referralOperationsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Referral operations'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(referralOperationsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load referral operations: $error'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(referralOperationsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (operations) => _buildOperations(operations),
      ),
    );
  }

  Widget _buildOperations(Map<String, dynamic> operations) {
    final access = _map(operations['access']);
    final campaign = _map(operations['campaign']);
    final workers = _list(operations['workers']);
    final outbox = _map(operations['outbox']);
    final activeHolds = _list(operations['activeHolds']);
    final recentAudit = _list(operations['recentAudit']);
    final campaignVersion = campaign?['version'] as String?;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Status and emergency holds',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        const Text(
          'Every hold requires an operator reason and is recorded in the audit log.',
        ),
        const SizedBox(height: 20),
        _section('Admission', [
          _holdTile(
            scope: 'admission',
            label: 'New member admission',
            state: access?['admissionMode']?.toString() ?? 'unknown',
            targetKey: 'global',
            holds: activeHolds,
            available: access != null,
          ),
        ]),
        _section('Active campaign', [
          if (campaign == null)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('No active campaign'),
              subtitle: Text(
                'Campaign-specific holds are unavailable until one is configured.',
              ),
            )
          else ...[
            ListTile(
              title: Text('Version ${campaign['version']}'),
              subtitle: Text(
                'Enrollment ${campaign['enrollmentCount']}/${campaign['enrollmentCap'] ?? 'uncapped'} · '
                'issued ₹${_paise(campaign['issuedPaise'])} · '
                'reserved ₹${_paise(campaign['reservedPaise'])} · '
                'budget ₹${_paise(campaign['budgetPaise'])}',
              ),
            ),
            _holdTile(
              scope: 'enrollment',
              label: 'New referral enrollment',
              state: campaign['enrollmentOpen'] == true ? 'open' : 'closed',
              targetKey: campaignVersion,
              holds: activeHolds,
              available: true,
            ),
            _holdTile(
              scope: 'fulfillment',
              label: 'Reward fulfillment',
              state: campaign['fulfillmentPaused'] == true
                  ? 'paused'
                  : 'running',
              targetKey: campaignVersion,
              holds: activeHolds,
              available: true,
            ),
            _holdTile(
              scope: 'redemption',
              label: 'Credit redemption',
              state: campaign['redemptionPaused'] == true
                  ? 'paused'
                  : 'running',
              targetKey: campaignVersion,
              holds: activeHolds,
              available: true,
            ),
          ],
        ]),
        _section('Reward worker', [
          if (workers.isEmpty)
            const ListTile(
              leading: Icon(Icons.warning_amber),
              title: Text('No worker heartbeat recorded'),
              subtitle: Text(
                'Check worker deployment and credentials before enabling fulfillment.',
              ),
            )
          else
            for (final worker in workers)
              ListTile(
                leading: Icon(
                  (worker['heartbeatAgeSeconds'] as num? ?? 999999) > 180
                      ? Icons.warning_amber
                      : Icons.check_circle_outline,
                ),
                title: Text('Worker ${worker['workerId']}'),
                subtitle: Text(
                  'Heartbeat ${worker['heartbeatAgeSeconds']}s ago · polls ${worker['polls']} · '
                  'claimed ${worker['claimedEvents']} · completed ${worker['completedEvents']}'
                  '${worker['lastErrorCode'] == null ? '' : ' · last error ${worker['lastErrorCode']}'}',
                ),
              ),
          ListTile(
            title: const Text('Outbox'),
            subtitle: Text(
              'Counts ${outbox?['countsByState'] ?? const {}} · '
              'oldest pending ${outbox?['oldestPendingAgeSeconds'] ?? 0}s',
            ),
          ),
        ]),
        _section('Recent hold audit', [
          if (recentAudit.isEmpty)
            const ListTile(title: Text('No hold actions recorded'))
          else
            for (final audit in recentAudit)
              ListTile(
                title: Text('${audit['action']} · ${audit['scope']}'),
                subtitle: Text('${audit['reason']} · ${audit['occurredAt']}'),
                isThreeLine: true,
              ),
        ]),
      ],
    );
  }

  Widget _holdTile({
    required String scope,
    required String label,
    required String state,
    required String? targetKey,
    required List<Map<String, dynamic>> holds,
    required bool available,
  }) {
    final matchingHolds = holds.where(
      (hold) => hold['scope'] == scope && hold['targetKey'] == targetKey,
    );
    final activeHold = matchingHolds.isEmpty ? null : matchingHolds.first;
    final releasing = activeHold != null;
    final enabled = available && targetKey != null && _busyScope == null;
    return ListTile(
      title: Text(label),
      subtitle: Text(
        releasing ? '$state · hold: ${activeHold['reason']}' : state,
      ),
      trailing: OutlinedButton(
        onPressed: !enabled ? null : () => _changeHold(scope, label, releasing),
        child: _busyScope == scope
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(releasing ? 'Release hold' : 'Pause'),
      ),
    );
  }

  Future<void> _changeHold(String scope, String label, bool releasing) async {
    final reason = await _askReason(
      '$label: ${releasing ? 'release hold' : 'pause'}',
    );
    if (reason == null || !mounted) return;

    setState(() => _busyScope = scope);
    try {
      await ref
          .read(adminApiProvider)!
          .setReferralHold(scope: scope, paused: !releasing, reason: reason);
      ref.invalidate(referralOperationsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              releasing ? '$label hold released.' : '$label paused.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update hold: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyScope = null);
    }
  }

  Future<String?> _askReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _ReferralHoldReasonDialog(title: title),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ...children,
        ],
      ),
    ),
  );

  Map<String, dynamic>? _map(Object? value) =>
      value is Map<String, dynamic> ? value : null;

  List<Map<String, dynamic>> _list(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];

  String _paise(Object? value) {
    final paise = int.tryParse(value?.toString() ?? '');
    return paise == null ? '—' : (paise / 100).toStringAsFixed(2);
  }
}

class _ReferralHoldReasonDialog extends StatefulWidget {
  const _ReferralHoldReasonDialog({required this.title});

  final String title;

  @override
  State<_ReferralHoldReasonDialog> createState() =>
      _ReferralHoldReasonDialogState();
}

class _ReferralHoldReasonDialogState extends State<_ReferralHoldReasonDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        maxLength: 500,
        decoration: const InputDecoration(
          labelText: 'Reason for audit log',
          border: OutlineInputBorder(),
        ),
        validator: (value) {
          final length = value?.trim().length ?? 0;
          if (length < 10) return 'Enter at least 10 characters.';
          return null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, _controller.text.trim());
          }
        },
        child: const Text('Confirm'),
      ),
    ],
  );
}
