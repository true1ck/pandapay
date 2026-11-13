import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../sms_v2/ledger/suspected_refunds.dart';

/// "Was this refunded?" — shown on a card spend whose card limit came back
/// with no message explaining it.
///
/// It only asks. "Yes" hands off to the screen's existing refund action (which
/// removes the spend and its reward); "No" is remembered so it is never asked
/// again for this spend.
class SuspectedRefundBanner extends StatefulWidget {
  const SuspectedRefundBanner({
    super.key,
    required this.info,
    required this.onConfirmRefunded,
  });

  final SuspectedRefundInfo info;
  final Future<void> Function() onConfirmRefunded;

  static String dismissKey(String spendEventId) =>
      'suspected_refund_dismissed:$spendEventId';

  @override
  State<SuspectedRefundBanner> createState() => _SuspectedRefundBannerState();
}

class _SuspectedRefundBannerState extends State<SuspectedRefundBanner> {
  bool _dismissed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed =
          prefs.getBool(SuspectedRefundBanner.dismissKey(widget.info.spendEventId)) ??
          false;
      if (mounted && dismissed) setState(() => _dismissed = true);
    } catch (_) {
      // Preferences unavailable: ask rather than hide a possible refund.
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        SuspectedRefundBanner.dismissKey(widget.info.spendEventId),
        true,
      );
    } catch (_) {
      // Not remembered across launches; the answer still applies for now.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final rose = Money.fromPaise(widget.info.limitRoseByMinor).format(hidePaise: true);
    final spend = Money.fromPaise(widget.info.spendAmountMinor).format(hidePaise: true);
    return Container(
      key: const ValueKey('suspected-refund-banner'),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Was this refunded?',
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: 4),
          Text(
            'Your card ending ${widget.info.cardLast4} got about $rose of its '
            'limit back with no payment or refund message, close to this $spend '
            'spend. If it was refunded, the reward on it should not count.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              FilledButton(
                key: const ValueKey('suspected-refund-yes'),
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        try {
                          await widget.onConfirmRefunded();
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: const Text('Yes, refunded'),
              ),
              const SizedBox(width: AppSpace.sm),
              TextButton(
                key: const ValueKey('suspected-refund-no'),
                onPressed: _busy ? null : _dismiss,
                child: const Text('No, keep it'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
