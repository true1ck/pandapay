import '../../../data/cached_regexp.dart';
import '../../../data/spend_reports_repository.dart' show SpendBreakdownRow;
import '../../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import '../understanding/date_grammar.dart';
import '../voice_format.dart';
import 'period_words.dart';
import 'question_model.dart';
import 'spend_data.dart';
import 'voice_answer.dart';

class _Total {
  const _Total(this.rupees, this.count, {this.rewards = 0, this.combined = false});

  final double rupees;
  final int count;
  final double rewards;

  /// Worked out from individual transactions, not read from a report row.
  final bool combined;
}

/// Answers the spend-family questions from the on-phone ledger: totals,
/// by category, merchant, card or payment method, top spends, money in and
/// comparisons. A single filter reads the very row the Spending screen
/// shows; several filters add up the matching transactions and say so.
class SpendAnswerer {
  const SpendAnswerer();

  VoiceAnswer answer(VoiceQuestion q, SpendDataSource s) {
    if (!s.ready) {
      return VoiceAnswer.message(
        'Your history isn’t ready on this phone yet, so I can’t add it up. Try again in a moment.',
        status: AnswerStatus.notReady,
      );
    }
    final earliest = s.earliest;
    if (earliest == null) {
      return VoiceAnswer.message(
        'I don’t have any transactions on this phone yet, so there is nothing to add up.',
        status: AnswerStatus.noData,
      );
    }
    final period = q.period;
    if (period == null) {
      return VoiceAnswer.message('Tell me which days you mean.');
    }
    if (period.to.isBefore(earliest)) {
      return VoiceAnswer.message(
        'My records on this phone start on ${VoiceFormat.day(earliest, s.now)}, so I have nothing for ${PeriodWords.label(period, s.now)}.',
        status: AnswerStatus.noData,
      );
    }
    return switch (q.kind) {
      QuestionKind.spend => _spend(q, s, earliest, period),
      QuestionKind.topSpends => _top(q, s, earliest, period),
      QuestionKind.moneyIn => _moneyIn(q, s, earliest, period),
      QuestionKind.compare => _compare(q, s, earliest, period),
      _ => VoiceAnswer.message('I can’t answer that one yet.'),
    };
  }

  // ---- totals -------------------------------------------------------------------

  static String _norm(String s) =>
      s.toLowerCase().split(cachedRegExp(r'[^a-z0-9]+')).join(' ').trim();

  static bool _merchantMatches(String label, String merchant) {
    final l = _norm(label);
    final wanted = _norm(merchant)
        .split(' ')
        .where((w) => w.length > 2)
        .toList();
    if (wanted.isEmpty) return l.contains(_norm(merchant));
    final have = l.split(' ').toSet();
    return wanted.every(have.contains);
  }

  _Total _total(VoiceQuestion q, SpendDataSource s, DateTime from, DateTime to) {
    if (q.filterCount >= 2) return _fromTransactions(q, s, from, to);
    final r = s.report(from, to);
    double sum(Iterable<SpendBreakdownRow> rows) =>
        rows.fold(0, (a, b) => a + b.total.rupees);
    int count(Iterable<SpendBreakdownRow> rows) =>
        rows.fold(0, (a, b) => a + b.txnCount);
    if (q.category != null) {
      final c = q.category!;
      final rows = (c.parentCategoryId == null ? r.byCategory : r.bySubcategory)
          .where((row) => row.categoryId == c.id || _norm(row.label) == _norm(c.name))
          .toList();
      return _Total(sum(rows), count(rows));
    }
    if (q.merchant != null) {
      final rows = r.byMerchant
          .where((row) => _merchantMatches(row.label, q.merchant!))
          .toList();
      return _Total(sum(rows), count(rows));
    }
    if (q.cards.isNotEmpty) {
      final ids = q.cards.map((c) => c.id).toSet();
      final rows = r.byCard.where((row) => ids.contains(row.cardId)).toList();
      return _Total(
        rows.fold(0, (a, b) => a + b.total.rupees),
        rows.fold(0, (a, b) => a + b.txnCount),
        rewards: rows.fold(0, (a, b) => a + b.rewards.rupees),
      );
    }
    if (q.instrument != null) {
      final rows = r.byInstrument
          .where((row) => row.instrument == q.instrument!.wireValue)
          .toList();
      return _Total(
        rows.fold(0, (a, b) => a + b.total.rupees),
        rows.fold(0, (a, b) => a + b.txnCount),
      );
    }
    return _Total(
      r.spend.total.rupees,
      r.spend.txnCount,
      rewards: r.spend.rewards.rupees,
    );
  }

  _Total _fromTransactions(
    VoiceQuestion q,
    SpendDataSource s,
    DateTime from,
    DateTime to,
  ) {
    final end = DateTime(to.year, to.month, to.day + 1);
    final ids = q.cards.map((c) => c.id).toSet();
    var sum = 0.0;
    var n = 0;
    for (final t in s.transactions) {
      if (t.entryKind != TxnEntryKind.spend || t.status != 'active') continue;
      final at = t.occurredAt.toLocal();
      if (at.isBefore(from) || !at.isBefore(end)) continue;
      if (!_matches(t, q, ids)) continue;
      sum += t.amount.rupees;
      n++;
    }
    return _Total(sum, n, combined: true);
  }

  bool _matches(TransactionEntry t, VoiceQuestion q, Set<String> cardIds) {
    final c = q.category;
    if (c != null &&
        t.categoryId != c.id &&
        t.parentCategoryId != c.id &&
        t.userCategoryId != c.id &&
        t.parentUserCategoryId != c.id) {
      return false;
    }
    if (q.merchant != null &&
        !_merchantMatches(t.merchantName ?? '', q.merchant!)) {
      return false;
    }
    if (cardIds.isNotEmpty && !cardIds.contains(t.userCardId)) return false;
    if (q.instrument != null && t.instrument != q.instrument) return false;
    return true;
  }

  // ---- wording --------------------------------------------------------------------

  String? _filterName(VoiceQuestion q) {
    final parts = <String>[
      if (q.category != null) q.category!.name,
      if (q.merchant != null) q.merchant!,
      if (q.cards.isNotEmpty)
        q.cards.length == 1
            ? (q.cards.first.nickname?.isNotEmpty == true
                  ? q.cards.first.nickname!
                  : q.cards.first.cardName)
            : 'selected cards',
      if (q.instrument != null) q.instrument!.label,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// "this month", "in October", "on Fri 6 Nov", "over the last 7 days".
  static String when(String label) {
    if (label.startsWith('the last ')) return 'over $label';
    if (label.startsWith('this ') ||
        label.startsWith('last ') ||
        label == 'today' ||
        label == 'yesterday' ||
        label.startsWith('since ') ||
        label == 'all time') {
      return label;
    }
    if (cachedRegExp(
      r'^(FY |Q\d |\d{4}$|[A-Z][a-z]+( \d{4})?$)',
    ).hasMatch(label)) {
      return 'in $label';
    }
    if (label.contains(' to ')) return 'from $label';
    return 'on $label';
  }

  String? _comparison(double now, double before, String label) {
    final diff = now - before;
    if (diff.abs() < 0.5) return 'About the same as $label';
    final pct = before.abs() > 0.5
        ? ' (${(diff.abs() / before.abs() * 100).round()}%)'
        : '';
    return '${VoiceFormat.rupees(diff.abs())} ${diff > 0 ? 'more' : 'less'} than $label$pct';
  }

  String? _coverage(DateTime earliest, TimeSpan p, DateTime now) {
    if (p.from.isBefore(earliest.subtract(const Duration(days: 1)))) {
      return 'History on this phone starts ${VoiceFormat.day(earliest, now)}, so earlier spending isn’t included.';
    }
    return null;
  }

  String _evidence(_Total t, TimeSpan p, DateTime now) {
    final range = VoiceFormat.range(p.from, p.to, now);
    final n = '${t.count} transaction${t.count == 1 ? '' : 's'}';
    if (t.combined) return 'Calculated from $n on this phone, $range.';
    return '$n, $range. Same figures as the Spending screen.';
  }

  List<AnswerAction> _actions(VoiceQuestion q, TimeSpan p, {bool spendOnly = true}) {
    final c = q.category;
    return [
      AnswerAction(
        AnswerActionKind.showTransactions,
        'Show transactions',
        from: p.from,
        to: p.to,
        categoryId: q.filterCount == 1 ? c?.id : null,
        categoryLabel: q.filterCount == 1 ? c?.name : null,
        query: q.filterCount == 1 ? q.merchant : null,
        spendOnly: spendOnly,
      ),
      const AnswerAction(AnswerActionKind.spendTrends, 'Open Spending trends'),
      if (q.cards.isNotEmpty)
        const AnswerAction(AnswerActionKind.wallet, 'Open Wallet'),
    ];
  }

  // ---- the questions ---------------------------------------------------------------

  VoiceAnswer _spend(
    VoiceQuestion q,
    SpendDataSource s,
    DateTime earliest,
    TimeSpan p,
  ) {
    final now = s.now;
    final cur = _total(q, s, p.from, p.to);
    final prevSpan = PeriodWords.previous(p);
    final prev =
        prevSpan != null && !prevSpan.from.isBefore(earliest.subtract(const Duration(days: 1)))
        ? _total(q, s, prevSpan.from, prevSpan.to)
        : null;
    final label = PeriodWords.label(p, now);
    final filter = _filterName(q);
    final comparison = prev == null
        ? null
        : _comparison(cur.rupees, prev.rupees, PeriodWords.previousLabel(p, now));
    final amount = VoiceFormat.rupees(cur.rupees);
    final what = filter == null
        ? 'spending'
        : '${filter.toLowerCase()} spending';
    final spoken = cur.count == 0 && cur.rupees == 0
        ? 'I found no $what ${when(label)}.'
        : 'You spent $amount${_spokenFilter(q)} ${when(label)}'
              '${comparison == null ? '' : ', ${_lower(comparison)}'}.';
    return VoiceAnswer(
      title: '${filter ?? 'Spending'} · $label',
      headline: amount,
      comparison: comparison,
      evidence: _evidence(cur, p, now),
      coverageNote: _coverage(earliest, p, now),
      actions: _actions(q, p),
      spoken: spoken,
      status: AnswerStatus.ok,
    );
  }

  String _spokenFilter(VoiceQuestion q) {
    final parts = <String>[];
    if (q.category != null) parts.add('on ${q.category!.name.toLowerCase()}');
    if (q.merchant != null) parts.add('at ${q.merchant}');
    if (q.cards.isNotEmpty) {
      parts.add(
        q.cards.length == 1
            ? 'on your ${q.cards.first.nickname?.isNotEmpty == true ? q.cards.first.nickname : q.cards.first.cardName}'
            : 'on those cards',
      );
    }
    if (q.instrument != null) parts.add('by ${q.instrument!.label.toLowerCase()}');
    return parts.isEmpty ? '' : ' ${parts.join(' ')}';
  }

  static String _lower(String s) =>
      s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';

  VoiceAnswer _top(
    VoiceQuestion q,
    SpendDataSource s,
    DateTime earliest,
    TimeSpan p,
  ) {
    final now = s.now;
    final r = s.report(p.from, p.to);
    final label = PeriodWords.label(p, now);
    final cats = [...r.byCategory]..sort((a, b) => b.total.paise.compareTo(a.total.paise));
    final merchants = [...r.byMerchant]..sort((a, b) => b.total.paise.compareTo(a.total.paise));
    final topCats = cats.where((c) => c.total.paise > 0).take(3).toList();
    final topMerchants = merchants.where((c) => c.total.paise > 0).take(3).toList();
    if (topCats.isEmpty) {
      return VoiceAnswer(
        title: 'Biggest spending · $label',
        headline: VoiceFormat.rupees(0),
        evidence: _evidence(
          _Total(0, 0),
          p,
          now,
        ),
        coverageNote: _coverage(earliest, p, now),
        spoken: 'I found no spending ${when(label)}.',
        actions: _actions(q, p),
      );
    }
    String row(SpendBreakdownRow x) => VoiceFormat.rupees(x.total.rupees);
    final spokenList = [
      for (var i = 0; i < topCats.length; i++)
        '${topCats[i].label} at ${row(topCats[i])}',
    ];
    final spoken =
        'Your biggest category ${when(label)} was ${spokenList.first}'
        '${spokenList.length > 1 ? ', then ${spokenList.skip(1).join(' and ')}' : ''}.';
    return VoiceAnswer(
      title: 'Biggest spending · $label',
      headline: '${topCats.first.label} · ${row(topCats.first)}',
      rows: [
        for (final c in topCats)
          AnswerRow(
            c.label,
            row(c),
            detail: '${c.txnCount} transaction${c.txnCount == 1 ? '' : 's'}',
          ),
        for (final m in topMerchants)
          AnswerRow(
            'At ${m.label}',
            row(m),
            detail: '${m.txnCount} transaction${m.txnCount == 1 ? '' : 's'}',
          ),
      ],
      evidence: _evidence(
        _Total(r.spend.total.rupees, r.spend.txnCount),
        p,
        now,
      ),
      coverageNote: _coverage(earliest, p, now),
      actions: _actions(q, p),
      spoken: spoken,
    );
  }

  VoiceAnswer _moneyIn(
    VoiceQuestion q,
    SpendDataSource s,
    DateTime earliest,
    TimeSpan p,
  ) {
    final now = s.now;
    final r = s.report(p.from, p.to);
    final label = PeriodWords.label(p, now);
    final prevSpan = PeriodWords.previous(p);
    final prev =
        prevSpan != null && !prevSpan.from.isBefore(earliest.subtract(const Duration(days: 1)))
        ? s.report(prevSpan.from, prevSpan.to).income.total.rupees
        : null;
    final amount = VoiceFormat.rupees(r.income.total.rupees);
    final comparison = prev == null
        ? null
        : _comparison(
            r.income.total.rupees,
            prev,
            PeriodWords.previousLabel(p, now),
          );
    final n = r.income.txnCount;
    return VoiceAnswer(
      title: 'Money in · $label',
      headline: amount,
      comparison: comparison,
      evidence:
          '$n entr${n == 1 ? 'y' : 'ies'}, ${VoiceFormat.range(p.from, p.to, now)}. Same figures as the Spending screen.',
      coverageNote: _coverage(earliest, p, now),
      actions: [
        AnswerAction(
          AnswerActionKind.showTransactions,
          'Show transactions',
          from: p.from,
          to: p.to,
          spendOnly: false,
        ),
        const AnswerAction(AnswerActionKind.spendTrends, 'Open Spending trends'),
      ],
      spoken: r.income.total.paise == 0
          ? 'I found no money coming in ${when(label)}.'
          : '$amount came in ${when(label)}${comparison == null ? '' : ', ${_lower(comparison)}'}.',
    );
  }

  VoiceAnswer _compare(
    VoiceQuestion q,
    SpendDataSource s,
    DateTime earliest,
    TimeSpan a,
  ) {
    final now = s.now;
    final b = q.comparePeriod ?? PeriodWords.previous(a);
    if (b == null) {
      return VoiceAnswer.message('I need a second period to compare with.');
    }
    final ta = _total(q, s, a.from, a.to);
    final tb = _total(q, s, b.from, b.to);
    final la = PeriodWords.label(a, now);
    final lb = PeriodWords.label(b, now);
    final filter = _filterName(q);
    final diff = ta.rupees - tb.rupees;
    final comparison = _comparison(ta.rupees, tb.rupees, lb);
    final amountA = VoiceFormat.rupees(ta.rupees);
    final amountB = VoiceFormat.rupees(tb.rupees);
    final spokenDiff = diff.abs() < 0.5
        ? 'about the same'
        : '${VoiceFormat.rupees(diff.abs())} ${diff > 0 ? 'more' : 'less'}';
    final note = [
      _coverage(earliest, a, now),
      _coverage(earliest, b, now),
    ].whereType<String>().toSet().join(' ');
    return VoiceAnswer(
      title: '${filter ?? 'Spending'} · $la vs $lb',
      headline: '$amountA vs $amountB',
      comparison: comparison,
      rows: [
        AnswerRow(la, amountA, detail: '${ta.count} transactions'),
        AnswerRow(lb, amountB, detail: '${tb.count} transactions'),
      ],
      evidence: ta.combined
          ? 'Calculated from the matching transactions on this phone.'
          : 'Same figures as the Spending screen for each period.',
      coverageNote: note.isEmpty ? null : note,
      actions: _actions(q, a),
      spoken:
          'You spent $amountA ${when(la)}, against $amountB ${when(lb)}, which is $spokenDiff.',
    );
  }
}
