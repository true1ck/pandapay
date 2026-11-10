import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../insights/subscription_view.dart';
import '../ledger/adapters.dart';
import '../ledger/providers.dart';
import '../ledger/reports.dart';
import '../instruments/issuer_slugs.dart';
import 'screen_parts.dart';

enum SmsLedgerScreen { investments, ipos, moneyIn, subscriptions }

const _moneyInSections = [
  ('salary', 'Salary'),
  ('dividend', 'Dividends'),
  ('refund', 'Refunds'),
  ('cashback', 'Cashback'),
  ('person', 'From people'),
  ('other', 'Other money in'),
];

String _ipoStatus(String status) => switch (status) {
  'blocked' => 'Applied, amount blocked',
  'allotted' => 'Allotted',
  'partially_allotted' => 'Partly allotted, rest released',
  'released' => 'Not allotted, amount released',
  'review' => 'Needs your review',
  _ => status.replaceAll('_', ' '),
};

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
    body: AppBackground(
      child: ref
          .watch(smsV2LedgerReadModelProvider)
          .when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const SmsLoading(),
            error: (_, _) => SmsError(
              onRetry: () => ref.invalidate(smsV2LedgerReadModelProvider),
            ),
            data: (model) => LedgerReportList(screen: screen, model: model),
          ),
    ),
  );
}

/// One line of figures — "Put in ₹x • Taken out ₹y" — with each label
/// quiet and each amount in the money face. A single rich text, so the line
/// reads (and is found by tests) as one sentence.
class _InlineFigures extends StatelessWidget {
  const _InlineFigures(this.figures, {this.size = 13});
  final List<(String, String)> figures;
  final double size;
  @override
  Widget build(BuildContext context) {
    final label = BambooFonts.ui(size, color: BambooInk.ink500, height: 1.5);
    final value = BambooFonts.money(
      size + 0.5,
      weight: FontWeight.w700,
      color: BambooInk.ink900,
    ).copyWith(height: 1.5);
    return Text.rich(
      TextSpan(
        children: [
          for (final (index, (name, amount)) in figures.indexed) ...[
            if (index > 0) TextSpan(text: ' • ', style: label),
            TextSpan(text: '$name ', style: label),
            TextSpan(text: amount, style: value),
          ],
        ],
      ),
    );
  }
}

/// A panel holding a run of rows separated by hairlines.
class _RowGroup extends StatelessWidget {
  const _RowGroup(this.rows);
  final List<Widget> rows;
  @override
  Widget build(BuildContext context) => BambooPanel(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Column(
      children: [
        for (final (index, row) in rows.indexed) ...[
          if (index > 0)
            const Divider(indent: AppSpace.lg, endIndent: AppSpace.lg),
          row,
        ],
      ],
    ),
  );
}

const _rowPadding = EdgeInsets.symmetric(horizontal: AppSpace.lg);

class LedgerReportList extends StatelessWidget {
  const LedgerReportList({
    super.key,
    required this.screen,
    required this.model,
  });
  final SmsLedgerScreen screen;
  final LedgerReadModel model;

  Widget _amount(String text) =>
      Text(text, style: BambooFonts.money(14.5, weight: FontWeight.w700));

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
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: BambooPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const BambooIconTile(Icons.show_chart_rounded),
                        const SizedBox(width: AppSpace.md),
                        Expanded(
                          child: Text(
                            item.platform,
                            style: BambooFonts.heading(
                              16.5,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.md),
                    _InlineFigures([
                      ('Net invested', smsMoney(item.netInvestedMinor)),
                    ], size: 15),
                    const SizedBox(height: AppSpace.xs),
                    _InlineFigures([
                      ('Put in', smsMoney(item.putInMinor)),
                      ('Taken out', smsMoney(item.takenOutMinor)),
                    ]),
                    _InlineFigures([
                      ('Fund balance', smsMoney(item.balanceMinor)),
                      ('Dividends', smsMoney(item.dividendMinor)),
                    ]),
                  ],
                ),
              ),
            ),
          );
        }
      case SmsLedgerScreen.ipos:
        for (final item in ipoApplications(model.facts, events)) {
          final meta = [
            item.platform ?? 'Platform unknown',
            'Account ••${item.accountMask ?? 'unknown'}',
            if (item.appliedAt != null) 'Applied ${smsDate(item.appliedAt!)}',
          ].join(' • ');
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: BambooPanel(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: ListTile(
                  contentPadding: _rowPadding,
                  isThreeLine: true,
                  leading: const BambooIconTile(Icons.lock_clock_outlined),
                  title: Text(item.company),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      _IpoStatusPill(item.status),
                      const SizedBox(height: 6),
                      _InlineFigures([
                        ('Blocked', smsMoney(item.blockedMinor)),
                        ('Invested', smsMoney(item.investedMinor)),
                        ('Released', smsMoney(item.releasedMinor)),
                      ], size: 12.5),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                      if (item.noAllotmentNoticeAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'No allotment notice on ${smsDate(item.noAllotmentNoticeAt!)} • your bank should release the money',
                            style: BambooFonts.ui(12, color: BambooInk.ink500),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      case SmsLedgerScreen.moneyIn:
        final items = moneyIn(
          model.facts,
          events,
          DateTime.utc(1900),
          DateTime.utc(2200),
        )..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
        int sum(Iterable<MoneyInItem> rows) =>
            rows.fold(0, (total, row) => total + row.amountMinor);
        if (items.isNotEmpty) {
          final income = items.where((i) => i.kind != 'refund');
          children.add(_MoneyInSummary(total: smsMoney(sum(income))));
        }
        for (final (kind, title) in _moneyInSections) {
          final rows = items.where((i) => i.kind == kind).toList();
          if (rows.isEmpty) continue;
          children.add(
            BambooSectionLabel(
              title,
              asTitle: true,
              trailing: smsMoney(sum(rows)),
            ),
          );
          children.add(
            _RowGroup([
              for (final item in rows)
                ListTile(
                  contentPadding: _rowPadding,
                  leading: const BambooIconTile(
                    Icons.south_west_rounded,
                    size: 36,
                  ),
                  title: Text(item.payer),
                  subtitle: Text(smsDate(item.occurredAt)),
                  trailing: _amount(smsMoney(item.amountMinor)),
                ),
            ]),
          );
        }
      case SmsLedgerScreen.subscriptions:
        // The same filtering and merging as the main Subscriptions screen
        // ([buildSubscriptionView]), so both list the same services.
        final view = buildSubscriptionView(
          subscriptionsFromLedger(model.facts, events, now: DateTime.now()),
        );
        final subscriptions = view.subscriptions;
        for (final active in [true, false]) {
          final items = subscriptions
              .where((s) => (s.lifecycleStatus == 'active') == active)
              .toList();
          if (items.isEmpty) continue;
          children.add(
            BambooSectionLabel(
              active ? 'Active' : 'Past and interrupted',
              asTitle: true,
              padding: EdgeInsets.fromLTRB(
                4,
                children.isEmpty ? AppSpace.sm : AppSpace.xl,
                4,
                10,
              ),
            ),
          );
          children.add(
            _RowGroup([
              for (final item in items)
                ListTile(
                  contentPadding: _rowPadding,
                  leading: BambooIconTile(
                    active ? Icons.autorenew_rounded : Icons.pause_rounded,
                    size: 36,
                  ),
                  title: Text(item.displayName),
                  subtitle: Text(
                    '${item.lifecycleStatus.replaceAll('_', ' ')} • ${item.cadenceDays == 0 ? 'Schedule unknown' : 'Every ${item.cadenceDays} days'}',
                  ),
                  trailing: item.amountKnown
                      ? _amount(smsMoney(item.typicalAmount.paise))
                      : Text(
                          'Amount unknown',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                ),
            ]),
          );
        }
        if (view.candidates.isNotEmpty) {
          children.add(
            BambooSectionLabel(
              'Possible subscriptions',
              asTitle: true,
              padding: EdgeInsets.fromLTRB(
                4,
                children.isEmpty ? AppSpace.sm : AppSpace.xl,
                4,
                10,
              ),
            ),
          );
          children.add(
            _RowGroup([
              for (final item in view.candidates)
                ListTile(
                  contentPadding: _rowPadding,
                  leading: const BambooIconTile(
                    Icons.help_outline_rounded,
                    size: 36,
                  ),
                  title: Text(item.displayName),
                  subtitle: Text(
                    'Found from repeated charges, not confirmed • every ${item.cadenceDays} days',
                  ),
                  trailing: _amount(smsMoney(item.typicalAmount.paise)),
                ),
            ]),
          );
        }
    }
    if (children.isEmpty) {
      return SmsEmpty(
        'Nothing here yet. Your imported messages will fill this in.',
        icon: switch (screen) {
          SmsLedgerScreen.investments => Icons.show_chart_rounded,
          SmsLedgerScreen.ipos => Icons.lock_clock_outlined,
          SmsLedgerScreen.moneyIn => Icons.south_west_rounded,
          SmsLedgerScreen.subscriptions => Icons.autorenew_rounded,
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: children,
    );
  }
}

class _IpoStatusPill extends StatelessWidget {
  const _IpoStatusPill(this.status);
  final String status;
  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (status) {
      'allotted' ||
      'partially_allotted' => (BambooInk.rankBadgeInk, BambooInk.rankBadgeBg),
      'review' => (BambooInk.clayInk, BambooInk.warningBg),
      _ => (BambooInk.ink700, BambooInk.paperMuted),
    };
    return StatusPill(
      label: _ipoStatus(status),
      foreground: fg,
      background: bg,
    );
  }
}

/// The money-in total on a slate decision surface, with the figure in lime —
/// the same treatment the home screen gives its headline number.
class _MoneyInSummary extends StatelessWidget {
  const _MoneyInSummary({required this.total});
  final String total;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg + 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BambooInk.slateRaised, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total money in',
            style: BambooFonts.ui(
              13,
              weight: FontWeight.w600,
              color: BambooInk.onSlateSubtle,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(total, style: BambooFonts.money(30, color: BambooInk.lime)),
          const SizedBox(height: AppSpace.md),
          Text(
            'Refunds reduce your spending, so they are not counted here. '
            'Transfers between your own accounts are left out.',
            style: BambooFonts.ui(
              12.5,
              color: BambooInk.onSlateMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class InstrumentDetailScreen extends ConsumerWidget {
  const InstrumentDetailScreen({super.key, required this.instrumentId});
  final String instrumentId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Account details')),
    body: AppBackground(
      child: ref
          .watch(smsV2LedgerReadModelProvider)
          .when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
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
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.xxl,
                ),
                children: [
                  BambooTitleBlock(
                    title: instrument.displayName,
                    subtitle:
                        '${instrument.issuerSlug.toUpperCase()} ••${instrument.maskDigits ?? 'unknown'}',
                    icon: instrument.kind == InstrumentKind.creditCard
                        ? Icons.credit_card_rounded
                        : Icons.account_balance_outlined,
                    titleSize: 22,
                  ),
                  const SizedBox(height: AppSpace.xl),
                  InstrumentUsageSection(instrument: instrument, model: model),
                ],
              );
            },
          ),
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
    return BambooPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Holds and usage',
            style: BambooFonts.heading(16.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.sm),
          BambooFigureRow('Available', smsMoney(instrument.availableMinor)),
          if (instrument.kind == InstrumentKind.creditCard) ...[
            BambooFigureRow('Limit', smsMoney(instrument.creditLimitMinor)),
            BambooFigureRow('Used', smsMoney(cardUsage(instrument))),
          ],
          BambooFigureRow('Points', '${instrument.pointsBalance ?? 'unknown'}'),
          const SizedBox(height: AppSpace.sm),
          if (holds.isEmpty)
            const BambooNote(
              'No active IPO holds',
              icon: Icons.lock_open_rounded,
            )
          else
            for (final hold in holds)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: BambooNote(
                  '${smsMoney(hold.remainingHoldMinor)} blocked for ${hold.company}',
                  icon: Icons.lock_clock_outlined,
                ),
              ),
        ],
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
    final model = ref.watch(smsV2LedgerReadModelProvider);
    return model.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        child: LinearProgressIndicator(minHeight: 3),
      ),
      error: (_, _) => TextButton.icon(
        style: BambooButtons.quiet,
        onPressed: () => ref.invalidate(smsV2LedgerReadModelProvider),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Retry account details'),
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
