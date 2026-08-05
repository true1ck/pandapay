import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-6.1/6.2: crowdsourced merchant visibility. Scope note (see api/'s
/// GET /admin/merchants doc comment): this is a filtered table over
/// `merchants`/`merchant_locations`, not the ui-spec's AD-6.1.1
/// `flutter_map`/OSM pin-cluster map — a real interactive map is a
/// separately-scoped UI investment not attempted here. Every filter AD-6.1.4
/// asks for (category, confidence, published) is still present; AD-6.1.5's
/// "grid-snapped coordinates only" constraint holds automatically since
/// grid_lat/grid_lng are the only columns the backend has to show.
class MerchantsScreen extends ConsumerWidget {
  const MerchantsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final merchants = ref.watch(merchantsProvider);
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

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
                width: 220,
                child: TextField(
                  decoration: const InputDecoration(labelText: 'Search VPA or name', isDense: true),
                  onSubmitted: (v) => ref.read(merchantSearchFilterProvider.notifier).state = v,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: ref.watch(merchantCategoryFilterProvider),
                  decoration: const InputDecoration(labelText: 'Category', isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All categories')),
                    for (final c in categories)
                      DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String)),
                  ],
                  onChanged: (v) => ref.read(merchantCategoryFilterProvider.notifier).state = v,
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<double?>(
                  isExpanded: true,
                  initialValue: ref.watch(merchantMinConfidenceFilterProvider),
                  decoration: const InputDecoration(labelText: 'Min confidence', isDense: true),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Any confidence')),
                    DropdownMenuItem(value: 0.3, child: Text('≥ 0.3')),
                    DropdownMenuItem(value: 0.5, child: Text('≥ 0.5')),
                    DropdownMenuItem(value: 0.8, child: Text('≥ 0.8')),
                  ],
                  onChanged: (v) => ref.read(merchantMinConfidenceFilterProvider.notifier).state = v,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<bool?>(
                  isExpanded: true,
                  initialValue: ref.watch(merchantPublishedFilterProvider),
                  decoration: const InputDecoration(labelText: 'Published', isDense: true),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Any')),
                    DropdownMenuItem(value: true, child: Text('Published only')),
                    DropdownMenuItem(value: false, child: Text('Unpublished only')),
                  ],
                  onChanged: (v) => ref.read(merchantPublishedFilterProvider.notifier).state = v,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: () => ref.invalidate(merchantsProvider),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: merchants.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text('Failed to load merchants: $err')),
            data: (rows) {
              if (rows.isEmpty) return const Center(child: Text('No merchants match these filters.'));
              return ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, i) => _MerchantTile(rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MerchantTile extends ConsumerWidget {
  final Map<String, dynamic> merchant;
  const _MerchantTile(this.merchant);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = merchant;
    return ListTile(
      title: Text(m['display_name'] as String? ?? m['vpa'] as String),
      subtitle: Text(
        '${m['vpa']} · ${m['category_name'] ?? 'uncategorized'} · '
        'confidence ${m['confidence']} (${m['confidence_score']}) · '
        '${m['confirmation_count']} confirmations, ${m['distinct_device_count']} devices'
        '${m['grid_lat'] != null ? ' · grid (${m['grid_lat']}, ${m['grid_lng']})' : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m['is_published'] == true) const Chip(label: Text('published'), visualDensity: VisualDensity.compact),
          if (m['operator_locked'] == true)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.lock, size: 16),
            ),
        ],
      ),
      onTap: () => showDialog(
        context: context,
        builder: (_) => _MerchantDetailDialog(merchantId: m['id'] as String),
      ),
    );
  }
}

class _MerchantDetailDialog extends ConsumerStatefulWidget {
  final String merchantId;
  const _MerchantDetailDialog({required this.merchantId});

  @override
  ConsumerState<_MerchantDetailDialog> createState() => _MerchantDetailDialogState();
}

class _MerchantDetailDialogState extends ConsumerState<_MerchantDetailDialog> {
  late Future<Map<String, dynamic>> _detail;
  bool _busy = false;
  String? _error;
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _detail = ref.read(adminApiProvider)!.fetchMerchantDetail(widget.merchantId);
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(merchantsProvider);
      setState(_load);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Merchant detail'),
      content: SizedBox(
        width: 520,
        height: 480,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _detail,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final m = snapshot.data!['merchant'] as Map<String, dynamic>;
            final locations = (snapshot.data!['locations'] as List).cast<Map<String, dynamic>>();
            final contributions = (snapshot.data!['contributions'] as List).cast<Map<String, dynamic>>();
            final conflicts = (snapshot.data!['conflicts'] as List).cast<Map<String, dynamic>>();
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m['display_name'] as String? ?? m['vpa'] as String,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(m['vpa'] as String),
                  const SizedBox(height: 8),
                  // AD-6.2.1: confidence breakdown — the raw inputs (see
                  // GET /admin/merchants/:id's doc comment for why this is
                  // inputs, not a re-derived score: no scoring job exists yet).
                  Text('Confidence: ${m['confidence']} (score ${m['confidence_score']})'),
                  Text('Confirmations: ${m['confirmation_count']} · distinct devices: ${m['distinct_device_count']}'),
                  Text('Published: ${m['is_published']} · operator-locked: ${m['operator_locked']}'),
                  const Divider(),
                  Text('Locations (${locations.length})', style: Theme.of(context).textTheme.titleSmall),
                  for (final l in locations)
                    Text('  (${l['grid_lat']}, ${l['grid_lng']}) · geohash ${l['geohash6']} · '
                        '${l['confirmation_count']} confirmations'),
                  const Divider(),
                  Text('Contributions (${contributions.length})', style: Theme.of(context).textTheme.titleSmall),
                  for (final c in contributions.take(10))
                    Text('  ${c['submitted_on']} · ${c['kind']} · ${c['reported_name'] ?? c['vpa'] ?? '—'}'
                        '${c['is_counted'] == false ? ' (excluded: ${c['rejected_reason']})' : ''}'),
                  const Divider(),
                  Text('Conflicts (${conflicts.length})', style: Theme.of(context).textTheme.titleSmall),
                  for (final c in conflicts) Text('  ${c['field']}: ${c['state']}'),
                  const Divider(),
                  const Text('Manual override', style: TextStyle(fontWeight: FontWeight.bold)),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'New display name', isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _busy || _nameController.text.isEmpty
                            ? null
                            : () => _act(() => ref
                                .read(adminApiProvider)!
                                .overrideMerchant(widget.merchantId, displayName: _nameController.text, reason: 'console override')),
                        child: const Text('Override name'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _act(() => ref
                                .read(adminApiProvider)!
                                .unpublishMerchant(widget.merchantId, reason: 'console unpublish')),
                        child: const Text('Unpublish'),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
