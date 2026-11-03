import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../ledger/adapters.dart';
import '../ledger/providers.dart';
import '../ledger/reports.dart';
import '../flag.dart';
import '../instruments/issuer_slugs.dart';
import 'screen_parts.dart';

enum SmsLedgerScreen { investments, ipos, moneyIn, subscriptions }

class SmsLedgerScreenView extends ConsumerWidget {
  const SmsLedgerScreenView({super.key, required this.screen});
  final SmsLedgerScreen screen;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: Text(switch (screen) {
        SmsLedgerScreen.investments => 'Investments',
        SmsLedgerScreen.ipos => 'Your IPO applications',
        SmsLedgerScreen.moneyIn => 'Money in',
        SmsLedgerScreen.subscriptions => 'Subscriptions',
      }),
    ),
    body: ref
        .watch(smsV2LedgerReadModelProvider)
        .when(
          loading: () => const SmsLoading(),
          error: (_, _) => SmsError(
            onRetry: () => ref.invalidate(smsV2LedgerReadModelProvider),
          ),
          data: (model) => LedgerReportList(screen: screen, model: model),
        ),
  );
}

class LedgerReportList extends StatelessWidget {
  const LedgerReportList({
    super.key,
    required this.screen,
    required this.model,
  });
  final SmsLedgerScreen screen;
  final LedgerReadModel model;
  @override
  Widget build(BuildContext context) {
    final events = model.snapshot().events;
    final children = <Widget>[];
    switch (screen) {
      case SmsLedgerScreen.investments:
        for (final item in investmentsSummary(
          model.facts,
          events,
          model.instruments,
        )) {
          children.add(
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.platform,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'Put in ${smsMoney(item.putInMinor)} • Taken out ${smsMoney(item.takenOutMinor)}',
                    ),
                    Text('Net invested ${smsMoney(item.netInvestedMinor)}'),
                    Text('Fund balance ${smsMoney(item.balanceMinor)}'),
                    Text('Dividends ${smsMoney(item.dividendMinor)}'),
                  ],
                ),
              ),
            ),
          );
        }
      case SmsLedgerScreen.ipos:
        for (final item in ipoApplications(model.facts, events)) {
          children.add(
            Card(
              child: ListTile(
                leading: const Icon(Icons.lock_clock_outlined),
                title: Text(item.company),
                subtitle: Text(
                  '${item.status.replaceAll('_', ' ')}\nBlocked ${smsMoney(item.blockedMinor)} • Invested ${smsMoney(item.investedMinor)}\n${item.platform ?? 'Platform unknown'} • Account ••${item.accountMask ?? 'unknown'}',
                ),
                isThreeLine: true,
              ),
            ),
          );
        }
      case SmsLedgerScreen.moneyIn:
        for (final item in moneyIn(
          model.facts,
          events,
          DateTime.utc(1900),
          DateTime.utc(2200),
        )..sort((a, b) => b.occurredAt.compareTo(a.occurredAt))) {
          children.add(
            Card(
              child: ListTile(
                leading: const Icon(Icons.south_west),
                title: Text(item.payer),
                subtitle: Text('${item.kind} • ${smsDate(item.occurredAt)}'),
                trailing: Text(smsMoney(item.amountMinor)),
              ),
            ),
          );
        }
      case SmsLedgerScreen.subscriptions:
        final subscriptions = subscriptionsFromLedger(
          model.facts,
          events,
          now: DateTime.now(),
        );
        for (final active in [true, false]) {
          final items = subscriptions
              .where((s) => (s.lifecycleStatus == 'active') == active)
              .toList();
          if (items.isEmpty) continue;
          children.add(
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                active ? 'Active' : 'Past and interrupted',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          );
          for (final item in items) {
            children.add(
              Card(
                child: ListTile(
                  title: Text(item.displayName),
                  subtitle: Text(
                    '${item.lifecycleStatus.replaceAll('_', ' ')} • ${item.cadenceDays == 0 ? 'Schedule unknown' : 'Every ${item.cadenceDays} days'}',
                  ),
                  trailing: Text(
                    item.amountKnown
                        ? smsMoney(item.typicalAmount.paise)
                        : 'Amount unknown',
                  ),
                ),
              ),
            );
          }
        }
    }
    if (children.isEmpty) {
      return const SmsEmpty(
        'Nothing here yet. Your imported messages will fill this in.',
      );
    }
    return ListView(padding: const EdgeInsets.all(16), children: children);
  }
}

class InstrumentDetailScreen extends ConsumerWidget {
  const InstrumentDetailScreen({super.key, required this.instrumentId});
  final String instrumentId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Account details')),
    body: ref
        .watch(smsV2LedgerReadModelProvider)
        .when(
          loading: () => const SmsLoading(),
          error: (_, _) => SmsError(
            onRetry: () => ref.invalidate(smsV2LedgerReadModelProvider),
          ),
          data: (model) {
            final instrument = model.instruments
                .where((i) => i.instrumentId == instrumentId)
                .firstOrNull;
            if (instrument == null) {
              return const SmsEmpty('This account is no longer available.');
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  instrument.displayName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  '${instrument.issuerSlug.toUpperCase()} ••${instrument.maskDigits ?? 'unknown'}',
                ),
                const SizedBox(height: 24),
                InstrumentUsageSection(instrument: instrument, model: model),
              ],
            );
          },
        ),
  );
}

class InstrumentUsageSection extends StatelessWidget {
  const InstrumentUsageSection({
    super.key,
    required this.instrument,
    required this.model,
  });
  final Instrument instrument;
  final LedgerReadModel model;
  @override
  Widget build(BuildContext context) {
    final facts = {for (final fact in model.facts) fact.factId: fact};
    final ownEvents = model.snapshot().events.where(
      (event) => event.legs.any((leg) {
        final mention = facts[leg.factId]?.instrument;
        return mention?.issuerSlug == instrument.issuerSlug &&
            mention?.maskDigits == instrument.maskDigits;
      }),
    );
    final holds = ipoApplications(
      model.facts,
      ownEvents,
    ).where((i) => i.remainingHoldMinor > 0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Holds and usage',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text('Available ${smsMoney(instrument.availableMinor)}'),
            if (instrument.kind == InstrumentKind.creditCard) ...[
              Text('Limit ${smsMoney(instrument.creditLimitMinor)}'),
              Text('Used ${smsMoney(cardUsage(instrument))}'),
            ],
            Text('Points ${instrument.pointsBalance ?? 'unknown'}'),
            if (holds.isEmpty) const Text('No active IPO holds'),
            for (final hold in holds)
              Text(
                '${smsMoney(hold.remainingHoldMinor)} blocked for ${hold.company}',
              ),
          ],
        ),
      ),
    );
  }
}

/// The existing card/account pages share this account-scoped reading.
class LinkedInstrumentUsage extends ConsumerWidget {
  const LinkedInstrumentUsage({
    super.key,
    this.userCardId,
    this.accountMask,
    this.issuerName,
  });
  final String? userCardId, accountMask, issuerName;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(smsPipelineV2EnabledProvider))
      return const SizedBox.shrink();
    final model = ref.watch(smsV2LedgerReadModelProvider);
    return model.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => TextButton(
        onPressed: () => ref.invalidate(smsV2LedgerReadModelProvider),
        child: const Text('Retry account details'),
      ),
      data: (model) {
        final issuer = issuerName == null
            ? null
            : v2IssuerSlugFromName(issuerName!);
        final matches = model.instruments
            .where(
              (i) => userCardId != null
                  ? i.userCardId == userCardId
                  : i.kind == InstrumentKind.bankAccount &&
                        accountMask != null &&
                        i.maskDigits == accountMask &&
                        issuer != null &&
                        i.issuerSlug == issuer,
            )
            .toList();
        if (matches.length != 1) return const SizedBox.shrink();
        return InstrumentUsageSection(instrument: matches.single, model: model);
      },
    );
  }
}
