import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/upi_payment_service.dart';

/// Scan-to-pay, Phase 1: the "which UPI app?" chooser.
///
/// Shown every single time — there is deliberately no "remember this app"
/// default. A cardholder keeps a given card in whichever UPI app they linked
/// it to (slice card in the slice app, Tata Neu card in Tata Neu, …), and
/// which card PandaPay recommends changes from one shop to the next, so a
/// sticky default would send the next payment to the wrong app more often
/// than the right one.
class UpiAppPickerSheet extends StatelessWidget {
  final List<UpiApp> apps;
  final String cardName;

  const UpiAppPickerSheet({super.key, required this.apps, required this.cardName});

  /// Returns the chosen app, or null if the user dismissed the sheet.
  static Future<UpiApp?> show(
    BuildContext context, {
    required List<UpiApp> apps,
    required String cardName,
  }) {
    return showModalBottomSheet<UpiApp>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => UpiAppPickerSheet(apps: apps, cardName: cardName),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              "You'll pay with $cardName there, then enter your UPI PIN.",
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: apps.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, i) {
                  final app = apps[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: SizedBox(
                      width: 40,
                      height: 40,
                      child: app.iconPng != null
                          ? Image.memory(app.iconPng!, gaplessPlayback: true)
                          : const Icon(Icons.account_balance_wallet_rounded, color: BambooInk.ink500),
                    ),
                    title: Text(
                      app.name,
                      style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
