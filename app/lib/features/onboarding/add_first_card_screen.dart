import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../cards/find_cards_screen.dart';
import '../scan/scan_card_screen.dart';
import '../sms_import/sms_listener_service.dart';
import 'all_set_screen.dart';
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
    return card.name.toLowerCase().contains(query) ||
        (card.issuerName?.toLowerCase().contains(query) ?? false);
  }

  /// Validation per spec: "cannot proceed with 0 cards" — the Continue
  /// button being disabled at zero selections is the whole enforcement,
  /// there's no separate error state to design for.
  Future<void> _continue(List<CardProduct> catalogue) async {
    setState(() {
      _adding = true;
      _error = null;
    });
    final repo = ref.read(userCardsRepositoryProvider);
    final addedIds = <String>[];
    try {
      // Sequential, not parallel: a handful of cards (not a bulk import),
      // and sequential awaits keep failure attribution simple — if card 3
      // of 5 fails, cards 1-2 are already added and we can say so exactly.
      if (repo == null) {
        // Guest mode (ui-spec.md A3) — same sequential-add shape, backed
        // by the on-device wallet instead of POST /user-cards.
        final local = await ref.read(localUserCardsRepositoryProvider.future);
        for (final id in _selected) {
          final userCardId = await local.addCard(id);
          addedIds.add(userCardId);
        }
      } else {
        for (final id in _selected) {
          final userCardId = await repo.addCard(id);
          addedIds.add(userCardId);
        }
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

  /// Design 30's "FASTEST · 4 seconds — Find them in my SMS" primary path.
  /// There is no real bank-SMS card-detection parser in this codebase yet
  /// (UA-5.3's SmsListenerService/parsing engine detects *transactions*
  /// from SMS already sent from a known card, not "which cards does this
  /// person own" from scratch) — building that honestly would be a new
  /// parsing feature, not a wiring task. So this does the one real thing
  /// available: starts real SMS transaction tracking for later (same
  /// permission Tracking Setup's own SMS option requests), then hands off
  /// to the real card list below rather than pretending to have picked
  /// anything for the user.
  /// Design 30's fastest path. On Android this also turns on SMS reading
  /// first (with the user's permission), because that's a second source the
  /// matcher can use; on iOS it goes straight to the email-backed scan,
  /// which is the only automatic source available there.
  Future<void> _findMyCards() async {
    if (!kIsWeb && Platform.isAndroid) {
      await SmsListenerService().requestPermissions();
      if (!mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FindCardsScreen()));
    if (mounted) ref.invalidate(myCardsProvider);
  }

  /// Design 30's "Photograph the card" path — reuses the real OCR scanner
  /// already shipped for Wallet's own add-a-card flow (ScanCardScreen),
  /// not a new implementation.
  Future<void> _photographCard(List<CardProduct> catalogue) async {
    final picked = await Navigator.of(
      context,
    ).push<CardProduct>(MaterialPageRoute(builder: (_) => ScanCardScreen(catalogue: catalogue)));
    if (picked != null && mounted) setState(() => _selected.add(picked.id));
  }

  /// Design 30's "I'll do this later" escape hatch — Home/Wallet already
  /// have a real no-cards-yet empty state (ui-spec 21), so skipping here is
  /// just moving on without adding anything, same shape as Tracking
  /// Setup's own always-available "Set up later".
  /// Onboarding is NOT completed here — AllSetScreen's "Take me Home" does
  /// it, for the redirect-guard ordering reason documented in
  /// TrackingSetupScreen._finish().
  Future<void> _skip() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllSetScreen()));
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
        title: Text(
          _selected.isEmpty ? 'Add your cards' : '${_selected.length} selected',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
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
                      // Design 30: "Step 2 of 3" progress bar at 66%.
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: 2 / 3,
                                minHeight: 6,
                                backgroundColor: BambooInk.paperMuted,
                                color: BambooInk.slate,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Text(
                            'Step 2 of 3',
                            style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.ink500),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.lg),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Add every card you own — the advice is only as good as what it knows about.',
                          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      Row(
                        children: [
                          Expanded(
                            child: _MethodCard(
                              icon: Icons.auto_awesome_rounded,
                              badge: 'FASTEST',
                              // Design 30 says "Find them in my SMS". SMS is
                              // Android-only — no iOS app may read it — so
                              // the same button reads bank *email* too, and
                              // is named for what it does rather than for
                              // one of its two sources. On iOS email is the
                              // only automatic route that exists.
                              title: 'Find my cards',
                              onTap: _findMyCards,
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Expanded(
                            child: _MethodCard(
                              icon: Icons.camera_alt_outlined,
                              badge: null,
                              title: 'Photograph the card',
                              onTap: () => _photographCard(cards),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.lg),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Or pick from 340 Indian cards',
                          style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink500),
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
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
                                    network == CardNetwork.amex ? 'Amex/Diners' : _networkLabel(network),
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
                    child: Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: BambooInk.slate,
                            foregroundColor: BambooInk.lime,
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                          ),
                          onPressed: _selected.isEmpty || _adding ? null : () => _continue(cards),
                          child: _adding
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                                )
                              : Text(
                                  _selected.isEmpty
                                      ? 'Continue'
                                      : 'Add ${_selected.length} card${_selected.length == 1 ? '' : 's'}',
                                ),
                        ),
                        if (_selected.isEmpty) ...[
                          const SizedBox(height: AppSpace.xs),
                          TextButton(
                            onPressed: _adding ? null : _skip,
                            style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                            child: const Text("I'll do this later"),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
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

class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String? badge;
  final String title;
  final VoidCallback onTap;
  const _MethodCard({required this.icon, required this.badge, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: badge != null ? BambooInk.slate : BambooInk.hairlineOnPaper,
            width: badge != null ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: BambooInk.lime, borderRadius: BorderRadius.circular(999)),
                child: Text(
                  badge!,
                  style: BambooFonts.ui(
                    9.5,
                    weight: FontWeight.w700,
                    color: BambooInk.slate,
                  ).copyWith(letterSpacing: 0.4),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            Icon(icon, color: BambooInk.ink900, size: 22),
            const SizedBox(height: AppSpace.sm),
            Text(
              title,
              style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900),
            ),
          ],
        ),
      ),
    );
  }
}
