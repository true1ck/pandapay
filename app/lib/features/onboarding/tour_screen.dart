import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/router.dart';

/// Design 27/28/29 "Tour" — three light-background value-prop screens shown
/// once, right after 15 Permissions and before 30 Add first card. Per the
/// README: "Tour screens 27–31 were deliberately moved from dark to the
/// light wash background at the user's request; keep them light." `Skip` is
/// available on every step and jumps straight to 30, matching "First run,
/// once only" in Interactions & behavior. Replayable later from You → Help
/// (see help_faq_screen.dart's own wiring of [AppRoute.tour]).
class TourScreen extends StatefulWidget {
  final VoidCallback? onFinished;
  const TourScreen({super.key, this.onFinished});

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _steps = [
    _TourStep(
      icon: Icons.savings_outlined,
      title: 'Your cards already pay you back.',
      body:
          'The average wallet leaves ₹8,000/year on the table — reward-earning spend that '
          'went on the wrong card. PandaPay finds it before you swipe.',
      example: _TourExample(
        merchantLine: 'A ₹2,500 grocery run',
        goodCard: 'Right card',
        goodValue: '₹125',
        badCard: 'Wrong card',
        badValue: '₹25',
      ),
    ),
    _TourStep(
      icon: Icons.qr_code_scanner_rounded,
      title: 'Point it at the QR, get an answer.',
      body:
          'Scan any UPI QR at checkout. PandaPay ranks every card in your wallet for that '
          'exact merchant in under a second.',
    ),
    _TourStep(
      icon: Icons.bar_chart_rounded,
      title: 'See what you kept, and what slipped.',
      body:
          'Every month, a clear tally of rewards earned versus rewards missed — so the '
          'picture never stays a guess.',
      earnedMissed: (earned: '₹1,842', missed: '₹310'),
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finishOrAdvance() {
    if (widget.onFinished != null) {
      widget.onFinished!();
    } else {
      context.push(AppRoute.addFirstCard);
    }
  }

  void _next() {
    if (_page < _steps.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _finishOrAdvance();
    }
  }

  void _skip() => _finishOrAdvance();

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
                0,
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Container(
                    width: 40,
                    height: 40,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: BambooInk.paper,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: const PandaMark(size: 28),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _skip,
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.ink500,
                    ),
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [for (final step in _steps) _TourPage(step: step)],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                0,
                AppSpace.xl,
                AppSpace.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _steps.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _page ? 20 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == _page
                                ? BambooInk.slate
                                : BambooInk.ink300,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.lg),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.lime,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                    ),
                    onPressed: _next,
                    child: Text(
                      _page == _steps.length - 1 ? 'Add my cards' : 'Next',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _EarnedMissed = ({String earned, String missed});

class _TourExample {
  final String merchantLine;
  final String goodCard;
  final String goodValue;
  final String badCard;
  final String badValue;
  const _TourExample({
    required this.merchantLine,
    required this.goodCard,
    required this.goodValue,
    required this.badCard,
    required this.badValue,
  });
}

class _TourStep {
  final IconData icon;
  final String title;
  final String body;
  final _TourExample? example;
  final _EarnedMissed? earnedMissed;
  const _TourStep({
    required this.icon,
    required this.title,
    required this.body,
    this.example,
    this.earnedMissed,
  });
}

class _TourPage extends StatelessWidget {
  final _TourStep step;
  const _TourPage({required this.step});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: BambooInk.lime,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(step.icon, color: BambooInk.slate, size: 30),
          ),
          const SizedBox(height: AppSpace.xl),
          Text(
            step.title,
            style: BambooFonts.heading(26, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            step.body,
            style: BambooFonts.ui(15, color: BambooInk.ink500, height: 1.5),
          ),
          if (step.example != null) ...[
            const SizedBox(height: AppSpace.xl),
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                color: BambooInk.slate,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.example!.merchantLine,
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _ExampleCard(
                          label: step.example!.goodCard,
                          value: step.example!.goodValue,
                          good: true,
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: _ExampleCard(
                          label: step.example!.badCard,
                          value: step.example!.badValue,
                          good: false,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (step.earnedMissed != null) ...[
            const SizedBox(height: AppSpace.xl),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'EARNED',
                    value: step.earnedMissed!.earned,
                    color: BambooInk.jade,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: _StatTile(
                    label: 'MISSED',
                    value: step.earnedMissed!.missed,
                    color: BambooInk.clay,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ExampleCard extends StatelessWidget {
  final String label;
  final String value;
  final bool good;
  const _ExampleCard({
    required this.label,
    required this.value,
    required this.good,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: good
            ? BambooInk.lime.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w600,
              color: BambooInk.onSlateMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: BambooFonts.money(
              20,
              color: good ? BambooInk.lime : BambooInk.onSlateSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w600,
              color: BambooInk.ink500,
            ).copyWith(letterSpacing: 1),
          ),
          const SizedBox(height: 4),
          Text(value, style: BambooFonts.money(22, color: color)),
        ],
      ),
    );
  }
}
