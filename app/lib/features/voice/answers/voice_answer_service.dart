import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart' show AppRoute;
import '../../../data/user_cards_repository.dart' show UserCard;
import '../../cards/cap_progress.dart';
import '../../sms_v2/ledger/providers.dart' show smsV2LedgerReadModelProvider;
import '../voice_format.dart';
import 'card_answers.dart';
import 'question_model.dart';
import 'spend_answers.dart';
import 'spend_data.dart';
import 'voice_answer.dart';

/// Gathers the data a question needs from the app's own providers and hands
/// it to the answerers. Nothing here leaves the phone: the transcript is not
/// sent anywhere, and the data is the same the matching screens read.
class VoiceAnswerService {
  const VoiceAnswerService(this.ref);

  final WidgetRef ref;

  Future<VoiceAnswer> answer(VoiceQuestion q) async {
    try {
      final now = ref.read(clockProvider).now();
      switch (q.kind) {
        case QuestionKind.spend:
        case QuestionKind.topSpends:
        case QuestionKind.moneyIn:
        case QuestionKind.compare:
          final model = await ref.read(smsV2LedgerReadModelProvider.future);
          return const SpendAnswerer().answer(q, LedgerSpendSource(model, now));
        case QuestionKind.billsDue:
          return await _bills(q, now);
        case QuestionKind.capsLeft:
          return _caps(q, now);
        case QuestionKind.pointsBalance:
          return _points(q, now);
        case QuestionKind.bestCard:
          return _bestCard(q);
        case QuestionKind.unknown:
          return VoiceAnswer.message(
            'I can’t answer that yet. I can add up your spending, show bills due, caps left, points, and pick a card for a purchase.',
          );
      }
    } catch (_) {
      return VoiceAnswer.message(
        'I couldn’t read that from your data just now. Please try again.',
        status: AnswerStatus.notReady,
      );
    }
  }

  String _name(UserCard c) =>
      c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName;

  List<UserCard> _cards(VoiceQuestion q) {
    final all = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    if (q.cards.isEmpty) return all;
    final ids = q.cards.map((c) => c.id).toSet();
    return all.where((c) => ids.contains(c.id)).toList();
  }

  Future<VoiceAnswer> _bills(VoiceQuestion q, DateTime now) async {
    final cards = _cards(q);
    final ledgers = await ref.read(cardBillLedgerProvider.future);
    final lines = <BillLine>[];
    for (final c in cards) {
      final bill = ledgers[c.id]?.current;
      if (bill == null || !bill.isCurrentAsOf(now)) {
        lines.add(BillLine(cardName: _name(c), hasBill: false));
        continue;
      }
      lines.add(
        BillLine(
          cardName: _name(c),
          dueDate: bill.dueDate,
          amountDue: bill.amountDue?.rupees,
          outstanding: bill.outstanding?.rupees,
          minimumDue: bill.minimumDue?.rupees,
          isPaid: bill.isPaid,
          isAutopay: bill.isAutopay,
        ),
      );
    }
    return const BillsAnswerer().answer(
      lines,
      now,
      cardsNamed: q.cards.isNotEmpty,
    );
  }

  VoiceAnswer _caps(VoiceQuestion q, DateTime now) {
    final owned =
        ref.read(ownedCardsWithProductProvider).valueOrNull ??
        const <(UserCard, CardProduct)>[];
    final ids = q.cards.map((c) => c.id).toSet();
    final lines = <CapLine>[];
    for (final (card, product) in owned) {
      if (ids.isNotEmpty && !ids.contains(card.id)) continue;
      lines.addAll(_capLines(card, product));
    }
    return const CapsAnswerer().answer(lines, cardsNamed: q.cards.isNotEmpty);
  }

  List<CapLine> _capLines(UserCard card, CardProduct product) {
    final now = ref.read(clockProvider).now();
    final name = _name(card);
    final out = <CapLine>[];
    if (product.isV2Shaped) {
      for (final p in capProgressesFor(
        product: product,
        owned: card,
        now: now,
      )) {
        if (p.isUnknown) continue;
        final used = p.consumed ?? 0;
        final remaining = (p.amount - used).clamp(0, p.amount).toDouble();
        out.add(
          CapLine(
            cardName: name,
            label: p.cap.label,
            remaining: switch (p.unit) {
              CapUnit.points => '${formatNative(remaining)} pts left',
              CapUnit.uses => '${formatNative(remaining)} uses left',
              _ => '${VoiceFormat.rupees(remaining)} left',
            },
            used: p.consumptionText,
            reset: p.resetText,
            ratio: p.ratio,
            reached: p.isReached,
            consequence: p.reachedConsequence,
          ),
        );
      }
      return out;
    }
    for (final cap in uniqueCapRules(product.capRules)) {
      final limit = cap.capValue.rupees;
      if (limit <= 0) continue;
      final used = card.capConsumed[cap.id]?.rupees ?? 0.0;
      out.add(
        CapLine(
          cardName: name,
          label: cap.label,
          remaining:
              '${VoiceFormat.rupees((limit - used).clamp(0, limit).toDouble())} left',
          used: '${VoiceFormat.rupees(used)} / ${VoiceFormat.rupees(limit)}',
          reset: 'resets each ${cap.period.name}',
          ratio: (used / limit).clamp(0.0, 1.0),
          reached: used >= limit,
        ),
      );
    }
    return out;
  }

  VoiceAnswer _points(VoiceQuestion q, DateTime now) {
    final owned =
        ref.read(ownedCardsWithProductProvider).valueOrNull ??
        const <(UserCard, CardProduct)>[];
    final ids = q.cards.map((c) => c.id).toSet();
    final lines = <PointsLine>[];
    for (final (card, product) in owned) {
      if (ids.isNotEmpty && !ids.contains(card.id)) continue;
      // The same figure the card screen shows: what the card has earned (the
      // points ledger plus any starting balance the user typed in). The server
      // always sends a saved balance, 0 by default, so that cannot come first.
      // A card with nothing at all is "unknown", not zero.
      final saved = card.pointsBalance;
      final points = card.totalPointsEarned > 0
          ? card.totalPointsEarned
          : (saved != null && saved > 0 ? saved : null);
      DateTime? expiry;
      final ledger = ref.read(pointsLedgerProvider(card.id)).valueOrNull;
      if (ledger != null) {
        final today = DateTime(now.year, now.month, now.day);
        final upcoming =
            ledger
                .where(
                  (e) => e.expiresOn != null && !e.expiresOn!.isBefore(today),
                )
                .map((e) => e.expiresOn!)
                .toList()
              ..sort();
        if (upcoming.isNotEmpty) expiry = upcoming.first;
      }
      lines.add(
        PointsLine(
          cardName: _name(card),
          points: points,
          valueRupees: points == null ? null : points * product.pointValueInr,
          nearestExpiry: expiry,
        ),
      );
    }
    return const PointsAnswerer().answer(
      lines,
      now,
      cardsNamed: q.cards.isNotEmpty,
    );
  }

  VoiceAnswer _bestCard(VoiceQuestion q) {
    final amount = q.amount;
    final recs = ref.read(
      quickAddRecommendationsProvider((
        amount: Money.fromRupees(amount ?? BestCardAnswerer.defaultAmount),
        categoryId: q.category?.id,
        categorySlug: q.category?.slug,
        merchantName: q.merchant,
        transactionDate: null,
      )),
    );
    final list = recs.valueOrNull;
    if (list == null) {
      return VoiceAnswer.message(
        'I’m still loading your cards. Try again in a moment.',
        status: AnswerStatus.notReady,
      );
    }
    final wallet =
        ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    String nameOf(CardProduct product) {
      for (final c in wallet) {
        if (c.cardProductId == product.id) return _name(c);
      }
      return product.name;
    }

    return const BestCardAnswerer().answer(
      [
        for (final r in list)
          RecoLine(
            cardName: nameOf(r.card),
            expectedValue: r.expectedValue.rupees,
            reason: r.reasonLines.isEmpty ? null : r.reasonLines.first,
            excluded: r.isExcluded,
          ),
      ],
      amount: amount,
      merchant: q.merchant,
      categoryName: q.category?.name,
    );
  }
}

/// The screen an answer button opens.
String routeFor(AnswerAction a) {
  switch (a.kind) {
    case AnswerActionKind.showTransactions:
      final q = <String, String>{
        if (a.categoryId != null) 'category': a.categoryId!,
        if (a.categoryLabel != null) 'categoryLabel': a.categoryLabel!,
        if (a.from != null) 'from': _date(a.from!),
        if (a.to != null) 'to': _date(a.to!),
        if (a.spendOnly) 'spendOnly': 'true',
        if (a.query != null && a.query!.isNotEmpty) 'q': a.query!,
      };
      return Uri(
        path: AppRoute.activity,
        queryParameters: q.isEmpty ? null : q,
      ).toString();
    case AnswerActionKind.spendTrends:
      return AppRoute.spendTrends;
    case AnswerActionKind.paymentsDue:
      return AppRoute.paymentsGroup;
    case AnswerActionKind.caps:
      return AppRoute.caps;
    case AnswerActionKind.milestones:
      return AppRoute.milestones;
    case AnswerActionKind.wallet:
      return AppRoute.cards;
    case AnswerActionKind.home:
      return AppRoute.home;
    case AnswerActionKind.pointsExpiry:
      return AppRoute.pointsExpiry;
  }
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
