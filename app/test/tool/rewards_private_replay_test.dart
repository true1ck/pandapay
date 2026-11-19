// Replays a person's real card spends through the Rewards page's own report to
// see what the Missed tab would say for them. A tool, not a unit test: it is
// skipped unless REWARDS_REPLAY_DIR names a folder with the four files below,
// and it prints figures (and a few merchant names) only to the console.
//
//   catalogue_v2.json   GET /catalogue?schema=2 (public)
//   categories.json     GET /categories (public)
//   owner_wallet.json   the person's user_cards rows
//   owner_txn.json      their active credit-card spend rows, with category slug
//
// How the two owner files are exported (read-only SQL) is in
// docs/rewards-missed-fix-2026-11-19.md. Run:
//
//   REWARDS_REPLAY_DIR=/path/to/dir flutter test test/tool/rewards_private_replay_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_v2.dart';
import 'package:pandapay/data/reward_counting.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/rewards/rewards_comparison.dart';
import 'package:pandapay/features/insights/rewards/rewards_filter.dart';
import 'package:pandapay/features/insights/rewards/rewards_report.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  final dir = Platform.environment['REWARDS_REPLAY_DIR'];

  test(
    'what the Missed tab says for real spends',
    () {
      final feed = parseCatalogueBody(
        jsonDecode(File('$dir/catalogue_v2.json').readAsStringSync()),
        schema: 2,
        origin: CatalogueOrigin.liveV2,
      );
      final byProduct = {for (final c in feed.cards) c.id: c};
      final categories =
          (jsonDecode(File('$dir/categories.json').readAsStringSync())
                  as Map)['categories']
              as List;
      final slugById = {
        for (final c in categories) c['id'] as String: c['slug'] as String,
      };
      final walletJson =
          (jsonDecode(File('$dir/owner_wallet.json').readAsStringSync())
                  as List)
              .cast<Map<String, dynamic>>();
      final wallet = <(UserCard, CardProduct)>[];
      for (final row in walletJson) {
        if (row['is_archived'] == true) continue;
        final product = byProduct[row['card_product_id']];
        if (product == null) continue;
        wallet.add((
          UserCard(
            id: row['id'] as String,
            cardProductId: product.id,
            cardName: product.name,
            isDefault: false,
            last4: row['last4'] as String?,
            openedOn: row['opened_on'] == null
                ? null
                : DateTime.parse(row['opened_on'] as String),
          ),
          product,
        ));
      }
      final entries = [
        for (final row
            in (jsonDecode(File('$dir/owner_txn.json').readAsStringSync())
                    as List)
                .cast<Map<String, dynamic>>())
          TransactionEntry.fromJson({
            ...row,
            // What the phone's ledger row carries for a card spend.
            'instrument': 'credit_card',
            'entry_kind': 'spend',
            'source': 'sms',
          }),
      ];

      final last = entries.map((e) => e.occurredAt).reduce(
        (a, b) => a.isAfter(b) ? a : b,
      );
      final lastDay = DateTime(last.year, last.month, last.day);
      final ranges = <String, RewardsRange>{
        'last 30 days': RewardsRange.days(
          lastDay.subtract(const Duration(days: 29)),
          lastDay,
        ),
        'this month': RewardsRange.days(
          DateTime(lastDay.year, lastDay.month),
          lastDay,
        ),
        'last 3 months': RewardsRange.days(
          DateTime(lastDay.year, lastDay.month - 3, lastDay.day + 1),
          lastDay,
        ),
        'last 12 months': RewardsRange.days(
          DateTime(lastDay.year - 1, lastDay.month, lastDay.day + 1),
          lastDay,
        ),
        'everything': RewardsRange.days(
          entries.map((e) => e.occurredAt).reduce(
            (a, b) => a.isBefore(b) ? a : b,
          ),
          lastDay,
        ),
      };

      final out = StringBuffer()
        ..writeln(
          '${entries.length} card spends, ${wallet.length} wallet cards '
          '(${{for (final (_, p) in wallet) p.id}.length} products)',
        );
      final firstUse = firstCardUseOf(entries);
      for (final MapEntry(key: label, value: range) in ranges.entries) {
        final stopwatch = Stopwatch()..start();
        final checks = computeSpendChecks(
          buildRewardsComparisonRequest(
            transactions: [
              for (final e in entries)
                if (range.contains(e.occurredAt)) e,
            ],
            walletCards: wallet,
            firstUseByCardId: firstUse,
            categorySlugById: slugById,
            directory: feed.directory,
          ),
        );
        final report = buildRewardsReport(
          transactions: entries,
          range: range,
          walletCards: wallet,
          checks: checks,
        );
        out
          ..writeln('')
          ..writeln(
            '== $label: ${report.rows.length} spends, '
            'earned ${report.earned.format(hidePaise: true)} on '
            '${report.spend.format(hidePaise: true)} '
            '| MISSED ${report.missed.format(hidePaise: true)} '
            'on ${report.missedCount} spends '
            '(checked ${report.comparedCount}) [${stopwatch.elapsedMilliseconds} ms]',
          );
        final patterns = <String, (int, Money)>{};
        for (final row in report.missedRows) {
          final key =
              '${report.cardLabel(row.entry.userCardId!)} -> '
              '${row.missed!.betterCard!.name.replaceAll('\n', ' ')}';
          final seen = patterns[key];
          patterns[key] = (
            (seen?.$1 ?? 0) + 1,
            (seen?.$2 ?? const Money.zero()) + row.missedValue,
          );
        }
        for (final entry
            in (patterns.entries.toList()
                  ..sort((a, b) => b.value.$2.paise.compareTo(a.value.$2.paise)))
                .take(5)) {
          out.writeln(
            '   ${entry.key}: ${entry.value.$1} spends, '
            '${entry.value.$2.format(hidePaise: true)}',
          );
        }
        if (label == 'last 30 days' || label == 'last 3 months') {
          for (final row in report.missedRows.take(8)) {
            final m = row.missed!;
            out.writeln(
              '   ${row.entry.occurredAt.toIso8601String().substring(0, 10)} '
              '${(row.entry.merchantName ?? '').padRight(20).substring(0, 20)} '
              '${row.entry.amount.format(hidePaise: true).padLeft(9)} '
              '${(m.usedRate * 100).toStringAsFixed(1)}% -> '
              '${(m.betterRate * 100).toStringAsFixed(1)}% '
              '(${m.betterCard!.name.replaceAll('\n', ' ')}) '
              '+${row.missedValue.format(hidePaise: true)}',
            );
          }
        }
      }
      // ignore: avoid_print
      print(out);
      expect(entries, isNotEmpty);
    },
    skip: dir == null
        ? 'set REWARDS_REPLAY_DIR to a folder of exported files'
        : false,
  );
}
