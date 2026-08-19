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
                'SMS auto-import reads your bank alerts for you',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.lg),
              // These three lines previously claimed on-device parsing and
              // that message text was never uploaded. Neither was true —
              // there is no Dart-side SMS parser; the regex match runs
              // server-side against `parser_patterns`. See
              // smsextractionimple.md §0.2. What IS true is the filtering
              // (on-device, before any upload) and the non-storage (a
              // parsed message becomes a transaction; an unparsed one
              // becomes redactSmsShape() output, which cannot contain
              // digits by CHECK constraint). Say that instead.
              const _Point(
                icon: Icons.filter_alt_outlined,
                text:
                    'Your phone checks each message first. Only ones that look like bank alerts are sent '
                    '— everything else stays on your device.',
              ),
              const _Point(
                icon: Icons.lock_outline_rounded,
                text:
                    'Bank alerts are sent to PandaPay over an encrypted connection to pull out the amount, '
                    'merchant and date.',
              ),
              const _Point(
                icon: Icons.delete_outline_rounded,
                text:
                    'The message text is never stored on our servers — only the transaction it produced.',
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
