import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../overrides/manual_overrides_screen.dart';

/// Design 23 "Card actions · freeze or remove" — everything you can do to
/// one card that isn't editing its details.
///
/// Two of the mockup's labels promise more than any app can deliver, and
/// are worded here for what actually happens:
///
/// - "Freeze this card — blocks new charges instantly" would need an issuer
///   API PandaPay has no relationship for. What the app can really do is
///   stop ranking the card, which is [UserCardsRepository.archiveCard]. The
///   row says so: pausing here does not block anything at your bank.
/// - "Remove this card" is an archive, not a delete — the transactions
///   logged against it stay, so your history and reward totals don't
///   silently change. The card stops being ranked and moves to Wallet's
///   Archived tab, from which it can come back. That's stated on the row
///   rather than left for the user to discover.
class CardActionsScreen extends ConsumerStatefulWidget {
  final UserCard card;
  final CardProduct product;
  const CardActionsScreen({super.key, required this.card, required this.product});

  @override
  ConsumerState<CardActionsScreen> createState() => _CardActionsScreenState();
}

class _CardActionsScreenState extends ConsumerState<CardActionsScreen> {
  bool _busy = false;

  String get _displayName => widget.card.nickname?.isNotEmpty == true
      ? widget.card.nickname!
      : widget.card.cardName;

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Both the pause toggle and "Remove card" archive the same card, because
  /// archiving is the only real operation underneath. They differ in intent
  /// and in how loudly they say so, which is why Remove confirms first.
  Future<void> _setPaused(bool paused) async {
    final repo = ref.read(userCardsRepositoryProvider);
    final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
    await _run(
      () async => paused
          ? (repo != null ? repo.archiveCard(widget.card.id) : local!.archiveCard(widget.card.id))
          : (repo != null ? repo.unarchiveCard(widget.card.id) : local!.unarchiveCard(widget.card.id)),
      paused ? '$_displayName paused — it will not be ranked.' : '$_displayName is back in the ranking.',
    );
  }

  Future<void> _setDefault() async {
    final repo = ref.read(userCardsRepositoryProvider);
    final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
    await _run(
      () async => repo != null
          ? repo.setDefaultCard(widget.card.id)
          : local!.setDefaultCard(widget.card.id),
      '$_displayName is now your default card.',
    );
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BambooInk.paper,
        title: Text('Remove $_displayName?', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        content: Text(
          'PandaPay stops ranking it and moves it to Archived, where you can restore it any '
          'time. Spends already logged against it stay in your history, so your totals do not '
          'change. This does not close the card with your bank.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.clay,
              foregroundColor: BambooInk.paper,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove card'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    destructiveActionHaptic();
    await _setPaused(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final paused = widget.card.isArchived;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_displayName, style: BambooFonts.heading(19, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, AppSpace.md, 20, 30),
          children: [
            // Design 23's slate identity strip. The mockup shows "•••• 4568"
            // — the app deliberately never stores a card number (see
            // product-plan §6), so this carries what it genuinely knows:
            // the issuer and the network.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: BambooInk.slate,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: BambooInk.lime.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      _displayName.characters.first.toUpperCase(),
                      style: BambooFonts.heading(12, color: BambooInk.lime),
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Text(
                      [
                        if (widget.product.issuerName != null) widget.product.issuerName!,
                        widget.product.network.name.toUpperCase(),
                      ].join(' · '),
                      style: BambooFonts.ui(13.5, color: BambooInk.onSlateSubtle),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              child: Column(
                children: [
                  _ActionRow(
                    title: 'Pause this card',
                    subtitle: 'PandaPay stops ranking it. This does not block the card with '
                        'your bank — only your bank can do that.',
                    trailing: Switch(
                      value: paused,
                      activeThumbColor: BambooInk.lime,
                      activeTrackColor: BambooInk.slate,
                      onChanged: _busy ? null : _setPaused,
                    ),
                  ),
                  const _RowDivider(),
                  _ActionRow(
                    title: 'Report lost or stolen',
                    subtitle: "Your issuer's hotline — works offline, no sign-in.",
                    onTap: () => context.push(AppRoute.emergencyCardInfo),
                  ),
                  const _RowDivider(),
                  _ActionRow(
                    title: widget.card.isDefault ? 'Already your default card' : 'Set as default card',
                    subtitle: 'Used when nothing else clearly wins.',
                    onTap: widget.card.isDefault || _busy ? null : _setDefault,
                  ),
                  const _RowDivider(),
                  _ActionRow(
                    title: 'Always use this card for a category',
                    subtitle: 'A manual override beats the ranking every time.',
                    onTap: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const ManualOverridesScreen())),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: BambooInk.warningBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BambooInk.warningBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Remove this card',
                    style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.clayInk),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'PandaPay stops ranking it and moves it to Archived. Your logged spends stay. '
                    'This does not close the card with your bank.',
                    style: BambooFonts.ui(12.5, color: BambooInk.clayInkMuted, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy || paused ? null : _confirmRemove,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.clay,
                      backgroundColor: BambooInk.paper.withValues(alpha: 0.88),
                      minimumSize: const Size.fromHeight(46),
                      side: const BorderSide(color: BambooInk.clay, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
                    ),
                    child: Text(paused ? 'Already removed' : 'Remove card'),
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

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16),
    child: Divider(height: 1, thickness: 1, color: BambooInk.hairlineOnPaper),
  );
}

class _ActionRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _ActionRow({required this.title, required this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null && trailing == null;
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: BambooFonts.ui(
                    14.5,
                    weight: FontWeight.w600,
                    color: disabled ? BambooInk.ink500 : BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          trailing ??
              (onTap == null
                  ? const SizedBox.shrink()
                  : const Icon(Icons.chevron_right_rounded, color: BambooInk.ink300)),
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}
