import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';

/// ui-spec.md F4 SMS Import: an explicit consent/declaration step before
/// the OS permission dialog. Per the plan: "matches F3's 'explicit
/// handling' bar and the app's own DPDP-consent posture used elsewhere
/// (A4/H2)... a self-contained explanation step within F4 is enough" —
/// this doesn't wait on Group A/H's own consent screens landing first.
///
/// Pops `true` if the user taps "Continue", `false`/`null` on back/cancel
/// — the caller only proceeds to the real `requestPermissions()` call on
/// `true`.
class SmsConsentScreen extends StatelessWidget {
  const SmsConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Before you continue', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SMS auto-import reads your bank SMS on-device',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.lg),
              const _Point(
                icon: Icons.phone_iphone_rounded,
                text:
                    'Parsing happens entirely on this device — message text is never uploaded, only the '
                    'extracted amount/merchant/date needed to log a transaction.',
              ),
              const _Point(
                icon: Icons.filter_alt_outlined,
                text:
                    'Only messages matching a known bank-alert pattern are used; everything else is ignored.',
              ),
              const _Point(
                icon: Icons.toggle_off_outlined,
                text: 'You can turn this off at any time; it never runs without this permission granted.',
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BambooInk.ink900,
                        side: const BorderSide(color: BambooInk.hairlineOnPaper),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                      ),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.slate,
                        foregroundColor: BambooInk.lime,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: BambooInk.ink900),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(text, style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
          ),
        ],
      ),
    );
  }
}
