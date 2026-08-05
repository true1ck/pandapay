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

class _UserCardTile extends ConsumerWidget {
  final UserCard card;
  const _UserCardTile(this.card);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        title: Text(card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName),
        subtitle: card.nickname?.isNotEmpty == true ? Text(card.cardName) : null,
        trailing: IconButton(
          icon: const Icon(Icons.archive_outlined),
          tooltip: 'Archive (never deleted)',
          onPressed: () async {
            await ref.read(userCardsRepositoryProvider)!.archiveCard(card.id);
            ref.invalidate(userCardsProvider);
          },
        ),
      ),
    );
  }
}

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
