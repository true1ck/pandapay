import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-2.1: New Card Request queue, grouped by issuer+product with counts so
/// priority follows actual demand. "Start scraping" creates a pre-filled
/// `sources` row (disabled until ToS review, enforced by the DB itself).
class CardRequestsScreen extends ConsumerWidget {
  const CardRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(cardRequestGroupsProvider);

    return groups.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load card requests: $err')),
      data: (groupList) {
        if (groupList.isEmpty) {
          return const Center(child: Text('No open card requests.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: groupList.length,
          itemBuilder: (context, index) => _CardRequestGroupTile(groupList[index]),
        );
      },
    );
  }
}

class _CardRequestGroupTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> group;
  const _CardRequestGroupTile(this.group);

  @override
  ConsumerState<_CardRequestGroupTile> createState() => _CardRequestGroupTileState();
}

class _CardRequestGroupTileState extends ConsumerState<_CardRequestGroupTile> {
  late final TextEditingController _urlController;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
  }

  Future<void> _startScraping() async {
    if (_urlController.text.trim().isEmpty) {
      setState(() => _error = 'base URL is required');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final api = ref.read(adminApiProvider)!;
      await api.startScrapingSource(
        issuerName: widget.group['issuer_name'] as String,
        productName: widget.group['product_name'] as String?,
        baseUrl: _urlController.text.trim(),
      );
      ref.invalidate(cardRequestGroupsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final isStale = g['is_stale'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text('${g['issuer_name']} — ${g['product_name']}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (isStale) ...[
                  const SizedBox(width: 8),
                  Chip(
                    label: Text('Stale · ${g['oldest_pending_age_days']}d'),
                    backgroundColor: Colors.orange.shade100,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            Text('${g['total_requests']} requests · ${g['distinct_reporters']} reporters'
                '${g['network_guess'] != null ? ' · ${g['network_guess']}' : ''}'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(labelText: 'Bank page URL', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _starting ? null : _startScraping,
                  child: Text(_starting ? '...' : 'Start scraping this issuer'),
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
    );
  }
}
