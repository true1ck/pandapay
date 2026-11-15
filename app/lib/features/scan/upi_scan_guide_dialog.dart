import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/bamboo_components.dart';

/// Scan-to-pay: the "scan this QR inside your UPI app" step.
///
/// NPCI makes UPI apps decline a payment that another app starts from a shop QR
/// (an intent), while the same QR scanned inside the UPI app goes through. So
/// PandaPay recommends the card, then sends the user to scan the QR in their UPI
/// app. This dialog explains that before the app opens, so the amount to type
/// and the card to pay with are in front of them.
class UpiScanGuideDialog extends StatelessWidget {
  /// The UPI app that will open, or null when no app can be opened from here
  /// (iOS, or no UPI app was found) and the user has to open their own.
  final String? appName;
  final String cardName;
  final String amount;

  const UpiScanGuideDialog({
    super.key,
    required this.appName,
    required this.cardName,
    required this.amount,
  });

  /// True when the user chose to continue, false when they backed out.
  static Future<bool> show(
    BuildContext context, {
    required String? appName,
    required String cardName,
    required String amount,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => UpiScanGuideDialog(appName: appName, cardName: cardName, amount: amount),
    );
    return go == true;
  }

  @override
  Widget build(BuildContext context) {
    final app = appName ?? 'your UPI app';
    return AlertDialog(
      title: Text('Scan the QR in $app'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'UPI apps block payments that another app starts for a shop. '
            'Scanning the same QR inside $app works.',
            style: BambooFonts.ui(13, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          _Step(number: 1, text: appName == null ? 'Open your UPI app' : 'Open $appName'),
          _Step(number: 2, text: "Scan the shop's QR again"),
          _Step(number: 3, text: 'Pay $amount with $cardName (amount is copied)'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: BambooButtons.primary,
          onPressed: () => Navigator.pop(context, true),
          child: Text(appName == null ? 'Got it' : 'Open $appName'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String text;
  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text('$number.', style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.ink900)),
          ),
          Expanded(child: Text(text, style: BambooFonts.ui(14, color: BambooInk.ink900))),
        ],
      ),
    );
  }
}
