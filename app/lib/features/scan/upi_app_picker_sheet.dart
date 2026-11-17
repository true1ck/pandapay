import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/upi_payment_service.dart';

/// Brands that are both a card and a UPI app. A card named for one of these is
/// usually linked in that app (a Scapia card in Scapia, a Tata Neu card in Tata
/// Neu, a slice card in slice), so the app is highlighted in the chooser.
const _cardAppBrands = [
  'scapia',
  'tata neu',
  'slice',
  'kiwi',
  'jupiter',
  'onecard',
  'phonepe',
  'paytm',
  'amazon pay',
  'mobikwik',
  'freecharge',
  'airtel',
  'navi',
];

String _words(String text) =>
    ' ${text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()} ';

/// Whether [app] is the app a card called [cardName] is usually linked in.
/// Whole words only, so a "Credit" card never matches the CRED app.
bool upiAppMatchesCard(UpiApp app, String cardName) {
  final card = _words(cardName);
  final name = _words(app.name);
  for (final brand in _cardAppBrands) {
    final word = ' $brand ';
    if (card.contains(word) && name.contains(word)) return true;
  }
  return false;
}

/// Scan-to-pay, Phase 1: the "which UPI app?" chooser.
///
/// Shown every single time — there is deliberately no "remember this app"
/// default. A cardholder keeps a given card in whichever UPI app they linked
/// it to (slice card in the slice app, Tata Neu card in Tata Neu, …), and
/// which card PandaPay recommends changes from one shop to the next, so a
/// sticky default would send the next payment to the wrong app more often
/// than the right one.
///
/// What it does do is show what is being paid with in a highlighted box, and
/// outline the app a card of that name is usually linked in, at the top.
class UpiAppPickerSheet extends StatelessWidget {
  final List<UpiApp> apps;

  /// The card being paid with, or the words "your bank account".
  final String cardName;

  /// True when there is no card: the payment is from the user's bank account.
  final bool fromBankAccount;

  const UpiAppPickerSheet({
    super.key,
    required this.apps,
    required this.cardName,
    this.fromBankAccount = false,
  });

  /// Returns the chosen app, or null if the user dismissed the sheet.
  static Future<UpiApp?> show(
    BuildContext context, {
    required List<UpiApp> apps,
    required String cardName,
    bool fromBankAccount = false,
  }) {
    return showModalBottomSheet<UpiApp>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => UpiAppPickerSheet(
        apps: apps,
        cardName: cardName,
        fromBankAccount: fromBankAccount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The matching app first, the rest in the order they came.
    final matched = [
      if (!fromBankAccount) ...apps.where((a) => upiAppMatchesCard(a, cardName)),
    ];
    final ordered = [...matched, ...apps.where((a) => !matched.contains(a))];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Open which UPI app?',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: 4),
            Text(
              "Pick the app where it's linked, then enter your UPI PIN there.",
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            _PayingWith(
              label: fromBankAccount ? 'Your bank account' : cardName,
              fromBankAccount: fromBankAccount,
            ),
            const SizedBox(height: AppSpace.md),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: ordered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final app = ordered[i];
                  return _AppRow(
                    app: app,
                    matchesCard: matched.contains(app),
                    onTap: () => Navigator.of(context).pop(app),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The payment method, in a box that stands out from the list below it.
class _PayingWith extends StatelessWidget {
  final String label;
  final bool fromBankAccount;

  const _PayingWith({required this.label, required this.fromBankAccount});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 12),
      decoration: BoxDecoration(
        color: BambooInk.jade.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.jade.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Row(
        children: [
          Icon(
            fromBankAccount ? Icons.account_balance_rounded : Icons.credit_card_rounded,
            color: BambooInk.jade,
            size: 22,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Paying with',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                ),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    14.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  final UpiApp app;
  final bool matchesCard;
  final VoidCallback onTap;

  const _AppRow({
    required this.app,
    required this.matchesCard,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The tile paints its own tint and outline, so its tap ripple stays visible.
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      tileColor: matchesCard ? BambooInk.jade.withValues(alpha: 0.08) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: matchesCard
            ? BorderSide(color: BambooInk.jade.withValues(alpha: 0.55), width: 1.5)
            : BorderSide.none,
      ),
      leading: _AppLogo(app: app),
      title: Text(
        app.name,
        style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
      ),
      subtitle: matchesCard
          ? Text(
              'Matches this card',
              style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.jade),
            )
          : null,
      trailing: const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
      onTap: onTap,
    );
  }
}

/// The app's own icon: the real one on Android, the bundled App Store artwork
/// on iOS, a plain wallet when there is neither.
class _AppLogo extends StatelessWidget {
  final UpiApp app;

  const _AppLogo({required this.app});

  static const _fallback = Icon(
    Icons.account_balance_wallet_rounded,
    color: BambooInk.ink500,
  );

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (app.iconPng != null) {
      child = Image.memory(app.iconPng!, gaplessPlayback: true);
    } else if (app.logoAsset != null) {
      child = Image.asset(
        app.logoAsset!,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => _fallback,
      );
    } else {
      child = _fallback;
    }
    return ExcludeSemantics(
      child: SizedBox(
        width: 42,
        height: 42,
        child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
      ),
    );
  }
}
