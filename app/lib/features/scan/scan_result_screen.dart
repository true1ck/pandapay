import '../../app/async_first_load.dart';
import 'package:flutter/material.dart';
import '../../app/design/bamboo_components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/card_snapshots.dart';
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer;
import '../../data/merchant_context.dart';
import '../../data/merchant_search_repository.dart' show MerchantResolution;
import '../../data/override_resolver.dart';
import '../../data/scanned_merchant_category.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../cards/add_card_local_first.dart';
import '../overrides/override_local_first.dart';
import '../cards/recommendation_confidence.dart';
import '../cards/card_picker_screen.dart';
import '../comparison/comparison_view_screen.dart';
import 'payment_sent_screen.dart';
import 'upi_app_picker_sheet.dart';
import 'package:url_launcher/url_launcher.dart';

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
    // The merchant name the QR carries, as on the original scan-result page
    // (a provider QR says "Paytm"; the user can correct it).
    _merchantController = TextEditingController(text: widget.parsed.pn ?? '');
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
      return _P2PNotice(vpa: widget.parsed.pa, action: _amountAndWithoutCard());
    }

    if (catalogue.isFirstLoad ||
        categories.isFirstLoad ||
        userCards.isFirstLoad ||
        overrides.isFirstLoad) {
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
      categoryList,
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
      if (cards.isEmpty) {
        return _P2PNotice(
          vpa: widget.parsed.pa,
          action: _amountAndWithoutCard(),
        );
      }
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
    final now = ref.watch(clockProvider).now();
    final selectedCategorySlug = categoryList
        .where((c) => c.id == selectedCategoryForRanking)
        .firstOrNull
        ?.slug;
    // WP9: the payee resolves through the C5 directory (slug, and the
    // merchant's first listed MCC when neither the QR nor the directory
    // lookup supplied one).
    final directory = ref.watch(merchantDirectoryProvider);
    final upiContext = buildRecommendationContext(
      directory: directory,
      amount: _amount,
      categoryId: selectedCategoryForRanking,
      categorySlug: selectedCategorySlug,
      mcc: effectiveMcc,
      vpa: widget.parsed.pa,
      merchantName: effectiveMerchantName,
      rail: TxnRail.upiQr,
      now: now,
    );
    final swipeContext = buildRecommendationContext(
      directory: directory,
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
        .map(
          (c) => buildCardSnapshot(
            c,
            owned: wallet.where((w) => w.cardProductId == c.id).firstOrNull,
            now: now,
            forcedOverrideCardId: overrideProductId,
          ),
        )
        .toList();

    final upiRanked = engine.rank(upiContext, snapshots);
    final swipeRanked = engine.rank(swipeContext, snapshots);
    final bestUpi = upiRanked.where((r) => !r.isExcluded).firstOrNull;
    final bestSwipe = swipeRanked.where((r) => !r.isExcluded).firstOrNull;

    bool owns(CardProduct c) => wallet.any((w) => w.cardProductId == c.id);
    // An owned UPI-linkable card is payable even when it earns nothing here
    // (the engine excludes it for "no reward rule"), so it still gets Pay.
    bool payable(Recommendation r) => r.card.isUpiLinkable && owns(r.card);
    final heroCardId =
        bestUpi?.card.id ?? upiRanked.where(payable).firstOrNull?.card.id;

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
            labelText: 'Merchant name',
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
        const SizedBox(height: AppSpace.md),
        _amountAndWithoutCard(),
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
        if (upiRanked.isNotEmpty)
          _RecommendedHeader(
            onInfo: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Why these cards?'),
                content: const Text(
                  'Cards are ranked by what they earn on this payment. Only a RuPay '
                  'credit card linked to UPI can pay a QR, and only at a shop that '
                  'accepts credit cards. If yours is not accepted, use Continue '
                  'without card.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Got it'),
                  ),
                ],
              ),
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
          // The suggested card first, then the other cards that can pay, and the
          // cards that cannot be used here last.
          for (final rec in [
            ...upiRanked.where((r) => !r.isExcluded || payable(r)),
            ...upiRanked.where((r) => r.isExcluded && !payable(r)),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _ScanResultCard(
                recommendation: rec,
                isHero: rec.card.id == heroCardId,
                isOwned: wallet.any((w) => w.cardProductId == rec.card.id),
                showRupayUpiNote: rec.card.isUpiLinkable,
                payDespiteExclusion: rec.isExcluded && payable(rec),
                amountEntered: _amount.rupees >= 1,
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

  /// A UPI payment needs a real amount. Merchant QRs usually don't carry one
  /// (`am` absent), and handing ₹0 to the UPI app just bounces straight back
  /// ("minimum amount of ₹1 is required"). Flag the Amount field inline and
  /// focus it rather than popping a modal — the user fills it and taps Pay
  /// again. True when there is an amount to pay.
  Future<bool> _requireAmount() async {
    if (_amount.rupees >= 1) return true;
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
    return false;
  }

  Future<void> _payWith(
    Recommendation rec,
    List<UserCard> wallet,
    String? categoryId,
  ) async {
    if (!await _requireAmount() || !mounted) return;

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
              style: BambooButtons.primary,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, continue'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    await _handOff(rec: rec, wallet: wallet, categoryId: categoryId);
  }

  /// "Continue without credit card": the user pays from their own bank account
  /// in any UPI app. It is the way out when they hold no RuPay credit card, the
  /// shop doesn't accept credit cards, or the payee is a person, so a scan is
  /// never a dead end. Same steps as paying with a card: enter the amount, then
  /// pick the UPI app, which lets the user choose the account.
  Future<void> _continueWithoutCard() async {
    if (!await _requireAmount()) return;
    await _handOff(
      rec: null,
      wallet: const [],
      categoryId: _selectedCategoryId,
    );
  }

  /// Hands the payment to the UPI app the user picks. [rec] is the card being
  /// paid with, or null for a payment from a bank account.
  Future<void> _handOff({
    required Recommendation? rec,
    required List<UserCard> wallet,
    required String? categoryId,
  }) async {
    final payWith = rec?.card.name ?? 'your bank account';
    final service = ref.read(upiPaymentServiceProvider);
    final hasAmount = _amount.rupees >= 1;

    // Open the UPI app the user picks with the payee and amount already filled
    // in, as before. Some banks decline a payment another app starts; the user
    // then still has the shared-QR route below, or can pay in the UPI app.
    final apps = await service.installedApps();
    if (!mounted) return;

    final link = buildUpiPayUri(
      pa: widget.parsed.pa,
      pn: widget.parsed.pn,
      am: hasAmount ? _amount : null,
      cu: widget.parsed.cu,
      mc: widget.parsed.mc,
      tr: widget.parsed.tr,
      tn: widget.parsed.tn,
      mode: widget.parsed.mode,
      orgid: widget.parsed.orgid,
      sign: widget.parsed.sign,
      extraParams: widget.parsed.extraParams,
    );

    // iOS, or Android with nothing enumerable: hand the link to the system, as
    // before; with no UPI app at all, copy the UPI ID instead.
    if (apps.isEmpty) {
      final uri = Uri.parse(link);
      final launched =
          await canLaunchUrl(uri) &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!launched) {
        await Clipboard.setData(
          ClipboardData(text: widget.parsed.pa),
        ).catchError((_) {});
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
        categoryId: categoryId,
        autoLog: false,
      );
      return;
    }

    final chosen = await UpiAppPickerSheet.show(
      context,
      apps: apps,
      cardName: payWith,
    );
    if (chosen == null || !mounted) return;

    var opened = await service.launchUpiLink(
      packageName: chosen.packageName,
      uri: link,
    );
    if (!mounted) return;

    // The app could not take the link: try handing it the payment as a shared
    // QR, which UPI apps read like a QR saved in the gallery.
    if (!opened && widget.parsed.sign == null) {
      opened = await service.shareQr(
        packageName: chosen.packageName,
        qrData: link,
      );
      if (!mounted) return;
    }

    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't open ${chosen.name}. Try another UPI app.",
          ),
        ),
      );
      return;
    }

    // The bank SMS is the authoritative settled spend, so nothing is logged
    // here. The sent screen offers a manual log if no SMS arrives.
    await _openPaymentSent(
      rec: rec,
      wallet: wallet,
      categoryId: categoryId,
      autoLog: false,
    );
  }

  /// The amount card and the way out below it, as one block: used under the
  /// category chips, and in the notices where no card can pay.
  Widget _amountAndWithoutCard() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _AmountCard(
        controller: _amountController,
        focusNode: _amountFocusNode,
        fieldKey: _amountFieldKey,
        errorText: _amountError,
      ),
      const SizedBox(height: AppSpace.md),
      _WithoutCardBanner(onTap: _continueWithoutCard),
    ],
  );

  Future<void> _openPaymentSent({
    required Recommendation? rec,
    required List<UserCard> wallet,
    required String? categoryId,
    required bool autoLog,
  }) async {
    if (!mounted) return;
    final owned = rec == null
        ? null
        : wallet.where((w) => w.cardProductId == rec.card.id).firstOrNull;
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
          // An empty card name means a payment from a bank account.
          cardName: rec?.card.name ?? '',
          userCardId: owned?.id,
          categoryId: categoryId,
          merchantVpa: widget.parsed.pa,
          mcc:
              widget.parsed.mc ??
              ref
                  .read(merchantResolutionProvider(widget.parsed.pa))
                  .valueOrNull
                  ?.mcc,
          expectedValue: rec?.expectedValue ?? const Money.zero(),
          confidence: rec == null ? Confidence.estimated : confidenceOf(rec),
          // Plan Phase 2.1: both needed for the acceptance report that
          // screen asks for once the user confirms they finished paying.
          vpa: widget.parsed.pa,
          cardNetwork: rec?.card.network ?? CardNetwork.unknown,
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
      // Local-first (WP-C6): queued when the server is not reachable.
      await createOverrideLocalFirst(
        ref,
        card: owned,
        scope: OverrideScope.vpa,
        vpa: widget.parsed.pa,
      );
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
    try {
      for (final c in picked) {
        await addCardLocalFirst(ref, cardProductId: c.id, product: c);
      }
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
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

/// The category chips of the original scan-result page.
class _CategoryPicker extends StatelessWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.xs,
      runSpacing: AppSpace.xs,
      children: [
        for (final c in categories)
          ChoiceChip(
            label: Text(c.name),
            labelStyle: BambooFonts.ui(
              13,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
            selected: selectedId == c.id,
            selectedColor: BambooInk.lime.withValues(alpha: 0.55),
            backgroundColor: BambooInk.paperMuted,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            onSelected: (_) => onSelected(c.id),
          ),
      ],
    );
  }
}

/// The amount, in its own card above the cards, with quick amounts.
class _AmountCard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey fieldKey;
  final String? errorText;
  const _AmountCard({
    required this.controller,
    required this.focusNode,
    required this.fieldKey,
    required this.errorText,
  });

  static const _quick = [100, 200, 500, 1000];

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            AppSpace.xs,
            AppSpace.md,
            AppSpace.md,
          ),
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: hasError ? BambooInk.clay : BambooInk.hairlineOnPaper,
              width: hasError ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    '₹',
                    style: BambooFonts.money(30, color: BambooInk.ink500),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: TextField(
                      key: fieldKey,
                      controller: controller,
                      focusNode: focusNode,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: BambooFonts.money(26, color: BambooInk.ink900),
                      cursorColor: BambooInk.slate,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        hintText: 'Enter amount',
                        hintStyle: BambooFonts.money(
                          24,
                          color: BambooInk.ink500.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: 'Clear amount',
                            icon: const Icon(
                              Icons.cancel_rounded,
                              color: BambooInk.ink500,
                            ),
                            onPressed: controller.clear,
                          ),
                  ),
                ],
              ),
              const Divider(height: 1, color: BambooInk.hairlineOnPaper),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  for (var i = 0; i < _quick.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: BambooInk.ink900,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size.fromHeight(40),
                          side: const BorderSide(
                            color: BambooInk.hairlineOnPaper,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: () => controller.text = '${_quick[i]}',
                        child: Text(
                          '₹${_quick[i] >= 1000 ? '1,000' : _quick[i]}',
                          style: BambooFonts.ui(
                            14,
                            weight: FontWeight.w600,
                            color: BambooInk.ink900,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.md, 6, 0, 0),
            child: Text(
              errorText!,
              style: BambooFonts.ui(12, color: BambooInk.clayInk),
            ),
          ),
      ],
    );
  }
}

/// "Continue without card": a button that does the same as Pay with a card,
/// opening the same UPI app list from the bottom, and the user pays from their
/// bank account.
class _WithoutCardBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _WithoutCardBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: BambooInk.lime.withValues(alpha: 0.35),
        foregroundColor: BambooInk.ink900,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        minimumSize: const Size.fromHeight(64),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: BambooInk.lime.withValues(alpha: 0.7)),
        ),
      ),
      onPressed: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: BambooInk.slate,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.account_balance_rounded,
              size: 20,
              color: BambooInk.lime,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Continue without card',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
                Text(
                  'Pay using UPI directly',
                  style: BambooFonts.ui(13, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: BambooInk.ink900),
        ],
      ),
    );
  }
}

class _RecommendedHeader extends StatelessWidget {
  final VoidCallback onInfo;
  const _RecommendedHeader({required this.onInfo});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Recommended cards',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
          ),
          IconButton(
            tooltip: 'Why these cards?',
            icon: const Icon(Icons.info_outline_rounded),
            color: BambooInk.ink900,
            onPressed: onInfo,
          ),
        ],
      ),
    );
  }
}

class _P2PNotice extends StatelessWidget {
  final String vpa;
  final Widget action;
  const _P2PNotice({required this.vpa, required this.action});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.person_off_rounded,
      title: "Credit cards can't be used for personal transfers",
      message:
          'This looks like a personal UPI transfer to $vpa, not a merchant payment. '
          "You can still pay it from your bank account.",
      action: Padding(
        padding: const EdgeInsets.only(top: AppSpace.md),
        child: action,
      ),
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  final Recommendation recommendation;
  final bool isHero;
  final bool isOwned;
  final bool showRupayUpiNote;

  /// An owned, UPI-linkable card the engine excluded only because it earns
  /// nothing here (no reward rule, category excluded, cap reached). That is
  /// not a reason to stop the user paying with it, so it keeps its Pay button
  /// and just shows no reward.
  final bool payDespiteExclusion;

  /// Whether a payable amount (≥ ₹1) has been entered yet.
  final bool amountEntered;

  final VoidCallback onNotAccepted;
  final VoidCallback onPay;
  final VoidCallback onAlwaysUseHere;
  final VoidCallback onAddCard;

  const _ScanResultCard({
    required this.recommendation,
    required this.isHero,
    required this.isOwned,
    required this.showRupayUpiNote,
    this.payDespiteExclusion = false,
    this.amountEntered = false,
    required this.onNotAccepted,
    required this.onPay,
    required this.onAlwaysUseHere,
    required this.onAddCard,
  });

  @override
  Widget build(BuildContext context) {
    // Only a card that truly cannot be used here is shown blocked. A card the
    // engine excluded just because it earns nothing here (no reward rule) is
    // shown like the others, with its ₹0.00, and can be paid with.
    final excluded = recommendation.isExcluded && !payDespiteExclusion;
    final hero = isHero && !excluded;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: excluded ? BambooInk.paperMuted : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: hero ? BambooInk.lime : BambooInk.hairlineOnPaper,
          width: hero ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    'TAP THIS ONE',
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
                  foreground: BambooInk.ink900,
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
            ),
          if (!excluded) ...[
            if (showRupayUpiNote)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.qr_code_2_rounded,
                      size: 14,
                      color: BambooInk.ink500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'RuPay credit card — pays through any UPI app',
                      style: BambooFonts.ui(
                        11.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink500,
                      ),
                    ),
                  ],
                ),
              ),
            if (!hero || amountEntered) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  MoneyText(
                    recommendation.expectedValue,
                    confidence: confidenceOf(recommendation),
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
              // D32d: say so when an exclusion could not be read.
              RecommendationCaution(recommendation: recommendation),
            ],
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
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
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
                  OutlinedButton.icon(
                    icon: const Icon(Icons.star_border_rounded, size: 18),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.ink900,
                      side: const BorderSide(color: BambooInk.hairlineOnPaper),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: onAlwaysUseHere,
                    label: const Text('Always use this card here'),
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

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
