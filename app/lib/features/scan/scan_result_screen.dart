import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer;
import '../../data/merchant_search_repository.dart'
    show MerchantResolution, safeMerchantMccForUpiHandoff;
import '../../data/override_resolver.dart';
import '../../data/scanned_merchant_category.dart';
import '../../data/upi_payment_service.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../cards/card_visual.dart';
import '../cards/card_picker_screen.dart';
import '../comparison/comparison_view_screen.dart';
import 'payment_sent_screen.dart';
import 'upi_app_picker_sheet.dart';

/// ui-spec B3. Merchant identity/category resolution is best-effort and
/// exact-VPA based: published directory data may enrich a QR before payment,
/// while the local MCC/name classifier remains the offline fallback. There is
/// no silent background contribution write, and "This card wasn't accepted"
/// remains a local-only (not server-recorded) re-rank.
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
  final FocusNode _amountFocusNode = FocusNode();
  final GlobalKey _amountFieldKey = GlobalKey();
  String? _selectedCategoryId;
  // Set when the user taps Pay with no amount — shows in red on the on-card
  // amount field, per feedback that a modal / detached field was confusing.
  String? _amountError;

  /// The single source of truth for the amount, derived straight from the
  /// on-card field's controller. Kept as a getter (not a mirrored `Money`
  /// field) so the figure the engine ranks on can never drift from the text
  /// the user sees — an earlier bug where a stale `_amount` left the reward
  /// stuck on "enter an amount" while the field showed a number.
  Money get _amount {
    final parsed = double.tryParse(_amountController.text.trim());
    return (parsed != null && parsed > 0)
        ? Money.fromRupees(parsed)
        : const Money.zero();
  }

  // "Wasn't accepted" — session-local only re-rank, see scope note above.
  // This is deliberate, not a missing wire-up: POST /acceptance-reports and
  // AcceptanceReportsRepository DO exist and ARE used (payment_sent_screen.dart),
  // but that screen's own doc-comment explains why it's the only honest place
  // to ask — it fires right after the user confirms a payment actually went
  // through, a fresh, high-confidence, first-hand signal. This button fires
  // BEFORE any payment attempt, as a lower-confidence "skip this card, I
  // don't want to try it here" action; writing it to the same shared
  // crowdsourced acceptance dataset would mix pre-attempt guesses in with
  // real post-payment confirmations. So it only excludes the card from the
  // in-memory ranked list for the rest of this scan session, never persisted.
  final Set<String> _locallyRejectedCardIds = {};

  @override
  void initState() {
    super.initState();
    _merchantController = TextEditingController(
      text: isGenericUpiProviderLabel(widget.parsed.pn)
          ? ''
          : (widget.parsed.pn ?? ''),
    );
    final scannedAmount = widget.parsed.am;
    _amountController = TextEditingController(
      text: (scannedAmount != null && scannedAmount.rupees > 0)
          ? scannedAmount.rupees.toStringAsFixed(0)
          : '',
    );
    // Rebuild the ranked list (and clear the red flag) as the user types.
    _amountController.addListener(_onAmountControllerChanged);
    _merchantController.addListener(_onMerchantControllerChanged);
  }

  void _onAmountControllerChanged() {
    setState(() {
      if (_amountError != null && _amount.rupees >= 1) _amountError = null;
    });
  }

  void _onMerchantControllerChanged() {
    // A typed merchant name is part of the scan context. Re-run the local
    // classifier while the user edits it, but never overwrite an explicit
    // category choice they already made.
    if (!mounted || _selectedCategoryId != null) return;
    setState(() {});
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _merchantController.removeListener(_onMerchantControllerChanged);
    _amountController.removeListener(_onAmountControllerChanged);
    _amountController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    final categories = ref.watch(categoriesProvider);
    final userCards = ref.watch(userCardsProvider);
    final overrides = ref.watch(cardOverridesProvider);
    final engine = ref.watch(recommendationEngineProvider);
    final merchantResolution = ref.watch(
      merchantResolutionProvider(widget.parsed.pa),
    );

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Scan result',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        actions: [
          IconButton(
            tooltip: 'Compare all cards',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ComparisonViewScreen()),
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: _buildBody(
          catalogue,
          categories,
          userCards,
          overrides,
          engine,
          merchantResolution,
        ),
      ),
    );
  }

  Widget _buildBody(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<SpendCategory>> categories,
    AsyncValue<List<UserCard>> userCards,
    AsyncValue<List<CardOverride>> overrides,
    RecommendationEngine engine,
    AsyncValue<MerchantResolution?> merchantResolution,
  ) {
    // ui-spec B3.4 P2P edge case. A QR with no merchant category code looks
    // like a personal transfer — but many small shops that only accept
    // scan-to-pay use exactly such a QR, and a RuPay credit card on UPI can
    // legitimately pay a *business* there. So: if the wallet holds a
    // UPI-linkable RuPay card, fall through to a filtered list (with a
    // "confirm this is a business" gate on Pay — see _payWith); otherwise
    // keep the plain personal-transfer notice.
    //
    // The notice fast-path stays for the no-wallet / still-loading case so
    // it renders without waiting on API calls it doesn't need.
    final resolvedMerchant = merchantResolution.valueOrNull;
    // A trusted exact-VPA directory result may correct/enrich a broad MCC
    // embedded in the QR (for example, a provider QR carrying 5999 while the
    // directory knows the merchant is groceries). Keep widget.parsed.mc as
    // the raw QR value, but use the verified value for ranking/classification.
    final effectiveMcc = resolvedMerchant?.mcc ?? widget.parsed.mc;
    final noMcc =
        widget.parsed.isLikelyP2P &&
        (resolvedMerchant == null || resolvedMerchant.isP2p);
    final walletPeek = userCards.valueOrNull;
    if (noMcc &&
        (walletPeek == null || walletPeek.isEmpty) &&
        !merchantResolution.isLoading) {
      return _P2PNotice(vpa: widget.parsed.pa);
    }

    if (catalogue.isLoading ||
        categories.isLoading ||
        userCards.isLoading ||
        overrides.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final combinedError =
        catalogue.error ??
        categories.error ??
        userCards.error ??
        overrides.error;
    if (combinedError != null) {
      return ErrorState(message: userFacingErrorMessage(combinedError));
    }

    final allCards = catalogue.requireValue;
    final categoryList = categories.requireValue;
    final wallet = userCards.requireValue;
    final overrideList = overrides.requireValue;
    final typedMerchantName = _merchantController.text.trim();
    final effectiveMerchantName = typedMerchantName.isEmpty
        ? resolvedMerchant?.displayName
        : typedMerchantName;
    final resolvedCategoryId = categoryList
        .where(
          (c) =>
              c.id == resolvedMerchant?.categoryId ||
              c.slug == resolvedMerchant?.categorySlug,
        )
        .firstOrNull
        ?.id;
    final inferredCategoryId =
        resolvedCategoryId ??
        categoryIdForScannedMerchant(
          merchantName: effectiveMerchantName ?? '',
          vpa: widget.parsed.pa,
          mcc: effectiveMcc,
          categories: categoryList,
        );
    final activeCategoryId = _selectedCategoryId ?? inferredCategoryId;

    // Keep the local fallback available if a directory record has no mapped
    // category yet. A published merchant name/MCC is still useful for ranking
    // and for showing the verified merchant identity.
    final localInferredCategoryId = categoryIdForScannedMerchant(
      merchantName: effectiveMerchantName ?? '',
      vpa: widget.parsed.pa,
      mcc: effectiveMcc,
      categories: categoryList,
    );
    final selectedCategoryForRanking = categoryIdForServer(
      activeCategoryId ?? localInferredCategoryId,
    );

    // ui-spec B1 says "No cards → CTA to add one". B3 has no rule of its own,
    // so: with an empty wallet still rank the whole catalogue (a useful
    // "best card for this merchant" signal), but every row is then a
    // not-owned card — _ScanResultCard swaps its "Pay with" action for
    // "Add this card" so we never offer a hand-off the user can't complete.
    final walletEmpty = wallet.isEmpty;
    var cards = walletEmpty
        ? allCards
        : allCards
              .where((c) => wallet.any((w) => w.cardProductId == c.id))
              .toList();

    // No merchant code on the QR: the only card that can pay here is one
    // linkable to UPI (today, per NPCI, that's RuPay credit cards — but the
    // rule lives in the catalogue's `is_upi_linkable` flag, not here, so it
    // stays a data change if that ever widens), and only at a business.
    // Filter to those; if the user owns none, show nothing but the notice.
    if (noMcc) {
      cards = cards.where((c) => c.isUpiLinkable).toList();
      if (cards.isEmpty) return _P2PNotice(vpa: widget.parsed.pa);
    }

    // Same reasoning as rankedRecommendationsProvider's own override
    // resolution (app/providers.dart), but with this screen's own vpa/
    // category context rather than Home's — a user who already set a vpa
    // override for this exact merchant sees it reflected here too, not
    // just on Home.
    final overrideProductId = resolveActiveOverrideCardProductId(
      overrides: overrideList,
      wallet: wallet,
      categoryId: selectedCategoryForRanking,
      vpa: widget.parsed.pa,
    );

    // This is the one ranking path in the app that genuinely knows the
    // merchant — a scanned UPI QR carries the payee name — so it is the
    // path where merchant-restricted rules ("10% at Amazon only") can
    // actually be honoured rather than falling through to the base rate.
    final now = DateTime.now();
    final selectedCategorySlug = categoryList
        .where((c) => c.id == selectedCategoryForRanking)
        .firstOrNull
        ?.slug;
    final upiContext = RecommendationContext(
      amount: _amount,
      categoryId: selectedCategoryForRanking,
      categorySlug: selectedCategorySlug,
      mcc: effectiveMcc,
      vpa: widget.parsed.pa,
      merchantName: effectiveMerchantName,
      rail: TxnRail.upiQr,
      now: now,
    );
    final swipeContext = RecommendationContext(
      amount: _amount,
      categoryId: selectedCategoryForRanking,
      categorySlug: selectedCategorySlug,
      mcc: effectiveMcc,
      vpa: widget.parsed.pa,
      merchantName: effectiveMerchantName,
      rail: TxnRail.swipe,
      now: now,
    );

    final snapshots = cards
        .where((c) => !_locallyRejectedCardIds.contains(c.id))
        .map((c) {
          final owned = wallet
              .where((w) => w.cardProductId == c.id)
              .firstOrNull;
          final capRemaining = owned == null
              ? const <String, Money>{}
              : {
                  for (final cap in uniqueCapRules(c.capRules))
                    if (owned.capConsumed.containsKey(cap.id))
                      cap.id: cap.capValue - owned.capConsumed[cap.id]!,
                };
          return CardSnapshot(
            product: c,
            capRemaining: capRemaining,
            milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
            forcedOverrideCardId: overrideProductId,
          );
        })
        .toList();

    final upiRanked = engine.rank(upiContext, snapshots);
    final swipeRanked = engine.rank(swipeContext, snapshots);
    final bestUpi = upiRanked.where((r) => !r.isExcluded).firstOrNull;
    final bestSwipe = swipeRanked.where((r) => !r.isExcluded).firstOrNull;

    // The amount is entered inline on the card the user actually pays with —
    // the best owned, eligible card — not in a field detached from it. Null
    // when the wallet is empty (nothing to pay yet; add a card first).
    final amountEntryCardId =
        (bestUpi != null &&
            wallet.any((w) => w.cardProductId == bestUpi.card.id))
        ? bestUpi.card.id
        : null;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (noMcc) ...[
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    "This QR has no merchant code. Only a RuPay credit card on UPI can pay "
                    "here, and only for a payment to a business — you'll confirm that before paying.",
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
        ],
        TextField(
          controller: _merchantController,
          style: BambooFonts.ui(15, color: BambooInk.ink900),
          decoration: InputDecoration(
            labelText: 'Merchant name (optional)',
            labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
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
            hintText: 'Use the shop name if the QR did not include one',
            helperText: 'The selected UPI app will verify ${widget.parsed.pa}',
            helperStyle: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          // No onChanged/setState needed: _payWith reads _merchantController.text
          // directly at tap time, not from a build-time-captured value, so
          // typing here doesn't need to trigger a rebuild of anything else.
        ),
        if (resolvedMerchant != null) ...[
          const SizedBox(height: AppSpace.xs),
          Row(
            children: [
              const Icon(
                Icons.verified_rounded,
                size: 16,
                color: BambooInk.jade,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Verified merchant: ${resolvedMerchant.displayName ?? widget.parsed.pa}'
                  '${resolvedMerchant.categoryName == null ? '' : ' · ${resolvedMerchant.categoryName}'}',
                  style: BambooFonts.ui(11.5, color: BambooInk.jade),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpace.sm),
        // MCC is the strongest signal. When it is absent, the same resolver
        // uses the QR merchant name and then a meaningful VPA prefix. The
        // picker remains available as an explicit merchant-context override.
        // The settled SMS/server resolver still validates the final transaction.
        _CategoryPicker(
          categories: categoryList,
          selectedId: activeCategoryId,
          onSelected: (id) => setState(() => _selectedCategoryId = id),
        ),
        const SizedBox(height: AppSpace.lg),
        if (walletEmpty && !noMcc)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'These are the best options from the full catalogue. Add your own cards '
                    'to pay from your wallet.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
        // ui-spec B3.5: UPI-vs-swipe comparison nudge — only shown when
        // swiping would actually earn strictly more than the best UPI
        // option, so it never nags when scan-and-pay is already optimal.
        if (bestUpi != null &&
            bestSwipe != null &&
            bestSwipe.expectedValue > bestUpi.expectedValue)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'Scan-and-pay earns ${bestUpi.expectedValue.format()} · swiping your ${bestSwipe.card.name} '
              'earns ${bestSwipe.expectedValue.format()} instead.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
        if (upiRanked.isEmpty && _locallyRejectedCardIds.isNotEmpty)
          // Every card was marked "wasn't accepted" this scan — not the same
          // as owning none. Offer to bring them back rather than showing a
          // dead end.
          Column(
            children: [
              const EmptyState(
                icon: Icons.block_rounded,
                title: 'No other cards to try',
                message:
                    "You've marked every card as not accepted at this merchant.",
              ),
              const SizedBox(height: AppSpace.md),
              OutlinedButton.icon(
                onPressed: () => setState(_locallyRejectedCardIds.clear),
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('Show them again'),
              ),
            ],
          )
        else if (upiRanked.isEmpty)
          const EmptyState(
            icon: Icons.credit_card_off_rounded,
            title: 'No cards yet',
            message:
                'Add a card to see personalized reward recommendations here.',
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
                isHero: bestUpi != null && rec.card.id == bestUpi.card.id,
                isOwned: wallet.any((w) => w.cardProductId == rec.card.id),
                showRupayUpiNote: rec.card.isUpiLinkable,
                showAmountEntry: rec.card.id == amountEntryCardId,
                amountEntered: _amount.rupees >= 1,
                amountController: _amountController,
                amountFocusNode: _amountFocusNode,
                amountFieldKey: _amountFieldKey,
                amountError: _amountError,
                onNotAccepted: () =>
                    setState(() => _locallyRejectedCardIds.add(rec.card.id)),
                onPay: () => _payWith(rec, wallet, activeCategoryId),
                onAlwaysUseHere: () => _createOverride(rec, wallet),
                onAddCard: () => _addCard(rec.card),
              ),
            ),
      ],
    );
  }

  Future<void> _payWith(
    Recommendation rec,
    List<UserCard> wallet,
    String? categoryId,
  ) async {
    // A UPI payment needs a real amount. Merchant QRs usually don't carry one
    // (`am` absent), and handing ₹0 to the UPI app just bounces straight back
    // ("minimum amount of ₹1 is required"). Flag the Amount field inline and
    // focus it rather than popping a modal — the user fills it and taps Pay
    // again.
    if (_amount.rupees < 1) {
      setState(() => _amountError = 'Enter an amount to pay');
      _amountFocusNode.requestFocus();
      final fieldContext = _amountFieldKey.currentContext;
      if (fieldContext != null) {
        await Scrollable.ensureVisible(
          fieldContext,
          alignment: 0.35,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      return;
    }

    // No merchant code on the QR: RuPay-credit-on-UPI is merchant-only, so
    // make the user affirm this is a business payment before handing off.
    if (widget.parsed.isLikelyP2P) {
      final payee = _merchantController.text.trim();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Is this a business payment?'),
          content: Text(
            'A RuPay credit card on UPI can only pay a business — not send money to a '
            'person. Continue only if ${payee.isEmpty ? 'this payee' : payee} is a shop or merchant.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, continue'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final service = ref.read(upiPaymentServiceProvider);
    // A static merchant QR can omit its acquiring-bank MCC. NPCI has
    // documented that PSPs may then classify it as P2P, which can cause
    // merchant payments to be declined. Use an exact-VPA directory MCC only
    // when explicitly operator-verified. Never infer it from a user-entered
    // category/name, and never alter a signed QR payload.
    final resolvedMerchant = await ref
        .read(merchantResolutionProvider(widget.parsed.pa).future)
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    if (!mounted) return;
    final handoffMcc = safeMerchantMccForUpiHandoff(
      qrMcc: widget.parsed.mc,
      qrHasSignature: widget.parsed.sign != null,
      resolution: resolvedMerchant,
    );

    final uriString = buildUpiPayUri(
      pa: widget.parsed.pa,
      // Preserve the QR's original payee name for the PSP handoff. PandaPay
      // may show a richer locally detected merchant name in its own UI, but
      // must not replace the QR's payee field before PSP validation.
      pn: widget.parsed.pn,
      am: _amount,
      cu: widget.parsed.cu,
      // Preserve QR transaction fields. The MCC may also be filled from an
      // sufficiently trusted exact-VPA record when the QR omitted it;
      // never invent a transaction reference for a static QR.
      mc: handoffMcc,
      tr: widget.parsed.tr,
      tn: widget.parsed.tn,
      mode: widget.parsed.mode,
      orgid: widget.parsed.orgid,
      sign: widget.parsed.sign,
      extraParams: widget.parsed.extraParams,
    );

    final apps = await service.installedApps();
    if (!mounted) return;

    // iOS, or Android with nothing enumerable — fall back to the plain
    // scheme launch (OS picks the app, no status comes back).
    if (apps.isEmpty) {
      await _legacyLaunch(rec, wallet, categoryId, uriString);
      return;
    }

    final chosen = await UpiAppPickerSheet.show(
      context,
      apps: apps,
      cardName: rec.card.name,
    );
    if (chosen == null || !mounted) return;

    // The channel completes on the UPI app's Activity result. If Android
    // recreated our Activity while the user was in the UPI app (low RAM), or
    // they never came back, that result is lost — cap the wait so the future
    // can't hang the screen forever, and fall to the manual-confirm path.
    final result = await service
        .pay(upiUri: uriString, packageName: chosen.packageName)
        .timeout(
          const Duration(minutes: 4),
          onTimeout: () =>
              const UpiPaymentResult(status: UpiPaymentStatus.submitted),
        );
    if (!mounted) return;

    switch (result.status) {
      case UpiPaymentStatus.success:
        // The UPI result is useful UX feedback, but the bank SMS is the
        // authoritative settled spend. Logging here first creates a manual
        // row which can race the SMS and count the same QR payment twice.
        await _openPaymentSent(
          rec: rec,
          wallet: wallet,
          categoryId: categoryIdForServer(categoryId),
          autoLog: false,
        );
        break;
      case UpiPaymentStatus.submitted:
        // The honest default: the app returned with no conclusive status.
        await _openPaymentSent(
          rec: rec,
          wallet: wallet,
          categoryId: categoryIdForServer(categoryId),
          autoLog: false,
        );
        break;
      case UpiPaymentStatus.failure:
        final responseCode = _upiResponseField(
          result.rawResponse,
          'responsecode',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The receiver bank declined this payment${responseCode == null ? '' : ' (code $responseCode)'}. Try another UPI app or bank account; no spend was logged in PandaPay.',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        break;
      case UpiPaymentStatus.cancelled:
        break; // user backed out of the UPI app — nothing to report
      case UpiPaymentStatus.noAppsAvailable:
        await _legacyLaunch(rec, wallet, categoryId, uriString);
        break;
    }
  }

  /// Pre-channel behaviour: hand the `upi://` link to the OS and hope. Used
  /// on iOS and whenever no UPI app can be enumerated.
  Future<void> _legacyLaunch(
    Recommendation rec,
    List<UserCard> wallet,
    String? categoryId,
    String uriString,
  ) async {
    final uri = Uri.parse(uriString);
    final launched =
        await canLaunchUrl(uri) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!launched) {
      // ui-spec B3 edge case: no UPI app installed -> recommendation-only
      // with a copy-VPA action.
      await Clipboard.setData(ClipboardData(text: widget.parsed.pa));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No UPI app found — copied ${widget.parsed.pa} to your clipboard instead.',
          ),
        ),
      );
      return;
    }
    await _openPaymentSent(
      rec: rec,
      wallet: wallet,
      categoryId: categoryIdForServer(categoryId),
      autoLog: false,
    );
  }

  Future<void> _openPaymentSent({
    required Recommendation rec,
    required List<UserCard> wallet,
    required String? categoryId,
    required bool autoLog,
  }) async {
    if (!mounted) return;
    final owned = wallet
        .where((w) => w.cardProductId == rec.card.id)
        .firstOrNull;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PaymentSentScreen(
          merchantName: _merchantController.text.trim().isNotEmpty
              ? _merchantController.text.trim()
              : (ref
                        .read(merchantResolutionProvider(widget.parsed.pa))
                        .valueOrNull
                        ?.displayName ??
                    ''),
          amount: _amount,
          cardName: rec.card.name,
          userCardId: owned?.id,
          categoryId: categoryIdForServer(categoryId),
          merchantVpa: widget.parsed.pa,
          mcc:
              widget.parsed.mc ??
              ref
                  .read(merchantResolutionProvider(widget.parsed.pa))
                  .valueOrNull
                  ?.mcc,
          expectedValue: rec.expectedValue,
          confidence: rec.confidence,
          // Plan Phase 2.1: both needed for the acceptance report that
          // screen asks for once the user confirms they finished paying.
          vpa: widget.parsed.pa,
          cardNetwork: rec.card.network,
          // Android returned a definite success — log the spend straight away
          // rather than asking the user to confirm what the app already told
          // us (RuPay-on-UPI plan, Phase 2).
          autoLog: autoLog,
        ),
      ),
    );
  }

  Future<void> _createOverride(
    Recommendation rec,
    List<UserCard> wallet,
  ) async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    final owned = wallet
        .where((w) => w.cardProductId == rec.card.id)
        .firstOrNull;
    if (repo == null || owned == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sign in and add this card to your wallet to create an override.',
          ),
        ),
      );
      return;
    }
    try {
      // B8 scope: vpa, from the scanned QR — the most specific override
      // scope (see override_resolver.dart's priority doc comment), matching
      // "Always use this card here" meaning "at this exact payee", not this
      // merchant's name (which can vary) or this whole category.
      await repo.createOverride(
        userCardId: owned.id,
        scope: OverrideScope.vpa,
        vpa: widget.parsed.pa,
      );
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${rec.card.name} will always be suggested here.'),
          ),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }

  /// "Add this card" on a not-owned suggestion (empty wallet). Opens the same
  /// picker the Wallet tab uses, pre-filtered to this card, then adds the
  /// pick to the wallet (server if signed in, local DB as a guest) so the
  /// row flips to a real "Pay with" on the next rebuild.
  Future<void> _addCard(CardProduct card) async {
    final picked = await Navigator.of(context).push<List<CardProduct>>(
      MaterialPageRoute(
        builder: (_) => CardPickerScreen(initialSearch: card.name),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final repo = ref.read(userCardsRepositoryProvider);
    try {
      if (repo != null) {
        for (final c in picked) {
          await repo.addCard(c.id);
        }
      } else {
        final local = await ref.read(localUserCardsRepositoryProvider.future);
        for (final c in picked) {
          await local.addCard(c.id);
        }
      }
      ref.invalidate(userCardsProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Added — now suggesting from your wallet.'),
          ),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }
}

String? _upiResponseField(String? raw, String wantedKey) {
  if (raw == null || raw.isEmpty) return null;
  for (final part in raw.split('&')) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    if (part.substring(0, separator).trim().toLowerCase() == wantedKey) {
      final value = part.substring(separator + 1).trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

class _CategoryPicker extends ConsumerWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CategoryPickerField(
      categories: categories,
      selectedId: selectedId,
      onSelected: onSelected,
      label: 'Purchase type',
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
      message:
          'This looks like a personal UPI transfer to $vpa, not a merchant payment. '
          "Use your bank account's UPI app to send this instead.",
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final Recommendation recommendation;
  final bool isHero;
  final bool isOwned;
  final bool showRupayUpiNote;

  /// This is the card the user pays with, so the amount is entered right
  /// here — in place of the reward figure — not in a field elsewhere.
  final bool showAmountEntry;

  /// Whether a payable amount (≥ ₹1) has been entered yet — drives the
  /// "enter an amount" prompt vs. the resolved reward, independent of
  /// whether *this* card happens to earn anything on the spend.
  final bool amountEntered;
  final TextEditingController? amountController;
  final FocusNode? amountFocusNode;
  final GlobalKey? amountFieldKey;
  final String? amountError;

  final VoidCallback onNotAccepted;
  final VoidCallback onPay;
  final VoidCallback onAlwaysUseHere;
  final VoidCallback onAddCard;

  const _ScanResultCard({
    required this.recommendation,
    required this.isHero,
    required this.isOwned,
    required this.showRupayUpiNote,
    this.showAmountEntry = false,
    this.amountEntered = false,
    this.amountController,
    this.amountFocusNode,
    this.amountFieldKey,
    this.amountError,
    required this.onNotAccepted,
    required this.onPay,
    required this.onAlwaysUseHere,
    required this.onAddCard,
  });

  @override
  Widget build(BuildContext context) {
    final excluded = recommendation.isExcluded;
    final hero = isHero && !excluded;
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: hero
            ? BambooInk.lime
            : (excluded ? BambooInk.paperMuted : BambooInk.glassFillOnPaper),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: hero ? BambooInk.lime : BambooInk.hairlineOnPaper,
          width: hero ? 2 : 1,
        ),
        boxShadow: hero
            ? [
                BoxShadow(
                  color: BambooInk.lime.withValues(alpha: 0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: CardVisual(
              product: recommendation.card,
              height: hero ? 142 : 116,
              showProductName: false,
            ),
          ),
          Row(
            children: [
              if (hero) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: BambooInk.slate,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'BEST PICK',
                    style: BambooFonts.ui(
                      10.5,
                      weight: FontWeight.w700,
                      color: BambooInk.lime,
                    ).copyWith(letterSpacing: 0.6),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  recommendation.card.name,
                  style: BambooFonts.heading(
                    16,
                    color: excluded ? BambooInk.ink500 : BambooInk.ink900,
                  ),
                ),
              ),
              if (recommendation.isOverride)
                StatusPill(
                  label: 'Override',
                  foreground: hero ? BambooInk.slate : BambooInk.ink900,
                  background: hero
                      ? Colors.white.withValues(alpha: 0.5)
                      : BambooInk.paperMuted,
                ),
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
                const Icon(
                  Icons.block_rounded,
                  size: 16,
                  color: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    recommendation.exclusionReason!,
                    style: BambooFonts.ui(13, color: BambooInk.ink500),
                  ),
                ),
              ],
            )
          else ...[
            if (showRupayUpiNote)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.qr_code_2_rounded,
                      size: 14,
                      color: hero ? BambooInk.slate : BambooInk.ink500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'RuPay · UPI eligible',
                      style: BambooFonts.ui(
                        11.5,
                        weight: FontWeight.w600,
                        color: hero ? BambooInk.slate : BambooInk.ink500,
                      ),
                    ),
                  ],
                ),
              ),
            if (showAmountEntry) ...[
              _OnCardAmountField(
                controller: amountController!,
                focusNode: amountFocusNode!,
                fieldKey: amountFieldKey!,
                errorText: amountError,
                onSubmitted: (_) => onPay(),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            if (!showAmountEntry || amountEntered) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  MoneyText(
                    recommendation.expectedValue,
                    confidence: recommendation.confidence,
                    style: BambooFonts.money(
                      hero ? 34 : 22,
                      color: BambooInk.ink900,
                    ),
                  ),
                  if (recommendation.expectedValue.paise > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      'back',
                      style: BambooFonts.ui(13, color: BambooInk.ink500),
                    ),
                  ],
                ],
              ),
              for (final line in recommendation.reasonLines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '•  $line',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
            ] else
              Text(
                'Enter an amount to see your reward',
                style: BambooFonts.ui(
                  12.5,
                  color: hero ? BambooInk.slate : BambooInk.ink500,
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            if (!isOwned)
              // Empty wallet: this is a catalogue pick, not a card the user
              // holds — offer to add it rather than a "Pay with" that can't
              // complete (ui-spec B1's "No cards → add a card").
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "You don't have this card yet.",
                    style: BambooFonts.ui(
                      12.5,
                      color: hero ? BambooInk.slate : BambooInk.ink500,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.lime,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: onAddCard,
                    icon: const Icon(Icons.add_card_rounded, size: 18),
                    label: const Text('Add this card'),
                  ),
                ],
              )
            else
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.lime,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: onPay,
                    child: Text('Pay with ${recommendation.card.name}'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: hero
                          ? BambooInk.slate
                          : BambooInk.ink900,
                      side: BorderSide(
                        color: hero
                            ? BambooInk.slate.withValues(alpha: 0.4)
                            : BambooInk.hairlineOnPaper,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: onAlwaysUseHere,
                    child: const Text('Always use this card here'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: hero
                          ? BambooInk.slate
                          : BambooInk.ink500,
                    ),
                    onPressed: onNotAccepted,
                    child: const Text("Wasn't accepted"),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// The amount entry that sits on the hero card, where the reward figure
/// would be — a large `₹ ____` line, red when the user tapped Pay with it
/// empty. Sized for the lime card, so it paints its own light fill.
class _OnCardAmountField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey fieldKey;
  final String? errorText;
  final ValueChanged<String> onSubmitted;

  const _OnCardAmountField({
    required this.controller,
    required this.focusNode,
    required this.fieldKey,
    required this.errorText,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    return Column(
      key: fieldKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: BambooInk.paper,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasError
                  ? BambooInk.clay
                  : BambooInk.slate.withValues(alpha: 0.25),
              width: hasError ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Text('₹', style: BambooFonts.money(24, color: BambooInk.ink500)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: BambooFonts.money(26, color: BambooInk.ink900),
                  cursorColor: BambooInk.slate,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: InputBorder.none,
                    hintText: 'Amount',
                    hintStyle: BambooFonts.money(
                      24,
                      color: BambooInk.ink500.withValues(alpha: 0.5),
                    ),
                  ),
                  onSubmitted: onSubmitted,
                ),
              ),
            ],
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              errorText!,
              style: BambooFonts.ui(12, color: BambooInk.clay),
            ),
          ),
      ],
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
