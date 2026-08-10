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
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.9, -0.6),
          radius: 1.3,
          colors: [BambooInk.wash, BambooInk.paper],
          stops: [0.0, 0.6],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpace.xl),
              Container(
                width: 72,
                height: 72,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: BambooInk.paper,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: const PandaMark(size: 56),
              ),
              const SizedBox(height: AppSpace.xl),
              Text(
                'Know which card to use — before you pay.',
                style: BambooFonts.heading(26, color: BambooInk.ink900),
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
                          color: BambooInk.slate,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: BambooInk.lime, size: 20),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: BambooFonts.heading(15, color: BambooInk.ink900)),
                            const SizedBox(height: 2),
                            Text(body, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                ),
                onPressed: () => context.go(AppRoute.accountChoice),
                child: const Text('Get started'),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  minimumSize: const Size.fromHeight(48),
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w600),
                ),
                onPressed: () => context.push(AppRoute.logIn),
                child: const Text('I already have an account'),
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'PandaPay helps you compare card rewards. It is not financial '
                'advice and does not recommend taking on credit.',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
