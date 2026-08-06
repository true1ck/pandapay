import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/router.dart';

/// ui-spec.md A2. Headline + three value points + a not-financial-advice
/// disclaimer present from the very first screen (A2's explicit requirement,
/// not something bolted on later). "Get Started" -> A3 Account Choice;
/// "I have an account" -> A5 Log In directly, skipping account choice
/// entirely since a returning user has already made that decision.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  static const _valuePoints = [
    (Icons.qr_code_scanner_rounded, 'Scan any card', 'Point your camera at a card to add it in seconds.'),
    (Icons.auto_graph_rounded, 'Automatic tracking', 'Spend, points, and milestones update themselves.'),
    (Icons.notifications_active_outlined, 'Never miss a cap', 'Know before you lose a reward, not after.'),
  ];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: AppColors.canvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpace.xl),
              const AppLogoMark(),
              const SizedBox(height: AppSpace.xl),
              Text(
                'Know which card to use — before you pay.',
                style: textTheme.headlineMedium,
              ),
              const SizedBox(height: AppSpace.xxl),
              for (final (icon, title, body) in _valuePoints)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.teal50,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(icon, color: AppColors.teal600, size: 20),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: textTheme.titleSmall),
                            const SizedBox(height: 2),
                            Text(body, style: textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () => context.go(AppRoute.accountChoice),
                child: const Text('Get started'),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton(
                onPressed: () => context.push(AppRoute.logIn),
                child: const Text('I already have an account'),
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'PandaPay helps you compare card rewards. It is not financial '
                'advice and does not recommend taking on credit.',
                style: textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
