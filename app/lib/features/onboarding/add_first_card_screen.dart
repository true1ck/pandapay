import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import 'request_unsupported_card_screen.dart';

/// ui-spec.md A7 "Add Your First Card". Same picker shape as C3's
/// `CardPickerScreen` (search, issuer-grouped list, network filter chips,
/// multi-select with a running count, "my card isn't listed" footer link)
/// — deliberately not that same widget reused verbatim, because A7's DoD
/// requires a different post-selection action: C3 just pops the pick list
/// back to My Cards, which does its own adding; A7 owns adding the cards
/// itself (sequential `POST /user-cards`, collecting real ids) and then
/// hands off straight into A9 Card Details Setup, which My Cards' flow
/// never needs to do.
///
/// Copy per ui-spec: "Add every card you own — the advice is only as good
/// as what it knows about."
class AddFirstCardScreen extends ConsumerStatefulWidget {
  const AddFirstCardScreen({super.key});

  @override
  ConsumerState<AddFirstCardScreen> createState() => _AddFirstCardScreenState();
}

class _AddFirstCardScreenState extends ConsumerState<AddFirstCardScreen> {
  final _searchController = TextEditingController();
  final _selected = <String>{};
  final _networkFilters = <CardNetwork>{};
  bool _adding = false;
  String? _error;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesNetworkFilter(CardProduct card) {
    if (_networkFilters.isEmpty) return true;
    // Amex/Diners share one filter chip per ui-spec's own grouping.
    if (_networkFilters.contains(CardNetwork.amex) && card.network == CardNetwork.diners) return true;
    return _networkFilters.contains(card.network);
  }

  bool _matchesSearch(CardProduct card) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return card.name.toLowerCase().contains(query) || (card.issuerName?.toLowerCase().contains(query) ?? false);
  }

  /// Validation per spec: "cannot proceed with 0 cards" — the Continue
  /// button being disabled at zero selections is the whole enforcement,
  /// there's no separate error state to design for.
  Future<void> _continue(List<CardProduct> catalogue) async {
    setState(() {
      _adding = true;
      _error = null;
    });
    final repo = ref.read(userCardsRepositoryProvider)!;
    final addedIds = <String>[];
    try {
      // Sequential, not parallel: a handful of cards (not a bulk import),
      // and sequential awaits keep failure attribution simple — if card 3
      // of 5 fails, cards 1-2 are already added and we can say so exactly.
      for (final id in _selected) {
        final userCardId = await repo.addCard(id);
        addedIds.add(userCardId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
    if (addedIds.isEmpty) return; // every add failed — stay here, error shown above.
    ref.invalidate(userCardsProvider);
    ref.invalidate(myCardsProvider);
    if (mounted) context.go(AppRoute.cardDetailsSetup, extra: addedIds);
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Add your cards' : '${_selected.length} selected'),
      ),
      body: catalogue.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(catalogueProvider),
        ),
        data: (cards) {
          final filtered = cards.where(_matchesSearch).where(_matchesNetworkFilter).toList()
            ..sort((a, b) => a.name.compareTo(b.name));
          final byIssuer = <String, List<CardProduct>>{};
          for (final c in filtered) {
            byIssuer.putIfAbsent(c.issuerName ?? 'Other', () => []).add(c);
          }
          final issuers = byIssuer.keys.toList()..sort();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.sm),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Add every card you own — the advice is only as good as what it knows about.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search by issuer or card name',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final network in [CardNetwork.rupay, CardNetwork.visa, CardNetwork.mastercard, CardNetwork.amex])
                            Padding(
                              padding: const EdgeInsets.only(right: AppSpace.xs),
                              child: FilterChip(
                                label: Text(network == CardNetwork.amex ? 'Amex/Diners' : _networkLabel(network)),
                                selected: _networkFilters.contains(network),
                                onSelected: (selected) => setState(() {
                                  if (selected) {
                                    _networkFilters.add(network);
                                  } else {
                                    _networkFilters.remove(network);
                                  }
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(icon: Icons.search_off_rounded, title: 'No cards match')
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                        children: [
                          for (final issuer in issuers) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                              child: Text(issuer, style: Theme.of(context).textTheme.titleSmall),
                            ),
                            for (final card in byIssuer[issuer]!)
                              _CardRow(
                                card: card,
                                selected: _selected.contains(card.id),
                                onToggle: () => setState(() {
                                  if (_selected.contains(card.id)) {
                                    _selected.remove(card.id);
                                  } else {
                                    _selected.add(card.id);
                                  }
                                }),
                              ),
                          ],
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                            child: Center(
                              child: TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const RequestUnsupportedCardScreen()),
                                ),
                                child: const Text("My card isn't listed"),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.error)),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: FilledButton(
                    onPressed: _selected.isEmpty || _adding ? null : () => _continue(cards),
                    child: _adding
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(_selected.isEmpty ? 'Continue' : 'Add ${_selected.length} card${_selected.length == 1 ? '' : 's'}'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _networkLabel(CardNetwork n) => switch (n) {
        CardNetwork.rupay => 'RuPay',
        CardNetwork.visa => 'Visa',
        CardNetwork.mastercard => 'Mastercard',
        CardNetwork.amex => 'Amex',
        CardNetwork.diners => 'Diners',
      };
}

class _CardRow extends StatelessWidget {
  final CardProduct card;
  final bool selected;
  final VoidCallback onToggle;
  const _CardRow({required this.card, required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: AppColors.teal50, borderRadius: BorderRadius.circular(AppRadius.sm)),
              child: const Icon(Icons.credit_card_rounded, color: AppColors.teal600, size: 20),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(child: Text(card.name, style: Theme.of(context).textTheme.bodyLarge)),
            Checkbox(value: selected, onChanged: (_) => onToggle()),
          ],
        ),
      ),
    );
  }
}
