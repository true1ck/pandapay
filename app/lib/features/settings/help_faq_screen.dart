import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../onboarding/tour_screen.dart';

/// ui-spec.md H7 Help & FAQ — implementation-plan H7: "fully static,
/// offline, searchable FAQ screen — no backend, no new providers needed at
/// all." Content below is grounded in what the app actually does (not
/// generic filler): the real three tracking channels
/// (`import_hub_screen.dart`), the real `RecommendationEngine.rank()`
/// factors (`packages/pandapay_domain/lib/src/engine/engine.dart`), and the
/// real privacy posture from `product-plan.md` §6 (grid-snapped coords,
/// opt-in-off-by-default crowdsourcing, on-device SMS/PDF parsing).
///
/// Reached via a plain `Navigator.push` from elsewhere in Settings — this
/// file intentionally does not touch `router.dart`/`providers.dart` (see
/// plan note on parallel H-group agents). Zero network calls, zero provider
/// reads: this screen renders identically signed-in or signed-out, online
/// or offline.
class HelpFaqScreen extends StatefulWidget {
  const HelpFaqScreen({super.key});

  @override
  State<HelpFaqScreen> createState() => _HelpFaqScreenState();
}

class _HelpFaqScreenState extends State<HelpFaqScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final results = query.isEmpty
        ? _faqEntries
        : _faqEntries
              .where(
                (e) => e.question.toLowerCase().contains(query) || e.answer.toLowerCase().contains(query),
              )
              .toList();

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Help & FAQ', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // README: "This tour replays any time from You → Help." Pushed
              // directly with onFinished set — see TourScreen's own doc
              // comment for why a plain go_router AppRoute.tour navigation
              // wouldn't work once onboarding is already complete.
              Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TourScreen(onFinished: () => Navigator.of(context).pop()),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpace.md),
                    decoration: BoxDecoration(
                      color: BambooInk.glassFillOnPaper,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.replay_rounded, color: BambooInk.ink900, size: 20),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            'Replay the tour',
                            style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.ink900),
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: BambooInk.ink300),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: InputDecoration(
                  hintText: 'Search FAQs',
                  hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
                  prefixIcon: const Icon(Icons.search_rounded, color: BambooInk.ink500),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close_rounded, color: BambooInk.ink500),
                          onPressed: () => setState(() {
                            _searchController.clear();
                            _query = '';
                          }),
                        ),
                  filled: true,
                  fillColor: BambooInk.glassFillOnPaper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              Expanded(
                child: results.isEmpty
                    ? _EmptyResults(query: _searchController.text.trim())
                    : ListView.separated(
                        itemCount: results.length,
                        separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
                        itemBuilder: (context, index) => _FaqTile(entry: results[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  final String query;
  const _EmptyResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
        child: Text(
          "No results for '$query' — try a different word.",
          textAlign: TextAlign.center,
          style: BambooFonts.ui(14, color: BambooInk.ink500),
        ),
      ),
    );
  }
}

class _FaqTile extends StatelessWidget {
  final FaqEntry entry;
  const _FaqTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    // The fill/border live on the Material itself, not a Container nested
    // inside a transparent one: ExpansionTile's internal ListTile paints its
    // background and ink onto the nearest Material ancestor, so a coloured
    // box between the two hides them (Flutter asserts on exactly this).
    return Material(
      color: BambooInk.glassFillOnPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          iconColor: BambooInk.ink500,
          collapsedIconColor: BambooInk.ink500,
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
          expandedAlignment: Alignment.centerLeft,
          title: Text(entry.question, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(entry.answer, style: BambooFonts.ui(13, color: BambooInk.ink500, height: 1.45)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single question/answer pair. A plain class (not a record) so the list
/// below stays readable with named fields at the call site.
class FaqEntry {
  final String question;
  final String answer;
  const FaqEntry({required this.question, required this.answer});
}

const List<FaqEntry> _faqEntries = [
  FaqEntry(
    question: 'What does setup actually involve?',
    answer:
        'Onboarding walks you through adding the credit cards you already carry so the '
        'recommendation engine has something to rank. Creating an account is optional — PandaPay '
        'works fully in local-only mode, with sign-in unlocking sync and backup rather than gating '
        'any core feature. From there you can optionally set up a tracking channel (email '
        'forwarding, SMS auto-read, or statement import) so future spends get logged automatically '
        'instead of manually.',
  ),
  FaqEntry(
    question: 'What are the different ways PandaPay can track my spending?',
    answer:
        'There are three channels, and none is required. Email forwarding gives you a '
        'dedicated address to forward bank emails to — works on any platform but depends on your '
        'bank actually emailing you. SMS auto-read parses bank SMS on-device in real time, but it '
        "is Android-only (iOS doesn't allow apps to read SMS) and needs the SMS permission granted. "
        'Manual or statement-PDF import lets you drop in a password-protected statement for a '
        'one-off bulk catch-up — it is what turns estimated reward figures into bank-confirmed ones, '
        'but it is not automatic, you have to do it per statement.',
  ),
  FaqEntry(
    question: 'Why did the recommended card look wrong for this purchase?',
    answer:
        'A few real reasons this happens. RuPay/UPI cards are excluded outright for UPI-QR '
        'transactions if they are not UPI-linkable, showing greyed out with a reason rather than '
        'disappearing. If a card\'s reward cap has already been exhausted this cycle, the engine '
        'blends pre-cap and post-cap rates (or drops fully to the lower post-cap rate), so the same '
        'card can look great early in the month and mediocre later. A milestone that this '
        'transaction materially advances (covers at least half the remaining threshold) adds a '
        'pro-rated bonus that will not show up on a smaller purchase. An active manual override on '
        'a card always wins and forces it to the top regardless of expected value. And the '
        'category or merchant is sometimes guessed from a category chip or a geofence match rather '
        'than a hard MCC, so a misclassified category can shift the ranking.',
  ),
  FaqEntry(
    question: 'How accurate are the reward numbers I see?',
    answer:
        'Reward figures start as estimates computed from each card\'s published rate tables and '
        'your live cap/milestone headroom — they are not bank-confirmed until backed by real data. '
        'Each card\'s reward details carry a data-freshness date so you can see how recently the '
        'rate table was checked. Importing a real statement (password-protected PDF, parsed '
        'on-device) reconciles estimates against your bank\'s actual posted points and closing '
        'balance, which is what flips a transaction from "estimated" to "confirmed" confidence.',
  ),
  FaqEntry(
    question: 'What does PandaPay know about where I shop?',
    answer:
        'Location signals used for merchant/category detection are grid-snapped to roughly 50 '
        'metres before anything is stored — the system knows "a shop exists near here," never '
        'exactly where you personally stood. If you opt in to crowdsourcing (off by default, a '
        'separate toggle you control), your contribution is anonymized and stripped of identity '
        'before it ever leaves your phone or gets attached to your account — anonymization is '
        'architectural, not a policy promise layered on top. Raw SMS content and statement PDFs are '
        'parsed entirely on-device and never uploaded; only the extracted financial fields sync if '
        'you are signed in.',
  ),
];
