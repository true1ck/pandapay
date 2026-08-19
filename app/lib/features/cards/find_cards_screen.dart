import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show CardDiscoveryResult, DiscoveredCard;
import '../import/email_forwarding_screen.dart';

/// "Find my cards" — design 30's fastest add-a-card path, over **both**
/// forwarded bank email and (on Android) bank SMS.
///
/// Email matters as much as SMS here, and on iOS it matters more: no iOS app
/// may read SMS at all, so on an iPhone the SMS path can never find
/// anything and email is the only automatic route there is. Both feed the
/// same matcher server-side (api/src/card_discovery.js), so a card is
/// recognised identically wherever it was mentioned.
///
/// Nothing is added without a tap. Each suggestion shows the text that
/// produced it, because the failure this screen has to avoid is adding a
/// card the user doesn't own and then ranking against it.
class FindCardsScreen extends ConsumerStatefulWidget {
  /// Task S-3: SMS bodies to scan alongside the user's forwarded email,
  /// handed over by [SmsBackupImportScreen] after its on-device filter has
  /// already narrowed a backup file down to probable bank alerts.
  ///
  /// Sent for this one request and never persisted — POST /card-discovery
  /// holds them in memory to build the response and writes none of them.
  /// Empty on every other entry point, which makes this screen email-only
  /// there (and therefore email-only on iOS in all cases).
  final List<String> smsBodies;

  const FindCardsScreen({super.key, this.smsBodies = const []});

  @override
  ConsumerState<FindCardsScreen> createState() => _FindCardsScreenState();
}

class _FindCardsScreenState extends ConsumerState<FindCardsScreen> {
  CardDiscoveryResult? _result;
  bool _scanning = false;
  bool _adding = false;
  String? _error;
  final _added = <String>{};

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      setState(() => _error = 'Finding cards automatically needs an account.');
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      // SMS bodies are read on-device and passed up for this one request;
      // the server never stores them (see POST /card-discovery). On iOS
      // there are none to read, so this is email-only there.
      //
      // The server caps `smsBodies` at 500. Rather than let it truncate an
      // arbitrary first-500 — which on a chronological export is the OLDEST
      // messages, the ones least likely to mention a card the user still
      // holds — send the most recent 500 and let the cap be a no-op.
      final bodies = widget.smsBodies.length > 500
          ? widget.smsBodies.sublist(widget.smsBodies.length - 500)
          : widget.smsBodies;
      final result = await repo.discoverCards(smsBodies: bodies);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _add(DiscoveredCard card) async {
    if (_adding) return;
    setState(() => _adding = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = ref.read(userCardsRepositoryProvider);
      final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
      if (repo != null) {
        await repo.addCard(card.cardProductId);
      } else {
        await local!.addCard(card.cardProductId);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      // Design 19's own worked example: "Axis Ace added · Found
      // automatically from a bank SMS". dedupeKey keeps a re-add from
      // stacking duplicates in the inbox.
      await recordAppNotification(
        ref,
        category: 'card_added',
        title: '${card.name} added',
        body: 'Found automatically in ${card.sources.contains('email') ? 'your bank email' : 'your SMS'}.',
        severity: 'good',
        dedupeKey: 'card_added:${card.cardProductId}',
      );
      if (mounted) setState(() => _added.add(card.cardProductId));
      messenger.showSnackBar(SnackBar(content: Text('${card.name} added to your wallet.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Find my cards', style: BambooFonts.heading(19, color: BambooInk.ink900)),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppBackground(child: _body()),
    );
  }

  Widget _body() {
    if (_scanning && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _scan);
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    if (result.suggestions.isEmpty) {
      // Say which it was: "we read nothing" and "we read plenty and matched
      // nothing" are completely different problems for the user to fix.
      final readNothing = result.emailsScanned == 0 && result.smsScanned == 0;
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: readNothing ? 'Nothing to read yet' : 'No cards recognised',
        message: readNothing
            ? 'We have no bank email to look at. Set up email forwarding and forward a '
                  'statement or a transaction alert, then run this again.'
            : 'We read ${_scannedSummary(result)} and could not match any card in our '
                  'catalogue. Add yours from the list instead — it takes a few seconds.',
        action: readNothing
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                ),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const EmailForwardingScreen())),
                child: const Text('Set up email forwarding'),
              )
            : null,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, AppSpace.md, 20, 30),
      children: [
        Text(
          'We read ${_scannedSummary(result)} and think you carry '
          '${result.suggestions.length} '
          'of these. Add the ones you actually have.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
        ),
        if (!_isAndroid) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            'iOS never lets any app read your SMS, so this looks at forwarded bank email only.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        for (final s in result.suggestions)
          _SuggestionCard(
            card: s,
            added: _added.contains(s.cardProductId),
            busy: _adding,
            onAdd: () => _add(s),
          ),
      ],
    );
  }

  String _scannedSummary(CardDiscoveryResult r) {
    final parts = <String>[
      if (r.emailsScanned > 0) '${r.emailsScanned} bank email${r.emailsScanned == 1 ? '' : 's'}',
      if (r.smsScanned > 0) '${r.smsScanned} SMS',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(' and ');
  }
}

class _SuggestionCard extends StatelessWidget {
  final DiscoveredCard card;
  final bool added;
  final bool busy;
  final VoidCallback onAdd;

  const _SuggestionCard({
    required this.card,
    required this.added,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final sources = card.sources
        .map((s) => s == 'email' ? 'your bank email' : 'your SMS')
        .join(' and ');

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.name,
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
              ),
              if (card.last4.isNotEmpty)
                Text(
                  '•••• ${card.last4.first}',
                  style: BambooFonts.heading(13, color: BambooInk.ink300, letterSpacing: 1),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // The evidence line is the point of this screen: it lets someone
          // spot a wrong suggestion instead of trusting a bare list.
          Text(
            'Found in $sources — ${card.evidence.take(3).join(', ')}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45),
          ),
          const SizedBox(height: AppSpace.md),
          if (added)
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, size: 18, color: BambooInk.jade),
                const SizedBox(width: 6),
                Text(
                  'Added to your wallet',
                  style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.jade),
                ),
              ],
            )
          else
            FilledButton(
              onPressed: busy ? null : onAdd,
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
              ),
              child: Text('Yes, I have ${card.name}'),
            ),
        ],
      ),
    );
  }
}
