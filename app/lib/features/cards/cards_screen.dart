import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';
import '../auth/login_screen.dart';

/// UA-3+ (Chunk 16): the Cards tab — a signed-in user's actual wallet.
/// Signed-out shows the same login flow as More/AccountScreen (owning
/// cards requires an identity); signed-in shows the wallet with an
/// add-from-catalogue flow and archive (R4: never delete).
class CardsScreen extends ConsumerWidget {
  const CardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final userCards = ref.watch(userCardsProvider);
    return userCards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load your cards: $err')),
      data: (cards) => Column(
        children: [
          Expanded(
            child: cards.isEmpty
                ? const Center(child: Text('No cards yet — add one below.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: cards.length,
                    itemBuilder: (context, index) => _UserCardTile(cards[index]),
                  ),
          ),
          const Padding(padding: EdgeInsets.all(12), child: _AddCardForm()),
        ],
      ),
    );
  }
}

class _UserCardTile extends ConsumerStatefulWidget {
  final UserCard card;
  const _UserCardTile(this.card);

  @override
  ConsumerState<_UserCardTile> createState() => _UserCardTileState();
}

class _UserCardTileState extends ConsumerState<_UserCardTile> {
  bool _logging = false;

  Future<void> _logTransaction() async {
    setState(() => _logging = true);
    try {
      final categoryId = ref.read(_resolvedSelectedCategoryIdProvider);
      final amount = ref.read(enteredAmountProvider);
      await ref.read(userCardsRepositoryProvider)!.logTransaction(
            userCardId: widget.card.id,
            amount: amount,
            categoryId: categoryId,
          );
      ref.invalidate(userCardsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to log spend: $e')));
      }
    } finally {
      if (mounted) setState(() => _logging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final amount = ref.watch(enteredAmountProvider);
    final subtitleParts = <String>[
      if (card.nickname?.isNotEmpty == true) card.cardName,
      if (card.totalPointsEarned > 0) '${card.totalPointsEarned.toStringAsFixed(0)} pts earned',
      for (final fw in card.feeWaiverStates)
        fw.waivedAt != null
            ? 'Fee waived (${fw.qualifiedSpend.format()} spent)'
            : '${fw.qualifiedSpend.format()} of ${fw.thresholdSpend.format()} toward fee waiver',
    ];
    return Card(
      child: ListTile(
        title: Text(card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName),
        subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(_logging ? Icons.hourglass_top : Icons.add_card),
              tooltip: 'Log a ${amount.format()} spend on this card (enter amount on Home)',
              onPressed: _logging ? null : _logTransaction,
            ),
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: 'Archive (never deleted)',
              onPressed: () async {
                await ref.read(userCardsRepositoryProvider)!.archiveCard(card.id);
                ref.invalidate(userCardsProvider);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Reuses Home's selectedCategoryProvider (a slug) resolved to the UUID
/// reward_rules.category_id/cap_rules.category_id actually need — same
/// slug->id bridge providers.dart's rankedRecommendationsProvider already
/// does, so a logged spend is attributed to the same category Home is
/// currently showing recommendations for.
final _resolvedSelectedCategoryIdProvider = Provider<String?>((ref) {
  final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
  final selectedSlug = ref.watch(selectedCategoryProvider);
  for (final c in categories) {
    if (c.slug == selectedSlug) return c.id;
  }
  return null;
});

class _AddCardForm extends ConsumerStatefulWidget {
  const _AddCardForm();
  @override
  ConsumerState<_AddCardForm> createState() => _AddCardFormState();
}

class _AddCardFormState extends ConsumerState<_AddCardForm> {
  String? _selectedCardId;
  bool _adding = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    return catalogue.when(
      loading: () => const SizedBox.shrink(),
      error: (err, _) => Text('Failed to load catalogue: $err'),
      data: (cards) {
        if (cards.isEmpty) return const SizedBox.shrink();
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _selectedCardId,
                decoration: const InputDecoration(labelText: 'Add a card'),
                items: [
                  for (final c in cards) DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (value) => setState(() => _selectedCardId = value),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _adding || _selectedCardId == null ? null : _addCard,
              child: Text(_adding ? '...' : 'Add'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        );
      },
    );
  }

  Future<void> _addCard() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await ref.read(userCardsRepositoryProvider)!.addCard(_selectedCardId!);
      ref.invalidate(userCardsProvider);
      setState(() => _selectedCardId = null);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}
