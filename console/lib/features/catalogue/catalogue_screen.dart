import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-1.1.1 catalogue browse (cut down): card list with status + a reward
/// rule rate editor. Missing vs the full plan: tabbed rule-family editor,
/// diff-before-save confirmation, impact preview, bulk YAML import/export —
/// all UA-1.2+/AD-1.2/AD-1.3 territory, not built.
class CatalogueScreen extends ConsumerWidget {
  const CatalogueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(adminCardsProvider);

    return cards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load catalogue: $err')),
      data: (cardList) {
        if (cardList.isEmpty) {
          return const Center(child: Text('No cards found.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: cardList.length,
          itemBuilder: (context, index) => _CardEditorTile(cardList[index]),
        );
      },
    );
  }
}

class _CardEditorTile extends ConsumerWidget {
  final Map<String, dynamic> card;
  const _CardEditorTile(this.card);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rewardRules = (card['reward_rules'] as List).cast<Map<String, dynamic>>();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text('${card['name']} — ${card['status']}'),
        subtitle: Text('${card['network']} · data_version ${card['data_version']}'
            '${card['is_upi_linkable'] == true ? ' · UPI-linkable' : ''}'),
        children: [
          for (final rule in rewardRules) _RewardRuleRow(cardId: card['id'] as String, rule: rule),
        ],
      ),
    );
  }
}

class _RewardRuleRow extends ConsumerStatefulWidget {
  final String cardId;
  final Map<String, dynamic> rule;
  const _RewardRuleRow({required this.cardId, required this.rule});

  @override
  ConsumerState<_RewardRuleRow> createState() => _RewardRuleRowState();
}

class _RewardRuleRowState extends ConsumerState<_RewardRuleRow> {
  late final TextEditingController _rateController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rateController = TextEditingController(text: '${widget.rule['rate']}');
  }

  Future<void> _save() async {
    final rate = double.tryParse(_rateController.text);
    if (rate == null || rate < 0) {
      setState(() => _error = 'rate must be a non-negative number');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(adminApiProvider);
      await api!.updateRewardRuleRate(widget.rule['id'] as String, rate, reason: 'Console edit');
      ref.invalidate(adminCardsProvider); // AD-1.1.5-adjacent: refetch so data_version/rate are current
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('${widget.rule['unit']}')),
          SizedBox(
            width: 100,
            child: TextField(
              controller: _rateController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '...' : 'Save'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
