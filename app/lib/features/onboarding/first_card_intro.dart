import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import 'entry_brand.dart';

class FirstCardIntroduction extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onSkip;
  final VoidCallback? onBack;

  const FirstCardIntroduction({
    super.key,
    required this.onAdd,
    required this.onSkip,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) => EntryBackdrop(
    waves: false,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 56,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (onBack != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: IconButton(
                              tooltip: 'Back',
                              onPressed: onBack,
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                          ),
                        const EntryProgress(step: 2),
                        const SizedBox(height: 32),
                        Text(
                          'Welcome to',
                          textAlign: TextAlign.center,
                          style: BambooFonts.heading(
                            34,
                            weight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const PandaWordmark(size: 38),
                        const SizedBox(height: 20),
                        Center(
                          child: PandaIllustration(
                            size: math.min(260, constraints.maxHeight * .32),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          'Add your first card to see\nwhich one earns more.',
                          textAlign: TextAlign.center,
                          style: BambooFonts.heading(
                            21,
                            weight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'We’ll help you choose the best card\nfor every purchase.',
                          textAlign: TextAlign.center,
                          style: BambooFonts.ui(
                            15,
                            color: BambooInk.ink700,
                            height: 1.4,
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(height: 32),
                        EntryButton(label: 'Add a card', onPressed: onAdd),
                        const SizedBox(height: 10),
                        EntryButton(
                          label: 'I’ll do this later',
                          onPressed: onSkip,
                          secondary: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
