import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/override_resolver.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../comparison/comparison_view_screen.dart';

/// ui-spec B3. See Task 12's plan-doc header for three stated scope
/// reductions: no automatic VPA->merchant crowdsource lookup, no silent
/// background contribution write, and a local-only (not server-recorded)
/// re-rank on "This card wasn't accepted".
///
/// Ranking here is deliberately independent of Home's
/// `selectedCategoryProvider`/`enteredAmountProvider` — this screen's
/// merchant/category/amount context comes from the scanned QR and is
/// editable per-scan, same reasoning ui-spec gives B7 for its own
/// independent inputs (see rankedRecommendationsProvider's doc comment in
/// app/providers.dart for the Home-scoped equivalent this deliberately does
/// NOT reuse).
class ScanResultScreen extends ConsumerStatefulWidget {
  final ParsedUpiQr parsed;
  const ScanResultScreen({super.key, required this.parsed});

  @override
  ConsumerState<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends ConsumerState<ScanResultScreen> {
  late final TextEditingController _merchantController;
  late final TextEditingController _amountController;
  late Money _amount;
  String? _selectedCategoryId;
  // "Wasn't accepted" — session-local only re-rank, see scope note above.
  // No acceptance-data write endpoint exists in api/src/index.js today
  // (same gap noted for Home's backup-card row), so tapping this only
  // excludes the card from the in-memory ranked list for the rest of this
  // scan session, never persisted.
  final Set<String> _locallyRejectedCardIds = {};

  @override
  void initState() {
    super.initState();
    _merchantController = TextEditingController(text: widget.parsed.pn ?? '');
    _amount = widget.parsed.am ?? const Money.zero();
    _amountController = TextEditingController(text: _amount.rupees == 0 ? '' : _amount.rupees.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    final categories = ref.watch(categoriesProvider);
    final userCards = ref.watch(userCardsProvider);
    final overrides = ref.watch(cardOverridesProvider);
    final engine = ref.watch(recommendationEngineProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan result'),
        actions: [
          IconButton(
            tooltip: 'Compare all cards',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
          ),
        ],
      ),
      body: _buildBody(catalogue, categories, userCards, overrides, engine),
    );
  }

  Widget _buildBody(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<SpendCategory>> categories,
    AsyncValue<List<UserCard>> userCards,
    AsyncValue<List<CardOverride>> overrides,
    RecommendationEngine engine,
  ) {
    // ui-spec B3.4 P2P edge case: never shown a card list — credit cards
    // can't settle a personal transfer. Checked before the catalogue/
    // categories/wallet/override loading-and-error gate below on purpose:
    // a P2P notice needs none of that data, so it renders immediately from
    // the already-available ParsedUpiQr rather than waiting on (or failing
    // behind) API calls this screen doesn't actually need in that case.
    if (widget.parsed.isLikelyP2P) {
      return _P2PNotice(vpa: widget.parsed.pa);
    }

    if (catalogue.isLoading || categories.isLoading || userCards.isLoading || overrides.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final combinedError = catalogue.error ?? categories.error ?? userCards.error ?? overrides.error;
    if (combinedError != null) {
      return ErrorState(message: userFacingErrorMessage(combinedError));
    }

    final allCards = catalogue.requireValue;
    final categoryList = categories.requireValue;
    final wallet = userCards.requireValue;
    final overrideList = overrides.requireValue;

    final cards = wallet.isEmpty ? allCards : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

    // Same reasoning as rankedRecommendationsProvider's own override
    // resolution (app/providers.dart), but with this screen's own vpa/
    // category context rather than Home's — a user who already set a vpa
    // override for this exact merchant sees it reflected here too, not
    // just on Home.
    final overrideProductId = resolveActiveOverrideCardProductId(
      overrides: overrideList,
      wallet: wallet,
      categoryId: _selectedCategoryId,
      vpa: widget.parsed.pa,
    );

    final upiContext = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      rail: TxnRail.upiQr,
    );
    final swipeContext = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      rail: TxnRail.swipe,
    );

    final snapshots = cards.where((c) => !_locallyRejectedCardIds.contains(c.id)).map((c) {
      final owned = wallet.where((w) => w.cardProductId == c.id).firstOrNull;
      final capRemaining = owned == null
          ? const <String, Money>{}
          : {
              for (final cap in c.capRules)
                if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!,
            };
      return CardSnapshot(
        product: c,
        capRemaining: capRemaining,
        milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
        forcedOverrideCardId: overrideProductId,
      );
    }).toList();

    final upiRanked = engine.rank(upiContext, snapshots);
    final swipeRanked = engine.rank(swipeContext, snapshots);
    final bestUpi = upiRanked.where((r) => !r.isExcluded).firstOrNull;
    final bestSwipe = swipeRanked.where((r) => !r.isExcluded).firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        TextField(
          controller: _merchantController,
          decoration: const InputDecoration(labelText: 'Merchant name'),
          // No onChanged/setState needed: _payWith reads _merchantController.text
          // directly at tap time, not from a build-time-captured value, so
          // typing here doesn't need to trigger a rebuild of anything else.
        ),
        const SizedBox(height: AppSpace.sm),
        // ui-spec B3.2 edge case: no `mc` on the QR -> no category could be
        // inferred, so the user picks one from the same chip set Home uses.
        // No VPA->merchant crowdsource lookup here — see this file's header
        // comment / plan-doc scope-reduction note.
        _CategoryPicker(
          categories: categoryList,
          selectedId: _selectedCategoryId,
          onSelected: (id) => setState(() => _selectedCategoryId = id),
        ),
        const SizedBox(height: AppSpace.sm),
        TextField(
          decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          controller: _amountController,
          onChanged: (v) {
            final parsedAmount = double.tryParse(v);
            if (parsedAmount != null && parsedAmount >= 0) setState(() => _amount = Money.fromRupees(parsedAmount));
          },
        ),
        const SizedBox(height: AppSpace.lg),
        // ui-spec B3.5: UPI-vs-swipe comparison nudge — only shown when
        // swiping would actually earn strictly more than the best UPI
        // option, so it never nags when scan-and-pay is already optimal.
        if (bestUpi != null && bestSwipe != null && bestSwipe.expectedValue > bestUpi.expectedValue)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Text(
              'Scan-and-pay earns ${bestUpi.expectedValue.format()} · swiping your ${bestSwipe.card.name} '
              'earns ${bestSwipe.expectedValue.format()} instead.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (upiRanked.isEmpty)
          const EmptyState(
            icon: Icons.credit_card_off_rounded,
            title: 'No cards yet',
            message: 'Add a card to see personalized reward recommendations here.',
          )
        else
          // A plain ListView(children:) over a stateless per-row widget —
          // _ScanResultCard holds no internal state (no "why this card"
          // expansion, unlike Home's _RecommendationCard), so there is no
          // per-item Element state that a reorder (amount edit, category
          // change, "wasn't accepted") could lose or misattribute. The
          // stable-Key lesson from Home's ranked list therefore doesn't
          // apply here — see this class's test file for a reorder+rebuild
          // regression check confirming rows always show data matching
          // their current rank, not stale carried-over content.
          for (final rec in upiRanked)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _ScanResultCard(
                recommendation: rec,
                onNotAccepted: () => setState(() => _locallyRejectedCardIds.add(rec.card.id)),
                onPay: () => _payWith(rec),
                onAlwaysUseHere: () => _createOverride(rec, wallet),
              ),
            ),
      ],
    );
  }

  Future<void> _payWith(Recommendation rec) async {
    final uri = Uri.parse(buildUpiPayUri(pa: widget.parsed.pa, pn: _merchantController.text, am: _amount));
    final launched = await canLaunchUrl(uri) && await launchUrl(uri);
    if (!launched && mounted) {
      // ui-spec B3 edge case: no UPI app installed -> recommendation-only
      // with a copy-VPA action.
      await Clipboard.setData(ClipboardData(text: widget.parsed.pa));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No UPI app found — copied ${widget.parsed.pa} to your clipboard instead.')),
      );
    }
  }

  Future<void> _createOverride(Recommendation rec, List<UserCard> wallet) async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    final owned = wallet.where((w) => w.cardProductId == rec.card.id).firstOrNull;
    if (repo == null || owned == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in and add this card to your wallet to create an override.')),
      );
      return;
    }
    try {
      // B8 scope: vpa, from the scanned QR — the most specific override
      // scope (see override_resolver.dart's priority doc comment), matching
      // "Always use this card here" meaning "at this exact payee", not this
      // merchant's name (which can vary) or this whole category.
      await repo.createOverride(userCardId: owned.id, scope: OverrideScope.vpa, vpa: widget.parsed.pa);
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rec.card.name} will always be suggested here.')));
      }
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
    }
  }
}

class _CategoryPicker extends StatelessWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  const _CategoryPicker({required this.categories, required this.selectedId, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.xs,
      children: [
        for (final c in categories)
          ChoiceChip(
            label: Text(c.name),
            selected: selectedId == c.id,
            onSelected: (_) => onSelected(c.id),
          ),
      ],
    );
  }
}

class _P2PNotice extends StatelessWidget {
  final String vpa;
  const _P2PNotice({required this.vpa});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.person_off_rounded,
      title: "Credit cards can't be used for personal transfers",
      message: 'This looks like a personal UPI transfer to $vpa, not a merchant payment. '
          "Use your bank account's UPI app to send this instead.",
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final Recommendation recommendation;
  final VoidCallback onNotAccepted;
  final VoidCallback onPay;
  final VoidCallback onAlwaysUseHere;

  const _ScanResultCard({
    required this.recommendation,
    required this.onNotAccepted,
    required this.onPay,
    required this.onAlwaysUseHere,
  });

  @override
  Widget build(BuildContext context) {
    final excluded = recommendation.isExcluded;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: excluded ? AppColors.surfaceMuted : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(recommendation.card.name, style: textTheme.titleMedium)),
              if (recommendation.isOverride)
                const StatusPill(label: 'Override', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          if (excluded)
            // ui-spec B3.4: RuPay/UPI eligibility, explicit — the engine's
            // own exclusionReason string (e.g. "Not usable via UPI — swipe
            // this instead.") is shown verbatim, never re-worded
            // client-side. This is the SAME exclusion gate the engine
            // applies everywhere else (RecommendationEngine._evaluate's
            // TxnRail.upiQr / !isUpiLinkable check) — B3 doesn't reinvent
            // its own RuPay/UPI eligibility logic.
            Row(
              children: [
                const Icon(Icons.block_rounded, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(child: Text(recommendation.exclusionReason!, style: textTheme.bodySmall)),
              ],
            )
          else ...[
            MoneyText(recommendation.expectedValue, confidence: recommendation.confidence, style: textTheme.headlineSmall),
            for (final line in recommendation.reasonLines)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text('•  $line', style: textTheme.bodySmall)),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                FilledButton(onPressed: onPay, child: Text('Pay with ${recommendation.card.name}')),
                OutlinedButton(onPressed: onAlwaysUseHere, child: const Text('Always use this card here')),
                TextButton(onPressed: onNotAccepted, child: const Text("Wasn't accepted")),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
