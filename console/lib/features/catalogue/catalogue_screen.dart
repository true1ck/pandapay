import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-1.1.1 catalogue browse (cut down): card list with status + a reward
/// rule rate editor, plus AD-1.1.4's draft->in_review->published->archived
/// state machine (publish sets verified_at server-side — the human
/// verification pass). Missing vs the full plan: tabbed rule-family editor,
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

const Map<String, List<String>> _cardStatusTransitions = {
  'draft': ['in_review'],
  'in_review': ['draft', 'published'],
  'published': ['archived'],
  'archived': [],
};

class _CardEditorTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> card;
  const _CardEditorTile(this.card);

  @override
  ConsumerState<_CardEditorTile> createState() => _CardEditorTileState();
}

class _CardEditorTileState extends ConsumerState<_CardEditorTile> {
  bool _changingStatus = false;
  String? _statusError;

  Future<void> _changeStatus(String nextStatus) async {
    setState(() {
      _changingStatus = true;
      _statusError = null;
    });
    try {
      final api = ref.read(adminApiProvider)!;
      await api.changeCardStatus(
        widget.card['id'] as String,
        nextStatus,
        reason: nextStatus == 'published' ? 'Console: human-verified and published' : 'Console status change',
      );
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() => _statusError = e.toString());
    } finally {
      if (mounted) setState(() => _changingStatus = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final rewardRules = (card['reward_rules'] as List).cast<Map<String, dynamic>>();
    final status = card['status'] as String;
    final nextOptions = _cardStatusTransitions[status] ?? const <String>[];
    final verifiedAt = card['verified_at'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text('${card['name']} — $status'),
        subtitle: Text('${card['network']} · data_version ${card['data_version']}'
            '${card['is_upi_linkable'] == true ? ' · UPI-linkable' : ''}'
            '${verifiedAt != null ? ' · verified $verifiedAt' : ' · not verified'}'),
        children: [
          for (final rule in rewardRules) _RewardRuleRow(cardId: card['id'] as String, rule: rule),
          if (nextOptions.isNotEmpty || _statusError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final next in nextOptions)
                        OutlinedButton(
                          onPressed: _changingStatus ? null : () => _changeStatus(next),
                          child: Text(_changingStatus
                              ? '...'
                              : next == 'published'
                                  ? 'Verify & publish'
                                  : 'Move to $next'),
                        ),
                    ],
                  ),
                  if (_statusError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_statusError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
            ),
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
