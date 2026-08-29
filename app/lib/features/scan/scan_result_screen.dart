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
import '../../data/upi_payment_service.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../cards/card_picker_screen.dart';
import '../comparison/comparison_view_screen.dart';
import 'payment_sent_screen.dart';
import 'upi_app_picker_sheet.dart';

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
    return (parsed != null && parsed > 0) ? Money.fromRupees(parsed) : const Money.zero();
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
    _merchantController = TextEditingController(text: widget.parsed.pn ?? '');
    final scannedAmount = widget.parsed.am;
    _amountController = TextEditingController(
      text: (scannedAmount != null && scannedAmount.rupees > 0)
          ? scannedAmount.rupees.toStringAsFixed(0)
          : '',
    );
    // Rebuild the ranked list (and clear the red flag) as the user types.
    _amountController.addListener(_onAmountControllerChanged);
  }

  void _onAmountControllerChanged() {
    setState(() {
      if (_amountError != null && _amount.rupees >= 1) _amountError = null;
    });
  }

  @override
  void dispose() {
    _merchantController.dispose();
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

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Scan result', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        actions: [
          IconButton(
            tooltip: 'Compare all cards',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
          ),
        ],
      ),
      body: AppBackground(child: _buildBody(catalogue, categories, userCards, overrides, engine)),
    );
  }

  Widget _buildBody(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<SpendCategory>> categories,
    AsyncValue<List<UserCard>> userCards,
    AsyncValue<List<CardOverride>> overrides,
    RecommendationEngine engine,
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
    final noMcc = widget.parsed.isLikelyP2P;
    final walletPeek = userCards.valueOrNull;
    if (noMcc && (walletPeek == null || walletPeek.isEmpty)) {
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

    // ui-spec B1 says "No cards → CTA to add one". B3 has no rule of its own,
    // so: with an empty wallet still rank the whole catalogue (a useful
    // "best card for this merchant" signal), but every row is then a
    // not-owned card — _ScanResultCard swaps its "Pay with" action for
    // "Add this card" so we never offer a hand-off the user can't complete.
    final walletEmpty = wallet.isEmpty;
    var cards = walletEmpty
        ? allCards
        : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

    // No merchant code on the QR: the only card that can pay here is a
    // UPI-linkable RuPay credit card, and only at a business. Filter to
    // those; if the user owns none, there is nothing to show but the notice.
    if (noMcc) {
      cards = cards
          .where((c) => c.network == CardNetwork.rupay && c.isUpiLinkable)
          .toList();
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
      categoryId: _selectedCategoryId,
      vpa: widget.parsed.pa,
    );

    // This is the one ranking path in the app that genuinely knows the
    // merchant — a scanned UPI QR carries the payee name — so it is the
    // path where merchant-restricted rules ("10% at Amazon only") can
    // actually be honoured rather than falling through to the base rate.
    final merchantName = widget.parsed.pn;
    final now = DateTime.now();
    final upiContext = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      merchantName: merchantName,
      rail: TxnRail.upiQr,
      now: now,
    );
    final swipeContext = RecommendationContext(
      amount: _amount,
      categoryId: _selectedCategoryId,
      mcc: widget.parsed.mc,
      vpa: widget.parsed.pa,
      merchantName: merchantName,
      rail: TxnRail.swipe,
      now: now,
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

    // The amount is entered inline on the card the user actually pays with —
    // the best owned, eligible card — not in a field detached from it. Null
    // when the wallet is empty (nothing to pay yet; add a card first).
    final amountEntryCardId =
        (bestUpi != null && wallet.any((w) => w.cardProductId == bestUpi.card.id))
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
                const Icon(Icons.info_outline_rounded, size: 18, color: BambooInk.ink500),
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
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
                const Icon(Icons.info_outline_rounded, size: 18, color: BambooInk.ink500),
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
        if (bestUpi != null && bestSwipe != null && bestSwipe.expectedValue > bestUpi.expectedValue)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(16)),
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
                message: "You've marked every card as not accepted at this merchant.",
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
                isHero: bestUpi != null && rec.card.id == bestUpi.card.id,
                isOwned: wallet.any((w) => w.cardProductId == rec.card.id),
                showRupayUpiNote:
                    rec.card.network == CardNetwork.rupay && rec.card.isUpiLinkable,
                showAmountEntry: rec.card.id == amountEntryCardId,
                amountEntered: _amount.rupees >= 1,
                amountController: _amountController,
                amountFocusNode: _amountFocusNode,
                amountFieldKey: _amountFieldKey,
                amountError: _amountError,
                onNotAccepted: () => setState(() => _locallyRejectedCardIds.add(rec.card.id)),
                onPay: () => _payWith(rec, wallet),
                onAlwaysUseHere: () => _createOverride(rec, wallet),
                onAddCard: () => _addCard(rec.card),
              ),
            ),
      ],
    );
  }

  Future<void> _payWith(Recommendation rec, List<UserCard> wallet) async {
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, continue')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final merchant = _merchantController.text.trim();
    final service = ref.read(upiPaymentServiceProvider);
    final uriString = buildUpiPayUri(
      pa: widget.parsed.pa,
      pn: merchant.isEmpty ? widget.parsed.pn : merchant,
      am: _amount,
      // Carry the scanned merchant fields through so a verified-merchant QR
      // isn't downgraded to an "unverified payee" prompt; synth a `tr` when
      // the QR didn't carry an order reference of its own.
      mc: widget.parsed.mc,
      tr: widget.parsed.tr ?? service.newTransactionRef(),
      tn: widget.parsed.tn,
      mode: widget.parsed.mode,
      orgid: widget.parsed.orgid,
      sign: widget.parsed.sign,
    );

    final apps = await service.installedApps();
    if (!mounted) return;

    // iOS, or Android with nothing enumerable — fall back to the plain
    // scheme launch (OS picks the app, no status comes back).
    if (apps.isEmpty) {
      await _legacyLaunch(rec, wallet, uriString);
      return;
    }

    final chosen = await UpiAppPickerSheet.show(context, apps: apps, cardName: rec.card.name);
    if (chosen == null || !mounted) return;

    // The channel completes on the UPI app's Activity result. If Android
    // recreated our Activity while the user was in the UPI app (low RAM), or
    // they never came back, that result is lost — cap the wait so the future
    // can't hang the screen forever, and fall to the manual-confirm path.
    final result = await service
        .pay(upiUri: uriString, packageName: chosen.packageName)
        .timeout(
          const Duration(minutes: 4),
          onTimeout: () => const UpiPaymentResult(status: UpiPaymentStatus.submitted),
        );
    if (!mounted) return;

    switch (result.status) {
      case UpiPaymentStatus.success:
        await _openPaymentSent(rec: rec, wallet: wallet, autoLog: true);
        break;
      case UpiPaymentStatus.submitted:
        // The honest default: the app returned with no conclusive status.
        await _openPaymentSent(rec: rec, wallet: wallet, autoLog: false);
        break;
      case UpiPaymentStatus.failure:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment failed in ${chosen.name}. Try another UPI app, or a different card.'),
          ),
        );
        break;
      case UpiPaymentStatus.cancelled:
        break; // user backed out of the UPI app — nothing to report
      case UpiPaymentStatus.noAppsAvailable:
        await _legacyLaunch(rec, wallet, uriString);
        break;
    }
  }

  /// Pre-channel behaviour: hand the `upi://` link to the OS and hope. Used
  /// on iOS and whenever no UPI app can be enumerated.
  Future<void> _legacyLaunch(Recommendation rec, List<UserCard> wallet, String uriString) async {
    final uri = Uri.parse(uriString);
    final launched = await canLaunchUrl(uri) && await launchUrl(uri);
    if (!mounted) return;
    if (!launched) {
      // ui-spec B3 edge case: no UPI app installed -> recommendation-only
      // with a copy-VPA action.
      await Clipboard.setData(ClipboardData(text: widget.parsed.pa));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No UPI app found — copied ${widget.parsed.pa} to your clipboard instead.')),
      );
      return;
    }
    await _openPaymentSent(rec: rec, wallet: wallet, autoLog: false);
  }

  Future<void> _openPaymentSent({
    required Recommendation rec,
    required List<UserCard> wallet,
    required bool autoLog,
  }) async {
    if (!mounted) return;
    final owned = wallet.where((w) => w.cardProductId == rec.card.id).firstOrNull;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PaymentSentScreen(
          merchantName: _merchantController.text.trim(),
          amount: _amount,
          cardName: rec.card.name,
          userCardId: owned?.id,
          categoryId: _selectedCategoryId,
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${rec.card.name} will always be suggested here.')));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }

  /// "Add this card" on a not-owned suggestion (empty wallet). Opens the same
  /// picker the Wallet tab uses, pre-filtered to this card, then adds the
  /// pick to the wallet (server if signed in, local DB as a guest) so the
  /// row flips to a real "Pay with" on the next rebuild.
  Future<void> _addCard(CardProduct card) async {
    final picked = await Navigator.of(context).push<List<CardProduct>>(
      MaterialPageRoute(builder: (_) => CardPickerScreen(initialSearch: card.name)),
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
          const SnackBar(content: Text('Added — now suggesting from your wallet.')),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
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
      runSpacing: AppSpace.xs,
      children: [
        for (final c in categories)
          ChoiceChip(
            label: Text(c.name),
            labelStyle: BambooFonts.ui(
              13,
              weight: FontWeight.w600,
              color: selectedId == c.id ? BambooInk.onSlate : BambooInk.ink900,
            ),
            selected: selectedId == c.id,
            selectedColor: BambooInk.slate,
            backgroundColor: BambooInk.paperMuted,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
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
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: hero ? BambooInk.lime : (excluded ? BambooInk.paperMuted : BambooInk.glassFillOnPaper),
        borderRadius: BorderRadius.circular(24),
        border: hero ? null : Border.all(color: BambooInk.hairlineOnPaper),
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
          Row(
            children: [
              if (hero) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(999)),
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
                  style: BambooFonts.heading(16, color: excluded ? BambooInk.ink500 : BambooInk.ink900),
                ),
              ),
              if (recommendation.isOverride)
                StatusPill(
                  label: 'Override',
                  foreground: hero ? BambooInk.slate : BambooInk.ink900,
                  background: hero ? Colors.white.withValues(alpha: 0.5) : BambooInk.paperMuted,
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
                const Icon(Icons.block_rounded, size: 16, color: BambooInk.ink500),
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
                    Icon(Icons.qr_code_2_rounded, size: 14, color: hero ? BambooInk.slate : BambooInk.ink500),
                    const SizedBox(width: 4),
                    Text(
                      'RuPay credit card — pays through any UPI app',
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
                    style: BambooFonts.money(hero ? 34 : 22, color: BambooInk.ink900),
                  ),
                  if (recommendation.expectedValue.paise > 0) ...[
                    const SizedBox(width: 6),
                    Text('back', style: BambooFonts.ui(13, color: BambooInk.ink500)),
                  ],
                ],
              ),
              for (final line in recommendation.reasonLines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('•  $line', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                ),
            ] else
              Text(
                'Enter an amount to see your reward',
                style: BambooFonts.ui(12.5, color: hero ? BambooInk.slate : BambooInk.ink500),
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
                    style: BambooFonts.ui(12.5, color: hero ? BambooInk.slate : BambooInk.ink500),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.lime,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: onPay,
                    child: Text('Pay with ${recommendation.card.name}'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: hero ? BambooInk.slate : BambooInk.ink900,
                      side: BorderSide(
                        color: hero ? BambooInk.slate.withValues(alpha: 0.4) : BambooInk.hairlineOnPaper,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: onAlwaysUseHere,
                    child: const Text('Always use this card here'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: hero ? BambooInk.slate : BambooInk.ink500),
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
              color: hasError ? BambooInk.clay : BambooInk.slate.withValues(alpha: 0.25),
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
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: BambooFonts.money(26, color: BambooInk.ink900),
                  cursorColor: BambooInk.slate,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: InputBorder.none,
                    hintText: 'Amount',
                    hintStyle: BambooFonts.money(24, color: BambooInk.ink500.withValues(alpha: 0.5)),
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
            child: Text(errorText!, style: BambooFonts.ui(12, color: BambooInk.clay)),
          ),
      ],
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
