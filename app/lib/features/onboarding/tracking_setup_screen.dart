import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../import/email_forwarding_screen.dart';
import '../import/statement_pdf_import_screen.dart';
import '../sms_import/sms_import_screen.dart';
import 'all_set_screen.dart';

/// ui-spec.md A10 Tracking Setup — the last onboarding step; this is where
/// onboarding actually completes now (moved from account_choice_screen.dart,
/// per the plan: A3 -> A7 -> A9 -> A10 -> A11 -> Home). "Set up later" is
/// always visible and always enabled — never block onboarding completion on
/// this, per spec's own edge case.
class TrackingSetupScreen extends ConsumerStatefulWidget {
  const TrackingSetupScreen({super.key});

  @override
  ConsumerState<TrackingSetupScreen> createState() => _TrackingSetupScreenState();
}

class _TrackingSetupScreenState extends ConsumerState<TrackingSetupScreen> {
  bool _finishing = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Design 31 "You're all set" is the last step, so onboarding is NOT
  /// marked complete here — AllSetScreen's own "Take me Home" does that.
  /// Order matters: `onboardingCompleteProvider.complete()` fires the
  /// router's refreshListenable, whose redirect immediately bounces every
  /// preOnboarding route (including this one) to Home — which tore down the
  /// route this push was landing on, so screen 31 flashed past unseen.
  /// Confirmed on the simulator, not theorised.
  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllSetScreen()));
    if (mounted) setState(() => _finishing = false);
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text('Set up tracking', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'How should we track your spending?',
                  style: BambooFonts.heading(22, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  'Pick a channel below, or skip for now — you can always set this up later from Import & Sync.',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                ),
                const SizedBox(height: AppSpace.xl),
                Expanded(
                  child: ListView(
                    children: [
                      _ChannelChoiceCard(
                        icon: Icons.email_outlined,
                        title: 'Email forwarding',
                        description: 'Works on any phone/provider, ~3 min setup.',
                        badge: _isAndroid ? null : 'RECOMMENDED',
                        onTap: () => _openChannel(const EmailForwardingScreen()),
                      ),
                      const SizedBox(height: AppSpace.md),
                      if (_isAndroid)
                        _ChannelChoiceCard(
                          icon: Icons.sms_outlined,
                          title: 'SMS auto-read',
                          description: 'Android only, instant, on-device.',
                          badge: 'RECOMMENDED',
                          onTap: () => _openChannel(const SmsImportScreen()),
                        ),
                      if (_isAndroid) const SizedBox(height: AppSpace.md),
                      _ChannelChoiceCard(
                        icon: Icons.picture_as_pdf_outlined,
                        title: 'Manual / statement import',
                        description: 'No setup.',
                        onTap: () => _openChannel(const StatementPdfImportScreen()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.ink900,
                    minimumSize: const Size.fromHeight(48),
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _finishing ? null : _finish,
                  child: const Text('Set up later'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pushes the real channel screen (F2/F3/F4 — [SmsImportScreen] already
  /// runs its own [SmsConsentScreen] declaration step before requesting the
  /// OS permission, so A10 doesn't duplicate that consent flow itself, it
  /// just launches straight into the real screen same as Email/Manual).
  /// DoD: returning from ANY of the three completes onboarding too, same as
  /// "Set up later" — every channel screen here is independently skippable/
  /// back-able, so simply coming back (having looked at it, set up or not)
  /// counts as "done with this step."
  Future<void> _openChannel(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _finish();
  }
}

class _ChannelChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? badge;
  final VoidCallback onTap;

  const _ChannelChoiceCard({
    required this.icon,
    required this.title,
    required this.description,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: badge != null ? BambooInk.slate : BambooInk.hairlineOnPaper,
              width: badge != null ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: BambooInk.lime, size: 22),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title, style: BambooFonts.heading(16, color: BambooInk.ink900)),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: AppSpace.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: BambooInk.lime,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge!,
                              style: BambooFonts.ui(
                                10,
                                weight: FontWeight.w700,
                                color: BambooInk.slate,
                              ).copyWith(letterSpacing: 0.5),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(description, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: BambooInk.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
