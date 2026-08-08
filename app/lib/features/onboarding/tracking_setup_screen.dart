import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../import/email_forwarding_screen.dart';
import '../import/statement_pdf_import_screen.dart';
import '../sms_import/sms_import_screen.dart';

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

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await ref.read(onboardingCompleteProvider.notifier).complete();
    if (mounted) context.go(AppRoute.home);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up tracking')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('How should we track your spending?', style: textTheme.headlineSmall),
              const SizedBox(height: AppSpace.sm),
              Text(
                'Pick a channel below, or skip for now — you can always set this up later from Import & Sync.',
                style: textTheme.bodyMedium,
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
                onPressed: _finishing ? null : _finish,
                child: const Text('Set up later'),
              ),
            ],
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
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: badge != null ? AppColors.teal500 : AppColors.ink100,
              width: badge != null ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icon, color: AppColors.navy800, size: 22),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(title, style: textTheme.titleMedium)),
                        if (badge != null) ...[
                          const SizedBox(width: AppSpace.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.teal600,
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text(
                              badge!,
                              style: textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(description, style: textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
