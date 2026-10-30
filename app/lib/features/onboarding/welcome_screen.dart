import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/router.dart';
import 'entry_brand.dart';

class WelcomeScreen extends StatefulWidget {
  final bool resumeSetup;
  const WelcomeScreen({super.key, this.resumeSetup = false});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const _storyDurations = [
    Duration(milliseconds: 4750),
    Duration(milliseconds: 6500),
  ];

  final _pageController = PageController();
  Timer? _advanceTimer;
  int _page = 0;
  bool _dragging = false;
  bool? _reducedMotion;

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion == reducedMotion) return;
    _reducedMotion = reducedMotion;

    if (reducedMotion) {
      _advanceTimer?.cancel();
      // Respect the system's reduced-motion setting and take the user straight
      // to the welcome/entry page rather than showing two still frames.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPage(2);
      });
    } else if (_page < 2) {
      _scheduleAdvance(_page);
    }
  }

  void _scheduleAdvance(int page) {
    _advanceTimer?.cancel();
    if (page >= 2 || _reducedMotion == true || _dragging) return;
    _advanceTimer = Timer(_storyDurations[page], () {
      if (mounted && _page == page) _showPage(page + 1);
    });
  }

  void _showPage(int page) {
    if (!mounted || !_pageController.hasClients || page == _page) return;
    _advanceTimer?.cancel();
    if (_reducedMotion == true) {
      _pageController.jumpToPage(page);
    } else {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    _scheduleAdvance(page);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _advanceTimer?.cancel();
    } else if (notification is ScrollEndNotification) {
      _dragging = false;
      _scheduleAdvance(_page);
    }
    return false;
  }

  Widget _slideForPage(int page) => switch (page) {
    0 => _WelcomeSlide(
      title: 'A little less\ncard chaos.',
      body: 'Cards, rewards and limits.\nLet your money buddy keep track.',
      story: true,
      illustration: _StoryStage(spending: false, playing: _page == page),
    ),
    1 => _WelcomeSlide(
      title: 'A clearer view.\nA calmer month.',
      body: 'Understand your spending.\nMake more of every reward.',
      story: true,
      illustration: _StoryStage(spending: true, playing: _page == page),
    ),
    _ => const _WelcomeSlide(
      key: ValueKey('make-every-card-count'),
      title: 'Make every\ncard count.',
      body: 'Choose the best rewards card\nfor every purchase.',
      illustration: PandaIllustration(size: 270),
    ),
  };

  @override
  Widget build(BuildContext context) => EntryBackdrop(
    waves: false,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pageHeight = math.max(420.0, constraints.maxHeight - 276);
          return SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PandaWordmark(),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: pageHeight,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onScroll,
                          child: PageView.builder(
                            key: const ValueKey('welcome-pages'),
                            controller: _pageController,
                            onPageChanged: _onPageChanged,
                            itemCount: 3,
                            itemBuilder: (context, page) => _slideForPage(page),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 48,
                        child: Semantics(
                          label: 'Introduction ${_page + 1} of 3',
                          liveRegion: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < 3; i++)
                                Semantics(
                                  selected: i == _page,
                                  button: true,
                                  label: 'View introduction ${i + 1}',
                                  child: InkResponse(
                                    onTap: () => _showPage(i),
                                    radius: 22,
                                    child: SizedBox(
                                      width: 44,
                                      height: 48,
                                      child: Center(
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 250,
                                          ),
                                          width: i == _page ? 20 : 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            color: i == _page
                                                ? const Color(0xFFA8DD43)
                                                : const Color(0xFFDADDD9),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_page == 2) ...[
                        if (widget.resumeSetup)
                          EntryButton(
                            label: 'Continue setup',
                            onPressed: () => context.go(AppRoute.permissions),
                          )
                        else ...[
                          EntryButton(
                            label: 'Create account',
                            onPressed: () => context.push(AppRoute.signUp),
                          ),
                          const SizedBox(height: 10),
                          EntryButton(
                            label: 'I already have an account',
                            secondary: true,
                            onPressed: () => context.push(AppRoute.logIn),
                          ),
                        ],
                      ] else
                        SizedBox(
                          height: 118,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Swipe to explore',
                                style: BambooFonts.ui(
                                  11,
                                  color: BambooInk.ink700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        'Compare rewards. Spend thoughtfully.',
                        textAlign: TextAlign.center,
                        style: BambooFonts.ui(11, color: BambooInk.ink700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _WelcomeSlide extends StatelessWidget {
  final String title;
  final String body;
  final Widget illustration;
  final bool story;
  const _WelcomeSlide({
    super.key,
    required this.title,
    required this.body,
    required this.illustration,
    this.story = false,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: constraints.maxWidth,
              height: story
                  ? (constraints.maxHeight * .62).clamp(245.0, 400.0)
                  : (constraints.maxHeight * .52).clamp(180.0, 300.0),
              child: Center(child: illustration),
            ),
            SizedBox(height: story ? 20 : 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: BambooFonts.heading(
                constraints.maxWidth < 330 ? 36 : 42,
                weight: FontWeight.w800,
                height: 1.01,
                letterSpacing: -1.7,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              body,
              textAlign: TextAlign.center,
              style: BambooFonts.ui(16, color: BambooInk.ink700, height: 1.35),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _StoryStage extends StatelessWidget {
  final bool spending;
  final bool playing;

  const _StoryStage({required this.spending, required this.playing});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final showLabels =
          constraints.maxWidth >= 300 &&
          MediaQuery.textScalerOf(context).scale(12) <= 18;
      return Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          FractionallySizedBox(
            widthFactor: .94,
            heightFactor: .84,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xFFF0F7E8), Color(0x00F0F7E8)],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: PandaStoryIllustration(spending: spending, playing: playing),
          ),
          if (showLabels) ...[
            Positioned(
              left: 0,
              top: constraints.maxHeight * .16,
              child: _StoryLabel(
                icon: spending
                    ? Icons.insights_rounded
                    : Icons.credit_card_rounded,
                text: spending ? 'Spending insights' : 'All your cards',
              ),
            ),
            Positioned(
              right: 0,
              bottom: constraints.maxHeight * .17,
              child: _StoryLabel(
                icon: spending
                    ? Icons.auto_awesome_rounded
                    : Icons.toll_rounded,
                text: spending ? 'Better rewards' : 'Rewards & limits',
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _StoryLabel extends StatelessWidget {
  final IconData icon;
  final String text;

  const _StoryLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .94),
      border: Border.all(color: const Color(0xFFE5EBDC)),
      borderRadius: BorderRadius.circular(30),
      boxShadow: const [
        BoxShadow(
          color: Color(0x06738158),
          blurRadius: 14,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF7DA83F)),
          const SizedBox(width: 6),
          Text(text, style: BambooFonts.ui(11, weight: FontWeight.w600)),
        ],
      ),
    ),
  );
}
