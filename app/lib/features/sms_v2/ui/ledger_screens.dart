import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../activity/transaction_detail_screen.dart';
import '../ledger/adapters.dart';
import '../ledger/providers.dart';
import '../ledger/reports.dart';
import '../instruments/issuer_slugs.dart';
import 'screen_parts.dart';

enum SmsLedgerScreen { investments, ipos, moneyIn }

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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => InvestmentPlatformScreen(summary: item),
                  ),
                ),
                semanticLabel: item.platform,
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
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => IpoApplicationScreen(application: item),
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: BambooInk.ink500,
                  ),
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
                  // The full transaction page: details, category, notes, edit.
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TransactionDetailScreen(
                        transactionId: 'v2:${item.eventId}',
                      ),
                    ),
                  ),
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
    }
    if (children.isEmpty) {
      return SmsEmpty(
        'Nothing here yet. Your imported messages will fill this in.',
        icon: switch (screen) {
          SmsLedgerScreen.investments => Icons.show_chart_rounded,
          SmsLedgerScreen.ipos => Icons.lock_clock_outlined,
          SmsLedgerScreen.moneyIn => Icons.south_west_rounded,
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

/// An investment platform opened in full: its totals, then every movement behind
/// them. Each movement opens as a transaction, where it can be reviewed and
/// edited like any other.
class InvestmentPlatformScreen extends StatelessWidget {
  const InvestmentPlatformScreen({super.key, required this.summary});
  final InvestmentSummary summary;

  static String _kindLabel(String kind) => switch (kind) {
    'taken_out' => 'Taken out',
    'dividend' => 'Dividend',
    _ => 'Put in',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(summary.platform)),
    body: AppBackground(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.xxl,
        ),
        children: [
          BambooPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InlineFigures([
                  ('Net invested', smsMoney(summary.netInvestedMinor)),
                ], size: 18),
                const SizedBox(height: AppSpace.sm),
                _InlineFigures([
                  ('Put in', smsMoney(summary.putInMinor)),
                  ('Taken out', smsMoney(summary.takenOutMinor)),
                ]),
                _InlineFigures([
                  if (summary.balanceMinor != null)
                    ('Fund balance', smsMoney(summary.balanceMinor!)),
                  ('Dividends', smsMoney(summary.dividendMinor)),
                ]),
              ],
            ),
          ),
          BambooSectionLabel(
            'Movements',
            asTitle: true,
            trailing: '${summary.entries.length}',
          ),
          if (summary.entries.isEmpty)
            const SmsEmpty(
              'No movements yet. Your imported messages will fill this in.',
              icon: Icons.show_chart_rounded,
            )
          else
            _RowGroup([
              for (final e in summary.entries)
                ListTile(
                  contentPadding: _rowPadding,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TransactionDetailScreen(
                        transactionId: 'v2:${e.eventId}',
                      ),
                    ),
                  ),
                  leading: BambooIconTile(
                    e.kind == 'taken_out'
                        ? Icons.south_west_rounded
                        : e.kind == 'dividend'
                        ? Icons.savings_outlined
                        : Icons.north_east_rounded,
                    size: 36,
                  ),
                  title: Text(e.label),
                  subtitle: Text(
                    '${_kindLabel(e.kind)} • ${smsDate(e.occurredAt)}',
                  ),
                  trailing: Text(
                    smsMoney(e.amountMinor),
                    style: BambooFonts.money(14.5, weight: FontWeight.w700),
                  ),
                ),
            ]),
        ],
      ),
    ),
  );
}

/// One IPO application in full: what was blocked, invested and released, where
/// and when, and a way into the transaction behind it.
class IpoApplicationScreen extends StatelessWidget {
  const IpoApplicationScreen({super.key, required this.application});
  final IpoApplication application;

  @override
  Widget build(BuildContext context) {
    final a = application;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w600,
                color: BambooInk.ink900,
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('IPO application')),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.xxl,
          ),
          children: [
            BambooPanel(
              child: Row(
                children: [
                  const BambooIconTile(Icons.lock_clock_outlined),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Text(
                      a.company,
                      style: BambooFonts.heading(17, color: BambooInk.ink900),
                    ),
                  ),
                  _IpoStatusPill(a.status),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            _RowGroup([
              row('Blocked', smsMoney(a.blockedMinor)),
              row('Invested', smsMoney(a.investedMinor)),
              row('Released', smsMoney(a.releasedMinor)),
              if (a.remainingHoldMinor > 0)
                row('Still held by the bank', smsMoney(a.remainingHoldMinor)),
              row('Platform', a.platform ?? 'Not stated'),
              row('Account', '••${a.accountMask ?? 'unknown'}'),
              if (a.appliedAt != null) row('Applied', smsDate(a.appliedAt!)),
              if (a.updatedAt != null)
                row('Last update', smsDate(a.updatedAt!)),
              if (a.noAllotmentNoticeAt != null)
                row(
                  'No allotment notice',
                  '${smsDate(a.noAllotmentNoticeAt!)} • your bank should release the money',
                ),
            ]),
            if (a.investedMinor > 0) ...[
              const SizedBox(height: AppSpace.lg),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TransactionDetailScreen(
                      transactionId: 'v2:${a.eventId}',
                    ),
                  ),
                ),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Open transaction'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
