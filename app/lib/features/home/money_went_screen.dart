import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/sms_v2.dart' show Totals;

import '../../app/design/app_theme.dart';
import '../sms_v2/ledger/providers.dart';

String _m(int minor) => Money.fromPaise(minor).format(compact: true);

/// Money in / Money out with their splits, and Invested / Withdrawn / net on
/// one line. Additive lines under the Home spend card; same Totals as Activity.
class MoneyFlowLines extends StatelessWidget {
  final Totals totals;

  /// The period the totals cover (the report's start, and its end, which is
  /// exclusive). A tapped line opens Activity on exactly this period, as Spend
  /// Trends does, so the list adds up to the number that was tapped. Without
  /// them Activity opens on all time.
  final DateTime? periodStart;
  final DateTime? periodEnd;
  const MoneyFlowLines({
    super.key,
    required this.totals,
    this.periodStart,
    this.periodEnd,
  });

  /// `/activity?type=<type>` plus this period's first and last day.
  String _activityPath(String type) {
    final start = periodStart;
    final end = periodEnd;
    if (start == null || end == null) return '/activity?type=$type';
    String day(DateTime v) {
      final d = v.toLocal();
      return '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    return Uri(
      path: '/activity',
      queryParameters: {
        'type': type,
        'from': day(start),
        'to': day(end.subtract(const Duration(days: 1))),
      },
    ).toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = totals;
    final lines = <(String, String)>[
      (
        'Money in ${_m(t.moneyInMinor)}',
        'Income ${_m(t.earnedIncomeMinor)} · Returns ${_m(t.investmentReturnsMinor)}'
            ' · Withdrawn ${_m(t.withdrawnMinor)} · From people ${_m(t.fromPeopleMinor)}',
      ),
      (
        'Money out ${_m(t.moneyOutMinor)}',
        'Spending ${_m(t.spendMinor)} · Left out ${_m(t.excludedSpendMinor)}'
            ' · Invested ${_m(t.investmentOutMinor)}',
      ),
      if (t.investmentOutMinor > 0 || t.withdrawnMinor > 0)
        (
          'Investments',
          'Invested ${_m(t.investmentOutMinor)} · Withdrawn ${_m(t.withdrawnMinor)}'
              ' · Net ${_m(t.investmentOutMinor - t.withdrawnMinor)}',
        ),
    ];
    return Column(
      key: const Key('home_money_flow'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (head, split) in lines)
          InkWell(
            key: head == 'Investments'
                ? const Key('home_investments_line')
                : head.startsWith('Money in')
                ? const Key('home_money_in_line')
                : null,
            onTap: head == 'Investments'
                ? () => context.push(_activityPath('investments'))
                : head.startsWith('Money in')
                ? () => context.push(_activityPath('moneyIn'))
                : null,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$head  ',
                      style: BambooFonts.ui(
                        10.5,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                    TextSpan(
                      text: split,
                      style: BambooFonts.ui(9.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// "Where your money went": Money out, then the bridge to what left bank accounts.
class MoneyWentScreen extends ConsumerWidget {
  const MoneyWentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(smsV2LedgerReadModelProvider).valueOrNull;
    final now = DateTime.now();
    final b = model?.moneyBridge(
      DateTime(now.year, now.month),
      DateTime(now.year, now.month + 1),
    );
    final rows = b == null
        ? const <(String, int)>[]
        : [
            ('Money out (spending + invested)', b.moneyOut),
            ('Less: card and wallet spending', -b.cardWalletSpend),
            ('Card bills paid', b.cardBillsPaid),
            ('Transfers', b.transfers),
            ('Left your accounts', b.leftYourAccounts),
          ];
    return Scaffold(
      appBar: AppBar(title: const Text('Where your money went')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (b == null) const Text('Nothing to show yet.'),
          for (final (label, v) in rows)
            ListTile(
              dense: true,
              title: Text(label),
              trailing: Text(v < 0 ? '-${_m(-v)}' : _m(v)),
            ),
          if (b != null && b.family > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Includes ${_m(b.family)} to family',
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
            ),
        ],
      ),
    );
  }
}
