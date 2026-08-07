import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
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
    context.go(AppRoute.addFirstCard);
  }

  Future<void> _createAccount(WidgetRef ref, BuildContext context) async {
    await context.push(AppRoute.signUp);
    if (ref.read(accessTokenProvider) != null && context.mounted) {
      context.go(AppRoute.addFirstCard);
    }
    // Otherwise the user backed out of sign-up without completing it —
    // stay right here, no navigation.
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: AppColors.canvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpace.xl),
              Text('How do you want to start?', style: textTheme.headlineSmall),
              const SizedBox(height: AppSpace.sm),
              Text(
                'You can always create an account later without losing anything.',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpace.xxl),
              _ChoiceCard(
                title: 'Use without an account',
                description: 'Everything stays on this phone. Nothing is uploaded.',
                badge: 'RECOMMENDED',
                icon: Icons.phone_iphone_rounded,
                onTap: () => _useWithoutAccount(ref, context),
              ),
              const SizedBox(height: AppSpace.md),
              _ChoiceCard(
                title: 'Create an account',
                description: 'Sync across devices and restore if you lose your phone.',
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
