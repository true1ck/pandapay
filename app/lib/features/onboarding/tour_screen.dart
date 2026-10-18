import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/router.dart';
import 'entry_brand.dart';

class TourScreen extends StatefulWidget {
  final VoidCallback? onFinished;
  const TourScreen({super.key, this.onFinished});

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    if (widget.onFinished != null) {
      widget.onFinished!();
    } else {
      context.push(AppRoute.addFirstCard);
    }
  }

  void _next() {
    if (_page == 2) {
      _finish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) => EntryBackdrop(
    waves: false,
    child: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => context.pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const Spacer(),
                    const PandaWordmark(size: 20),
                    const Spacer(),
                    TextButton(onPressed: _finish, child: const Text('Skip')),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: const [
                    _TourPage(
                      title: 'Meet your\nmoney buddy.',
                      body:
                          'Keeping track of every card can feel like a lot.\nPandaPay brings the important bits together.',
                      illustration: PandaStoryIllustration(),
                    ),
                    _TourPage(
                      title: 'The right card.\nAt the right moment.',
                      body:
                          'Compare rewards across the cards you own.\nScan a UPI QR to see which card fits.',
                      illustration: PandaIllustration(size: 250),
                    ),
                    _TourPage(
                      title: 'Your month,\nmade clearer.',
                      body:
                          'Follow your spending, reward caps and milestones.\nA little clarity goes a long way.',
                      illustration: PandaStoryIllustration(spending: true),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < 3; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: i == _page ? 20 : 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? const Color(0xFFA8DD43)
                                  : const Color(0xFFDADDD9),
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    EntryButton(
                      label: _page == 2 ? 'Let’s add your cards' : 'Next',
                      onPressed: _next,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TourPage extends StatelessWidget {
  final String title;
  final String body;
  final Widget illustration;
  const _TourPage({
    required this.title,
    required this.body,
    required this.illustration,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            SizedBox(
              height: math.max(220, constraints.maxHeight * .63),
              child: Center(child: illustration),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: BambooFonts.heading(
                36,
                weight: FontWeight.w800,
                height: 1.05,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              body,
              textAlign: TextAlign.center,
              style: BambooFonts.ui(15, color: BambooInk.ink700, height: 1.45),
            ),
          ],
        ),
      ),
    ),
  );
}
