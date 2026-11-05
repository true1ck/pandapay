import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';

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
      body: instruments.when(skipLoadingOnReload: true, skipLoadingOnRefresh: true, 
        loading: () => const SmsLoading(),
        error: (_, _) =>
            SmsError(onRetry: () => ref.invalidate(instrumentsProvider)),
        data: (items) => FoundInstrumentsList(
          instruments: items,
          onConfirm: (i) => _act(context, ref, i, 'confirm'),
          onReject: (i) => _act(context, ref, i, 'reject'),
          onRename: (i) => _act(context, ref, i, 'rename'),
          onOpen: (i) => context.push('/sms-v2/instruments/${i.instrumentId}'),
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
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Confirm what belongs to you. You can change these choices later.',
        ),
        for (final kind in InstrumentKind.values)
          if (visible.any((i) => i.kind == kind)) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                instrumentKindLabel(kind),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final instrument in visible.where((i) => i.kind == kind))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          kind == InstrumentKind.creditCard
                              ? Icons.credit_card
                              : Icons.account_balance_outlined,
                        ),
                        title: Text(instrument.displayName),
                        subtitle: Text(
                          '${instrument.issuerSlug.toUpperCase()} ••${instrument.maskDigits ?? 'unknown'}\nLast activity ${smsDate(instrument.lastSeenAt)}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onOpen(instrument),
                      ),
                      Text(
                        kind == InstrumentKind.creditCard
                            ? 'Limit ${smsMoney(instrument.creditLimitMinor)}'
                            : 'Available ${smsMoney(instrument.availableMinor)}',
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (instrument.status == InstrumentStatus.detected)
                            FilledButton(
                              onPressed: () => onConfirm(instrument),
                              child: const Text('Confirm'),
                            )
                          else
                            const Chip(
                              avatar: Icon(Icons.check, size: 16),
                              label: Text('Confirmed'),
                            ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                            ),
                            onPressed: () => onReject(instrument),
                            child: const Text('Not mine'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                            ),
                            onPressed: () => onRename(instrument),
                            child: const Text('Rename'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
      ],
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
      decoration: const InputDecoration(labelText: 'Name'),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.primary,
        ),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}
