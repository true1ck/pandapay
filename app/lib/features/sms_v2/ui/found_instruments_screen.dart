import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../../app/required_field.dart';

import '../../../app/providers.dart' as app;
import '../../cards/card_picker_screen.dart';
import '../instruments/card_linker.dart';
import '../instruments/bank_summary_adapter.dart'
    show isShadowedByCard, shadowingCard;
import '../ledger/providers.dart' show instrumentChoiceRevisionProvider;
import '../providers/data_providers.dart';
import '../providers/runtime_provider.dart';
import 'instrument_actions.dart';
import 'screen_parts.dart';

String instrumentKindLabel(InstrumentKind kind) => switch (kind) {
  InstrumentKind.creditCard => 'Credit cards',
  InstrumentKind.debitCard => 'Debit cards',
  InstrumentKind.bankAccount => 'Bank accounts',
  InstrumentKind.wallet => 'Wallets',
  InstrumentKind.broker => 'Investment accounts',
  _ => 'Other accounts',
};

class FoundInstrumentsScreen extends ConsumerWidget {
  const FoundInstrumentsScreen({super.key});

  Future<void> _act(
    BuildContext context,
    WidgetRef ref,
    Instrument instrument,
    String action,
  ) async {
    final namespace = ref.read(app.cacheNamespaceProvider);
    try {
      // Confirming changes no ledger row, so it needs neither the rule bundle
      // nor a ledger re-projection. Rejecting and renaming still do.
      RuleBundle? bundle;
      if (action != 'confirm') {
        final runtime = await ref.read(smsV2RuntimeProvider.future);
        bundle = await runtime?.activeBundle();
        if (bundle == null) throw StateError('No verified rules');
      }
      final cache = await ref.read(app.responseCacheProvider.future);
      if (!context.mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      final actions = InstrumentActions(
        financial: cache.financialStore,
        namespace: namespace,
        bundle: bundle,
        catalogue: ref.read(app.catalogueProvider).valueOrNull ?? const [],
      );
      if (action == 'rename') {
        final name = await showDialog<String>(
          context: context,
          builder: (_) => _RenameDialog(name: instrument.displayName),
        );
        if (!context.mounted ||
            namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        if (name != null) actions.rename(instrument.instrumentId, name);
      } else if (action == 'reject') {
        actions.reject(instrument.instrumentId);
      } else if (action == 'asCard' || action == 'asAccount') {
        // [instrument] is the bank-account reading of a number that is also a
        // credit card. Keep the side the user names; archive the other.
        final all = ref.read(instrumentsProvider).valueOrNull ?? const [];
        final card = shadowingCard(instrument, all);
        if (action == 'asCard') {
          actions.archive(instrument.instrumentId);
        } else if (card != null && card.userCardId == null) {
          actions.archive(card.instrumentId);
          actions.confirm(instrument.instrumentId);
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This card is in your wallet. Remove it there first.',
                ),
              ),
            );
          }
          return;
        }
      } else {
        final result = actions.confirm(instrument.instrumentId);
        if (result case CardNeedsProduct(
          :final issuerSlug,
          :final maskDigits,
        )) {
          final products = await Navigator.of(context).push<List<CardProduct>>(
            MaterialPageRoute(
              builder: (_) => CardPickerScreen(
                initialSearch: issuerSlug,
                detectedLast4: maskDigits,
              ),
            ),
          );
          if (!context.mounted ||
              namespace != ref.read(app.cacheNamespaceProvider)) {
            return;
          }
          final repository = ref.read(app.userCardsRepositoryProvider);
          if (repository == null) throw StateError('Session unavailable');
          final selected = products ?? <CardProduct>[];
          if (selected.isEmpty) {
            // Nothing was saved: the card stays as it was until a wallet card
            // is chosen for it.
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Not added yet. Choose a card to add it to your wallet.',
                ),
              ),
            );
            return;
          }
          if (selected.length > 1) {
            throw ArgumentError('Choose one card for this account');
          }
          for (final product in selected) {
            final cardId = await repository.addCard(
              product.id,
              last4: maskDigits,
            );
            final cards = await repository.fetchUserCards();
            if (!context.mounted ||
                namespace != ref.read(app.cacheNamespaceProvider)) {
              return;
            }
            cache.financialStore.replaceCards(namespace, cards);
            final card = cards.where((c) => c.id == cardId).single;
            actions.attachCard(instrument.instrumentId, card);
            ref.invalidate(app.userCardsProvider);
          }
        }
      }
      // Local first: the choice is already saved on the phone; show it on this
      // list and on Home right now. Syncing to the server happens later from
      // the outbox, never while the user waits.
      ref.read(instrumentChoiceRevisionProvider.notifier).state++;
    } catch (error) {
      if (context.mounted) smsShowError(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final instruments = ref.watch(instrumentsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts and cards we found')),
      body: AppBackground(
        child: instruments.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const SmsLoading(),
          error: (_, _) =>
              SmsError(onRetry: () => ref.invalidate(instrumentsProvider)),
          data: (items) => FoundInstrumentsList(
            instruments: items,
            notMineHints:
                ref.watch(notMineSuggestionsProvider).valueOrNull ?? const {},
            onConfirm: (i) => _act(context, ref, i, 'confirm'),
            onReject: (i) => _act(context, ref, i, 'reject'),
            onRename: (i) => _act(context, ref, i, 'rename'),
            onResolveKind: (i, isCard) =>
                _act(context, ref, i, isCard ? 'asCard' : 'asAccount'),
            onOpen: (i) =>
                context.push('/sms-v2/instruments/${i.instrumentId}'),
          ),
        ),
      ),
    );
  }
}

class FoundInstrumentsList extends StatelessWidget {
  const FoundInstrumentsList({
    super.key,
    required this.instruments,
    required this.onConfirm,
    required this.onReject,
    required this.onRename,
    required this.onOpen,
    this.onResolveKind,
    this.notMineHints = const {},
  });
  final List<Instrument> instruments;

  /// Ids of accounts that look like someone else's: they get a hint beside
  /// "Not mine". Nothing is rejected for them.
  final Set<String> notMineHints;
  final ValueChanged<Instrument> onConfirm, onReject, onRename, onOpen;

  /// Called with the bank-account reading and true when the user says it is a
  /// credit card, false when it is a bank account.
  final void Function(Instrument account, bool isCard)? onResolveKind;
  @override
  Widget build(BuildContext context) {
    final visible = instruments
        .where(
          (i) =>
              i.status != InstrumentStatus.rejected &&
              i.status != InstrumentStatus.archived,
        )
        .toList();
    if (visible.isEmpty) {
      return const SmsEmpty(
        'No accounts found yet. Import your messages to find them here.',
        icon: Icons.account_balance_outlined,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.xs,
        AppSpace.lg,
        AppSpace.xl,
      ),
      children: [
        Text(
          'Confirm what belongs to you. Credit cards are added to your wallet. You can change these choices later.',
          style: BambooFonts.ui(13, color: BambooInk.ink700, height: 1.4),
        ),
        for (final kind in InstrumentKind.values)
          if (visible.any((i) => i.kind == kind)) ...[
            BambooSectionLabel(
              instrumentKindLabel(kind),
              asTitle: true,
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xs,
                AppSpace.lg,
                AppSpace.xs,
                AppSpace.sm,
              ),
            ),
            for (final instrument in visible.where((i) => i.kind == kind))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child:
                    onResolveKind != null &&
                        isShadowedByCard(instrument, visible)
                    ? _KindQuestionPanel(
                        account: instrument,
                        onChoose: (isCard) =>
                            onResolveKind!(instrument, isCard),
                      )
                    : _InstrumentPanel(
                        instrument: instrument,
                        suggestNotMine: notMineHints.contains(
                          instrument.instrumentId,
                        ),
                        onConfirm: onConfirm,
                        onReject: onReject,
                        onRename: onRename,
                        onOpen: onOpen,
                      ),
              ),
          ],
      ],
    );
  }
}

IconData instrumentKindIcon(InstrumentKind kind) => switch (kind) {
  InstrumentKind.creditCard ||
  InstrumentKind.debitCard => Icons.credit_card_rounded,
  InstrumentKind.wallet => Icons.account_balance_wallet_outlined,
  InstrumentKind.broker => Icons.show_chart_rounded,
  _ => Icons.account_balance_outlined,
};

/// One question for a number that your messages call both a credit card and
/// a bank account. Home lists neither until it is answered.
class _KindQuestionPanel extends StatelessWidget {
  const _KindQuestionPanel({required this.account, required this.onChoose});
  final Instrument account;
  final ValueChanged<bool> onChoose;

  @override
  Widget build(BuildContext context) {
    return BambooPanel(
      padding: _panelPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              BambooIconTile(instrumentKindIcon(account.kind), size: 36),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  '${account.issuerSlug.toUpperCase()} ••${account.maskDigits}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    15,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Your messages call this both a credit card and a bank account. Which is it?',
            style: BambooFonts.ui(13, color: BambooInk.ink700, height: 1.4),
          ),
          const SizedBox(height: AppSpace.sm),
          _ActionRow(
            quiet: [
              TextButton(
                style: _compactQuiet,
                onPressed: () => onChoose(false),
                child: const Text('Bank account'),
              ),
            ],
            primary: FilledButton(
              style: _compactPrimary,
              onPressed: () => onChoose(true),
              child: const Text('Credit card'),
            ),
          ),
        ],
      ),
    );
  }
}

const _panelPadding = EdgeInsets.fromLTRB(
  AppSpace.md,
  AppSpace.md,
  AppSpace.md,
  AppSpace.xs,
);

/// Small-looking buttons for the dense cards on this page. The theme's 52pt
/// full-width button would dominate a card this size. They draw 36pt tall but
/// keep Material's padded tap area, so the touch target stays the 44pt+ the
/// mobile UI guide asks for. No `visualDensity: compact`: it would shrink the
/// drawn button and the tap area with it.
final _compactPrimary = FilledButton.styleFrom(
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
  tapTargetSize: MaterialTapTargetSize.padded,
  textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
);

final _compactQuiet = TextButton.styleFrom(
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
  tapTargetSize: MaterialTapTargetSize.padded,
  foregroundColor: BambooInk.ink700,
  textStyle: BambooFonts.ui(13.5, weight: FontWeight.w600),
);

/// Quiet text actions on the left, the one primary action (when there is one)
/// on the right, all on a single line. Wraps rather than overflows on a narrow
/// screen or a large text size.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.quiet, this.primary});
  final List<Widget> quiet;
  final Widget? primary;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: quiet,
          ),
        ),
        ?primary,
      ],
    );
  }
}

/// One label above one figure, for the strip under an account's name.
class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: BambooFonts.ui(11.5, color: BambooInk.ink500)),
        const SizedBox(height: 1),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: BambooFonts.money(
            13.5,
            weight: FontWeight.w700,
            color: BambooInk.ink900,
          ),
        ),
      ],
    );
  }
}

class _InstrumentPanel extends StatelessWidget {
  const _InstrumentPanel({
    required this.instrument,
    required this.onConfirm,
    required this.onReject,
    required this.onRename,
    required this.onOpen,
    this.suggestNotMine = false,
  });
  final Instrument instrument;
  final bool suggestNotMine;
  final ValueChanged<Instrument> onConfirm, onReject, onRename, onOpen;

  @override
  Widget build(BuildContext context) {
    final detected = instrument.status == InstrumentStatus.detected;
    final isCard = instrument.kind == InstrumentKind.creditCard;
    // A credit card counts only once a wallet card stands behind it. An older
    // build could confirm one without linking it, so "confirmed" alone does
    // not mean it is in the wallet.
    final inWallet = isCard && !detected && instrument.userCardId != null;
    final needsAction = isCard ? !inWallet : detected;
    return BambooPanel(
      padding: _panelPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Pressable(
            onTap: () => onOpen(instrument),
            semanticLabel: 'Open ${instrument.displayName}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    BambooIconTile(
                      instrumentKindIcon(instrument.kind),
                      size: 36,
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            instrument.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              15,
                              weight: FontWeight.w700,
                              color: BambooInk.ink900,
                            ),
                          ),
                          Text(
                            '${instrument.issuerSlug.toUpperCase()} ••${instrument.maskDigits ?? 'unknown'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isCard ? inWallet : !detected) ...[
                      const SizedBox(width: AppSpace.sm),
                      StatusPill(
                        label: isCard ? 'In wallet' : 'Confirmed',
                        icon: Icons.check_rounded,
                        foreground: BambooInk.rankBadgeInk,
                        background: BambooInk.rankBadgeBg,
                      ),
                    ],
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: BambooInk.ink500,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.sm,
                  ),
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _Stat(
                          isCard ? 'Limit' : 'Available',
                          smsMoney(
                            isCard
                                ? instrument.creditLimitMinor
                                : instrument.availableMinor,
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 26,
                        margin: const EdgeInsets.only(right: AppSpace.md),
                        color: BambooInk.hairlineOnPaper,
                      ),
                      Expanded(
                        child: _Stat(
                          'Last activity',
                          smsDate(instrument.lastSeenAt),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (suggestNotMine)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(
                'Your name never appears on this account. If it is not yours, tap Not mine.',
                key: const Key('not-mine-hint'),
                style: BambooFonts.ui(12.5, color: BambooInk.ink700),
              ),
            ),
          _ActionRow(
            quiet: [
              TextButton(
                style: _compactQuiet,
                onPressed: () => onReject(instrument),
                child: const Text('Not mine'),
              ),
              TextButton(
                style: _compactQuiet,
                onPressed: () => onRename(instrument),
                child: const Text('Rename'),
              ),
            ],
            primary: needsAction
                ? FilledButton(
                    style: _compactPrimary,
                    onPressed: () => onConfirm(instrument),
                    child: Text(isCard ? 'Add to wallet' : 'Confirm'),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name});
  final String name;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.name);
  bool _submitted = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Name this account'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 80,
      onChanged: (_) {
        if (_submitted) setState(() {});
      },
      decoration: InputDecoration(
        label: requiredLabel('Name'),
        errorText: requiredError(_submitted, _controller.text),
        prefixIcon: const Icon(Icons.edit_outlined),
      ),
    ),
    actions: [
      TextButton(
        style: BambooButtons.quiet,
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: BambooButtons.primary,
        onPressed: () {
          setState(() => _submitted = true);
          if (_controller.text.trim().isEmpty) return;
          Navigator.pop(context, _controller.text);
        },
        child: const Text('Save'),
      ),
    ],
  );
}
