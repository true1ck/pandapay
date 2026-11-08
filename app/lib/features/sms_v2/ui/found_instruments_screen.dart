import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';

import '../../../app/providers.dart' as app;
import '../../cards/card_picker_screen.dart';
import '../instruments/card_linker.dart';
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
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      final bundle = await runtime?.activeBundle();
      final cache = await ref.read(app.responseCacheProvider.future);
      if (!context.mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      if (bundle == null) throw StateError('No verified rules');
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
      ref.invalidate(instrumentsProvider);
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
            onConfirm: (i) => _act(context, ref, i, 'confirm'),
            onReject: (i) => _act(context, ref, i, 'reject'),
            onRename: (i) => _act(context, ref, i, 'rename'),
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
  });
  final List<Instrument> instruments;
  final ValueChanged<Instrument> onConfirm, onReject, onRename, onOpen;
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
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        Text(
          'Confirm what belongs to you. Credit cards are added to your wallet. You can change these choices later.',
          style: BambooFonts.ui(14, color: BambooInk.ink700, height: 1.45),
        ),
        for (final kind in InstrumentKind.values)
          if (visible.any((i) => i.kind == kind)) ...[
            BambooSectionLabel(instrumentKindLabel(kind), asTitle: true),
            for (final instrument in visible.where((i) => i.kind == kind))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: _InstrumentPanel(
                  instrument: instrument,
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

class _InstrumentPanel extends StatelessWidget {
  const _InstrumentPanel({
    required this.instrument,
    required this.onConfirm,
    required this.onReject,
    required this.onRename,
    required this.onOpen,
  });
  final Instrument instrument;
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
    final quiet = [
      TextButton(
        style: BambooButtons.quiet,
        onPressed: () => onReject(instrument),
        child: const Text('Not mine'),
      ),
      TextButton(
        style: BambooButtons.quiet,
        onPressed: () => onRename(instrument),
        child: const Text('Rename'),
      ),
    ];
    return BambooPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Pressable(
            onTap: () => onOpen(instrument),
            semanticLabel: 'Open ${instrument.displayName}',
            child: Row(
              children: [
                BambooIconTile(instrumentKindIcon(instrument.kind)),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instrument.displayName,
                        style: BambooFonts.ui(
                          15.5,
                          weight: FontWeight.w700,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${instrument.issuerSlug.toUpperCase()} ••${instrument.maskDigits ?? 'unknown'}',
                        style: BambooFonts.ui(13, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                if (isCard ? inWallet : !detected) ...[
                  StatusPill(
                    label: isCard ? 'In wallet' : 'Confirmed',
                    icon: Icons.check_rounded,
                    foreground: BambooInk.rankBadgeInk,
                    background: BambooInk.rankBadgeBg,
                  ),
                  const SizedBox(width: AppSpace.xs),
                ],
                const Icon(
                  Icons.chevron_right_rounded,
                  color: BambooInk.ink500,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),
          const Divider(),
          const SizedBox(height: AppSpace.xs),
          BambooFigureRow(
            isCard ? 'Limit' : 'Available',
            smsMoney(
              isCard ? instrument.creditLimitMinor : instrument.availableMinor,
            ),
          ),
          BambooFigureRow('Last activity', smsDate(instrument.lastSeenAt)),
          const SizedBox(height: AppSpace.md),
          BambooActionBar(
            primary: needsAction
                ? FilledButton(
                    style: BambooButtons.primary,
                    onPressed: () => onConfirm(instrument),
                    child: Text(isCard ? 'Add to wallet' : 'Confirm'),
                  )
                : null,
            quiet: quiet,
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
      decoration: const InputDecoration(
        labelText: 'Name',
        prefixIcon: Icon(Icons.edit_outlined),
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
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}
