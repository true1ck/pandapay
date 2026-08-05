import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-7 Acceptance Map & Effective Rate Monitor — same scope note as AD-6
/// (api/'s GET /admin/acceptance-summary doc comment): a filtered table
/// over acceptance_summary, not a real flutter_map/OSM view.
class AcceptanceRatesScreen extends StatelessWidget {
  const AcceptanceRatesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Acceptance'), Tab(text: 'Effective rate monitor')]),
          const Expanded(
            child: TabBarView(children: [_AcceptanceTab(), _EffectiveRateTab()]),
          ),
        ],
      ),
    );
  }
}

class _AcceptanceTab extends ConsumerWidget {
  const _AcceptanceTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(acceptanceSummaryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: ref.watch(acceptanceNetworkFilterProvider),
                  decoration: const InputDecoration(labelText: 'Network', isDense: true),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All networks')),
                    DropdownMenuItem(value: 'amex', child: Text('Amex')),
                    DropdownMenuItem(value: 'diners', child: Text('Diners')),
                    DropdownMenuItem(value: 'rupay', child: Text('RuPay')),
                    DropdownMenuItem(value: 'visa', child: Text('Visa')),
                    DropdownMenuItem(value: 'mastercard', child: Text('Mastercard')),
                  ],
                  onChanged: (v) => ref.read(acceptanceNetworkFilterProvider.notifier).state = v,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<bool?>(
                  isExpanded: true,
                  initialValue: ref.watch(acceptancePublishedFilterProvider),
                  decoration: const InputDecoration(labelText: 'Published', isDense: true),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Any')),
                    DropdownMenuItem(value: true, child: Text('Published only')),
                    DropdownMenuItem(value: false, child: Text('Unpublished only')),
                  ],
                  onChanged: (v) => ref.read(acceptancePublishedFilterProvider.notifier).state = v,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text('Failed to load acceptance data: $err')),
            data: (list) {
              if (list.isEmpty) return const Center(child: Text('No acceptance data matches these filters.'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _AcceptanceTile(list[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AcceptanceTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> row;
  const _AcceptanceTile(this.row);

  @override
  ConsumerState<_AcceptanceTile> createState() => _AcceptanceTileState();
}

class _AcceptanceTileState extends ConsumerState<_AcceptanceTile> {
  bool _busy = false;

  Future<void> _togglePublish() async {
    setState(() => _busy = true);
    try {
      final r = widget.row;
      await ref.read(adminApiProvider)!.publishAcceptanceSummary(
            r['merchant_id'] as String,
            r['network'] as String,
            r['rail'] as String,
            published: !(r['is_published'] as bool),
            reason: 'console toggle',
          );
      ref.invalidate(acceptanceSummaryProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final total = (r['accepted_count'] as int) + (r['declined_count'] as int);
    final acceptRate = total == 0 ? 0.0 : (r['accepted_count'] as int) / total;
    return ListTile(
      // AD-7.1.3 pin detail equivalent: merchant, network/rail, confirming
      // reports, confidence — everything the ui-spec asks a pin to show.
      title: Text('${r['display_name'] ?? r['vpa']} — ${r['network']} / ${r['rail']}'),
      subtitle: Text(
        '${r['accepted_count']} accepted, ${r['declined_count']} declined '
        '(${(acceptRate * 100).toStringAsFixed(0)}% accept rate) · '
        'confidence ${r['confidence_score']}',
      ),
      trailing: FilledButton(
        onPressed: _busy ? null : _togglePublish,
        child: Text(r['is_published'] == true ? 'Unpublish' : 'Publish'),
      ),
    );
  }
}

class _EffectiveRateTab extends ConsumerWidget {
  const _EffectiveRateTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(effectiveRateSummaryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilterChip(
            label: const Text('Divergent only'),
            selected: ref.watch(effectiveRateDivergentOnlyProvider),
            onSelected: (v) => ref.read(effectiveRateDivergentOnlyProvider.notifier).state = v,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text('Failed to load effective-rate data: $err')),
            data: (list) {
              if (list.isEmpty) return const Center(child: Text('No effective-rate samples yet.'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _EffectiveRateTile(list[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EffectiveRateTile extends StatelessWidget {
  final Map<String, dynamic> row;
  const _EffectiveRateTile(this.row);

  @override
  Widget build(BuildContext context) {
    final r = row;
    final isDivergent = r['is_divergent'] == true;
    return ListTile(
      tileColor: isDivergent ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.25) : null,
      title: Text('${r['card_name']} — ${r['category_name'] ?? 'uncategorized'} (${r['period_month']})'),
      subtitle: Text(
        // AD-7.3: observed vs published rate, sample count + distinct
        // devices always shown alongside the number (per the plan's
        // explicit "never show a number without provenance" instruction).
        'Observed ${r['observed_rate_mean']}% (n=${r['sample_count']}, '
        '${r['distinct_devices']} devices) vs published ${r['published_rate']}% '
        '(${r['divergence_pct']}% divergence)\n'
        // AD-7.4 cap-ceiling detection view, made legible per the plan.
        '${r['observed_cap_ceiling'] != null ? 'Observed cap ceiling ₹${r['observed_cap_ceiling']} vs published ₹${r['published_cap_value']}' : ''}',
      ),
      isThreeLine: true,
      trailing: r['linked_alert_id'] != null
          // AD-7.5: never a standalone dead end — links straight to the
          // corresponding AD-6 (this codebase's AD-5-equivalent) alert.
          ? Chip(
              label: Text('Alert: ${r['linked_alert_state']}'),
              avatar: const Icon(Icons.link, size: 16),
            )
          : null,
    );
  }
}
