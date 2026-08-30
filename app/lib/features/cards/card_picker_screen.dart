import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import 'card_network_util.dart';

/// C3 Add Card (ui-spec Group C: "same picker as A7"). A standalone,
/// reusable widget deliberately kept out of features/onboarding/ — A7
/// (still unbuilt as of this pass, per implementation-plan-group-c-d.md's
/// own audit) can adopt this same screen instead of growing a second copy,
/// once its own flow exists to call it from.
///
/// Searchable, issuer-grouped, card-art-thumbnail list; multi-select with a
/// running count; network filter chips (RuPay/Visa/Mastercard/Amex-Diners);
/// "my card isn't listed" link out to C8. Returns the list of selected
/// [CardProduct]s on pop (null/empty if cancelled) — the caller (My Cards)
/// owns actually calling addCard for each one, same as ScanCardScreen's
/// existing "return a pick, caller acts on it" contract.
class CardPickerScreen extends ConsumerStatefulWidget {
  final VoidCallback? onCardNotListed;
  final String? initialSearch;
  const CardPickerScreen({super.key, this.onCardNotListed, this.initialSearch});

  @override
  ConsumerState<CardPickerScreen> createState() => _CardPickerScreenState();
}

class _CardPickerScreenState extends ConsumerState<CardPickerScreen> {
  late final _searchController = TextEditingController(text: widget.initialSearch ?? '');
  final _selected = <String>{};
  final _networkFilters = <CardNetwork>{};

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
    return card.name.toLowerCase().contains(query) ||
        (card.issuerName?.toLowerCase().contains(query) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Add a card', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
              onPressed: () {
                final catalogueValue = catalogue.valueOrNull ?? const [];
                final picked = catalogueValue.where((c) => _selected.contains(c.id)).toList();
                Navigator.of(context).pop(picked);
              },
              child: Text(
                'Add (${_selected.length})',
                style: BambooFonts.ui(14, weight: FontWeight.w700, color: BambooInk.jade),
              ),
            ),
        ],
      ),
      body: AppBackground(
        child: catalogue.when(
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
                      TextField(
                        controller: _searchController,
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded, color: BambooInk.ink500),
                          hintText: 'Search by issuer or card name',
                          hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
                          filled: true,
                          fillColor: BambooInk.glassFillOnPaper,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final network in [
                              CardNetwork.rupay,
                              CardNetwork.visa,
                              CardNetwork.mastercard,
                              CardNetwork.amex,
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: AppSpace.xs),
                                child: FilterChip(
                                  label: Text(
                                    network == CardNetwork.amex ? 'Amex/Diners' : cardNetworkLabel(network),
                                  ),
                                  labelStyle: BambooFonts.ui(
                                    13,
                                    weight: FontWeight.w600,
                                    color: _networkFilters.contains(network)
                                        ? BambooInk.onSlate
                                        : BambooInk.ink900,
                                  ),
                                  selected: _networkFilters.contains(network),
                                  selectedColor: BambooInk.slate,
                                  backgroundColor: BambooInk.paperMuted,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
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
                                child: Text(issuer, style: BambooFonts.heading(13, color: BambooInk.ink500)),
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
                                  style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                                  onPressed: widget.onCardNotListed,
                                  child: const Text("My card isn't listed"),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

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
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.credit_card_rounded, color: BambooInk.lime, size: 20),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(card.name, style: BambooFonts.ui(15, color: BambooInk.ink900)),
            ),
            Checkbox(
              value: selected,
              onChanged: (_) => onToggle(),
              activeColor: BambooInk.slate,
              checkColor: BambooInk.lime,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
          ],
        ),
      ),
    );
  }
}
