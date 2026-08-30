import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// ui-spec.md A3 ⭐. "Use without an account" carries a recommended badge —
/// local/guest mode is explicitly a first-class citizen per the spec ("no
/// dark patterns, no nagging later"), matching this app's existing
/// signed-out browse support on Home. "Create account" only continues once
/// sign-up actually succeeds (accessTokenProvider becomes non-null); backing
/// out of sign-up leaves the user right back here rather than silently
/// treating an abandoned flow as a completed choice.
///
/// Task A7-A10 (implementation-plan's Group A completion): neither path
/// completes onboarding here anymore — both continue to A7 (Add Your First
/// Card) instead, per the spec's real screen order A3 -> A7 -> A9 -> A10 ->
/// A11 -> Home. A10 Tracking Setup is now the only place onboarding
/// actually completes.
class AccountChoiceScreen extends ConsumerWidget {
  const AccountChoiceScreen({super.key});

  void _useWithoutAccount(WidgetRef ref, BuildContext context) {
    context.go(AppRoute.permissions);
  }

  Future<void> _createAccount(WidgetRef ref, BuildContext context) async {
    await context.push(AppRoute.signUp);
    if (ref.read(accessTokenProvider) != null && context.mounted) {
      context.go(AppRoute.permissions);
    }
    // Otherwise the user backed out of sign-up without completing it —
    // stay right here, no navigation.
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                'How do you want to start?',
                style: BambooFonts.heading(22, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                'You can always create an account later without losing anything.',
                style: BambooFonts.ui(13.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.xxl),
              _ChoiceCard(
                title: 'Use without an account',
                description:
                    'Everything stays on this phone. Nothing is uploaded.',
                badge: 'RECOMMENDED',
                icon: Icons.phone_iphone_rounded,
                onTap: () => _useWithoutAccount(ref, context),
              ),
              const SizedBox(height: AppSpace.md),
              _ChoiceCard(
                title: 'Create an account',
                description:
                    'Sync across devices and restore if you lose your phone.',
                icon: Icons.cloud_outlined,
                onTap: () => _createAccount(ref, context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  final String title;
  final String description;
  final String? badge;
  final IconData icon;
  final VoidCallback onTap;

  const _ChoiceCard({
    required this.title,
    required this.description,
    this.badge,
    required this.icon,
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
              color: badge != null
                  ? BambooInk.slate
                  : BambooInk.hairlineOnPaper,
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
                  color: BambooInk.slate,
                  borderRadius: BorderRadius.circular(14),
                ),
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
                          child: Text(
                            title,
                            style: BambooFonts.heading(
                              16,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: AppSpace.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
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
                    Text(
                      description,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
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
