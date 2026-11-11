import '../contract/enums.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import 'projector.dart' show instrumentForFact;
import 'statement_check.dart';

const Duration _ist = Duration(hours: 5, minutes: 30);

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// The Indian calendar day of an instant: a 23:40 UTC message belongs to the
/// next day for a bank that prints dates in IST.
DateTime istDay(DateTime at) => _day(at.toUtc().add(_ist));

// ------------------------------------------------------------------ text

final RegExp _number = RegExp(
  r'(?<![\d,])(?<!\d\.)(\d{1,3}(?:,\d{2,3})*(?:\.\d+)?|\d+(?:\.\d+)?)(?!\d)',
);
final RegExp _cueBefore = RegExp(
  r'(?:rs\.?|inr|₹|by|of|for|amt|amount|debited|credited|sent|paid|received|rcvd|withdrawn|deposited|txn|trf)\s*[:.]?\s*(?:rs\.?|inr|₹)?\s*$',
  caseSensitive: false,
);
final RegExp _monthAfter = RegExp(
  r'^\s*[-/]?\s*(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)',
  caseSensitive: false,
);

/// A number after one of these words is a balance, a limit or a due amount, not
/// the amount that moved.
final RegExp _notMovement = RegExp(
  r'\b(?:avl|avail(?:able)?|bal(?:ance)?|lmt|limit|outstanding|due|min(?:imum)?|total|points?)\b[^0-9]{0,18}$',
  caseSensitive: false,
);

/// Paise for a printed amount such as `12,345.00`, `206.2` or `500`; null if it
/// has more than two decimals that are not zeros.
int? _minor(String printed) {
  final clean = printed.replaceAll(',', '');
  final parts = clean.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  var frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > 2) {
    if (frac.substring(2).replaceAll('0', '').isNotEmpty) return null;
    frac = frac.substring(0, 2);
  }
  final paise = frac.isEmpty ? 0 : int.parse(frac.padRight(2, '0'));
  return whole * 100 + paise;
}

/// The amounts in an SMS [body] that can be the amount of a movement.
///
/// A number counts when it is written as a decimal ("Rs.12345.00", "206.2") or
/// sits after a currency or debit/credit word ("Rs 5,000", "debited by 500").
/// It does not count when a month name follows it ("500 Nov": a date), or when a
/// balance, limit or due word comes just before it ("Avl Bal Rs 22,000.00").
/// A bare "12345" with no cue is a reference or a phone number, never an amount.
List<int> movementAmountsInText(String body) {
  final out = <int>[];
  for (final m in _number.allMatches(body)) {
    final printed = m.group(1)!;
    final minor = _minor(printed);
    if (minor == null || minor <= 0) continue;
    final before = body.substring(m.start > 24 ? m.start - 24 : 0, m.start);
    final after = body.substring(m.end, m.end + 6 > body.length ? body.length : m.end + 6);
    if (_monthAfter.hasMatch(after)) continue;
    if (_notMovement.hasMatch(before)) continue;
    final cueWindow = body.substring(m.start > 14 ? m.start - 14 : 0, m.start);
    if (!printed.contains('.') && !_cueBefore.hasMatch(cueWindow)) continue;
    if (!out.contains(minor)) out.add(minor);
  }
  return out;
}

final RegExp _debitWord = RegExp(r'debit|spent|paid|sent|withdraw|purchase|payment of|\bdr\b', caseSensitive: false);
final RegExp _creditWord = RegExp(r'credit|received|deposit|refund|\bcr\b', caseSensitive: false);

/// The direction an SMS body states, or null when it states none or both.
Direction? directionInText(String body) {
  final d = _debitWord.hasMatch(body), c = _creditWord.hasMatch(body);
  if (d && !c) return Direction.debit;
  if (c && !d) return Direction.credit;
  return null;
}

/// Reference numbers printed in [text]: a run of 9 to 22 digits (a UPI or IMPS
/// reference, a cheque or a transaction number), or an alphanumeric token of 10
/// to 22 characters with both letters and digits (a NEFT or RTGS UTR). Upper
/// case. Two records that print the same reference are the same payment.
Set<String> extractReferences(String text) {
  final out = <String>{};
  for (final token in text.split(RegExp(r'[^A-Za-z0-9]+'))) {
    if (token.length < 9 || token.length > 22) continue;
    final digits = RegExp(r'^\d+$').hasMatch(token);
    final mixed = RegExp(r'[A-Za-z]').hasMatch(token) && RegExp(r'\d').hasMatch(token);
    // A bank's IFSC code (four letters, a zero, six characters) repeats on every
    // transfer to that bank; it is not a reference.
    if (RegExp(r'^[A-Za-z]{4}0[A-Za-z0-9]{6}$').hasMatch(token)) continue;
    if (digits || (mixed && token.length >= 10)) out.add(token.toUpperCase());
  }
  return out;
}

// ------------------------------------------------------------ candidates

/// Something the phone already knows that a statement row could be: one money
/// movement on a bank account, from a parsed fact or from raw SMS text.
final class StatementCandidate {
  const StatementCandidate({
    required this.id,
    required this.at,
    required this.amountsMinor,
    this.primaryAmountMinor,
    this.direction,
    this.references = const {},
    this.accountMask,
    this.issuerSlug,
  });

  /// A parsed money movement. Null when it is not a movement on a bank account
  /// (a card spend, a wallet, an evidence-only receipt, a foreign amount).
  static StatementCandidate? fromFact(
    Fact fact, {
    Map<String, String> instrumentIdByFactId = const {},
    Map<String, Instrument> instrumentsById = const {},
  }) {
    if (fact is! MovementFact || fact.evidenceOnly == true) return null;
    final posted = fact.amount(AmountRole.posted);
    if (posted == null || posted.unit != 'INR' || posted.minor <= 0) return null;
    final instrument = instrumentForFact(
      fact,
      instrumentsById,
      instrumentIdByFactId: instrumentIdByFactId,
    );
    final kind = instrument?.kind ?? fact.instrument?.kind;
    if (kind != null && kind != InstrumentKind.bankAccount && kind != InstrumentKind.debitCard) {
      return null; // a card, wallet or broker: the money is not on this statement
    }
    final onAccount = kind == InstrumentKind.bankAccount;
    return StatementCandidate(
      id: fact.factId,
      at: fact.occurredAt ?? fact.observedAt,
      amountsMinor: [posted.minor],
      primaryAmountMinor: posted.minor,
      direction: fact.direction,
      references: {
        for (final v in fact.references.values) ...extractReferences(v),
        ...extractReferences(fact.counterparty?.name ?? ''),
      },
      accountMask: onAccount ? (instrument?.maskDigits ?? fact.instrument?.maskDigits) : null,
      issuerSlug: onAccount ? (instrument?.issuerSlug ?? fact.instrument?.issuerSlug) : null,
    );
  }

  /// An SMS the phone could not turn into a movement, read for any amount that
  /// could be one. The weakest candidate: amount and date only.
  factory StatementCandidate.fromText({
    required String id,
    required DateTime at,
    required String body,
    String? accountMask,
    String? issuerSlug,
  }) => StatementCandidate(
    id: id,
    at: at,
    amountsMinor: movementAmountsInText(body),
    direction: directionInText(body),
    references: extractReferences(body),
    accountMask: accountMask,
    issuerSlug: issuerSlug,
  );

  final String id;
  final DateTime at;

  /// Every amount this candidate can stand for (one for a fact, any number for
  /// raw text).
  final List<int> amountsMinor;

  /// The one amount of a parsed movement, used to notice a disagreement.
  final int? primaryAmountMinor;
  final Direction? direction;
  final Set<String> references;
  final String? accountMask;
  final String? issuerSlug;
}

// ----------------------------------------------------------------- result

enum MatchBasis {
  /// The row and the candidate print the same reference number.
  reference,

  /// Same amount, same direction, same account, within the window.
  amountDate,

  /// No candidate explains the row.
  none,
}

/// Two rows, one in each of two statements, that are one transfer between the
/// person's own accounts.
final class OwnTransferPair {
  const OwnTransferPair(this.debit, this.credit, {required this.named});
  final StatementRow debit;
  final StatementRow credit;

  /// True when a narration names the owner or the other account, not only the
  /// amount and the day.
  final bool named;
}

final class SmsMatch {
  const SmsMatch(
    this.row,
    this.candidate,
    this.basis, {
    this.dayOffset,
    this.amountConflict = false,
    this.ownTransfer,
  });

  final StatementRow row;

  /// What explains the row; null when nothing does.
  final StatementCandidate? candidate;
  final MatchBasis basis;

  /// Statement day minus SMS day; 0 when they agree, 1 when the bank posted a
  /// day later.
  final int? dayOffset;

  /// A reference matched but the amounts differ: the statement wins and a person
  /// should be told (precedence rule 4).
  final bool amountConflict;

  /// Set when the row is one leg of a transfer between the person's own accounts.
  final OwnTransferPair? ownTransfer;

  bool get hasSms => candidate != null;
}

final class ReconciliationSummary {
  const ReconciliationSummary({
    required this.rows,
    required this.withSms,
    required this.withoutSms,
    required this.ownTransferRows,
    required this.amountConflicts,
    required this.addedInMinor,
    required this.addedOutMinor,
  });

  final int rows;
  final int withSms;
  final int withoutSms;
  final int ownTransferRows;
  final int amountConflicts;

  /// Money in and out on rows no SMS explains, own transfers left out: what an
  /// import adds to the person's picture.
  final int addedInMinor;
  final int addedOutMinor;
}

final class SmsReconciliation {
  const SmsReconciliation({
    required this.matches,
    required this.unmatchedCandidates,
    required this.ownTransfers,
    required this.ambiguousTransferRows,
    required this.summary,
  });

  /// One per row, in the order the rows were given.
  final List<SmsMatch> matches;

  /// SMS movements no statement row explains (an account whose statement was
  /// not imported, or a period outside it).
  final List<StatementCandidate> unmatchedCandidates;
  final List<OwnTransferPair> ownTransfers;

  /// Rows that could be a transfer between own accounts on several readings; no
  /// pair is guessed.
  final List<int> ambiguousTransferRows;
  final ReconciliationSummary summary;
}

// ----------------------------------------------------------------- match

bool _masksAgree(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return true;
  if (a == b) return true;
  final shorter = a.length < b.length ? a : b;
  final longer = a.length < b.length ? b : a;
  return shorter.length >= 3 && longer.endsWith(shorter);
}

bool _sameAccount(StatementRow row, StatementCandidate c) {
  if (row.issuerSlug != null && c.issuerSlug != null && row.issuerSlug != c.issuerSlug) {
    return false;
  }
  return _masksAgree(row.accountMask, c.accountMask);
}

bool _sameDirection(Direction? a, Direction? b) => a == null || b == null || a == b;

/// Does the narration name the owner (two of the name's words, or the only
/// word) or the other account's number?
bool _named(String narration, List<String> ownerNames, String? otherMask) {
  final text = narration.toLowerCase();
  if (otherMask != null && otherMask.length >= 4 && text.contains(otherMask)) return true;
  for (final name in ownerNames) {
    final words = [
      for (final w in name.toLowerCase().split(RegExp(r'\s+')))
        if (w.length >= 3) w,
    ];
    if (words.isEmpty) continue;
    final hits = words.where(text.contains).length;
    if (hits >= (words.length == 1 ? 1 : 2)) return true;
  }
  return false;
}

/// Finds, for every statement row, the SMS movement that already explains it,
/// and pairs the rows that are the two legs of a transfer between the person's
/// own accounts.
///
/// Order of evidence, strongest first:
///
/// 1. **Own transfers**: a debit in one statement and a credit in another, same
///    amount, within a day, are one move of the person's own money. Paired when
///    each side has exactly one such partner, or when narrations name the owner
///    or the account. Otherwise left alone ([SmsReconciliation.ambiguousTransferRows]).
/// 2. **Shared reference**: the row and the SMS print the same reference. Strong
///    enough to link even when the amounts differ; that is flagged, not hidden.
/// 3. **Amount, direction, account and day**: the same amount in the same
///    direction on a compatible account within [dayWindow] days (the bank posts
///    a day or two after the SMS). Every compatible pair is ranked by how close
///    the days are, and the closest pairs are taken first, so a row never takes
///    the SMS that a closer row needs. One SMS explains at most one row.
///
/// Nothing here writes anything: the caller decides what to import. Cost is
/// linear in rows and candidates (an index by amount), so it can run on a phone.
SmsReconciliation reconcileWithSms(
  List<StatementRow> rows,
  Iterable<StatementCandidate> candidates, {
  int dayWindow = 2,
  List<String> ownerNames = const [],
}) {
  final cands = [...candidates]
    ..sort((a, b) {
      final t = a.at.compareTo(b.at);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  final dayOf = [for (final c in cands) istDay(c.at)];
  final rowDay = [for (final r in rows) _day(r.date)];

  final taken = <int>{}; // candidate positions
  final chosen = List<int?>.filled(rows.length, null);
  final basis = List<MatchBasis>.filled(rows.length, MatchBasis.none);
  final offset = List<int?>.filled(rows.length, null);
  final conflict = List<bool>.filled(rows.length, false);

  // 1. Own transfers.
  final pairs = <OwnTransferPair>[];
  final ambiguous = <int>[];
  final pairOf = <int, OwnTransferPair>{};
  {
    final edges = <(int, int, bool)>[]; // debit row, credit row, named
    for (var d = 0; d < rows.length; d++) {
      if (rows[d].direction != Direction.debit) continue;
      for (var c = 0; c < rows.length; c++) {
        if (rows[c].direction != Direction.credit) continue;
        if (rows[d].accountId == rows[c].accountId) continue;
        if (rows[d].amountMinor != rows[c].amountMinor) continue;
        if (rowDay[d].difference(rowDay[c]).inDays.abs() > 1) continue;
        final named = _named(rows[d].narration, ownerNames, rows[c].accountMask) ||
            _named(rows[c].narration, ownerNames, rows[d].accountMask);
        edges.add((d, c, named));
      }
    }
    final paired = <int>{};
    void take(int d, int c, bool named) {
      paired..add(d)..add(c);
      final p = OwnTransferPair(rows[d], rows[c], named: named);
      pairs.add(p);
      pairOf[d] = p;
      pairOf[c] = p;
    }

    int degree(int row, Iterable<(int, int, bool)> among) =>
        among.where((e) => e.$1 == row || e.$2 == row).length;

    final named = [for (final e in edges) if (e.$3) e];
    for (final e in named) {
      if (paired.contains(e.$1) || paired.contains(e.$2)) continue;
      if (degree(e.$1, named) == 1 && degree(e.$2, named) == 1) take(e.$1, e.$2, true);
    }
    final rest = [
      for (final e in edges)
        if (!paired.contains(e.$1) && !paired.contains(e.$2)) e,
    ];
    for (final e in rest) {
      if (paired.contains(e.$1) || paired.contains(e.$2)) continue;
      if (degree(e.$1, rest) == 1 && degree(e.$2, rest) == 1) take(e.$1, e.$2, e.$3);
    }
    final seen = <int>{};
    for (final e in edges) {
      for (final r in [e.$1, e.$2]) {
        if (!paired.contains(r) && seen.add(r)) ambiguous.add(rows[r].index);
      }
    }
  }

  // 2. Shared reference.
  final byReference = <String, List<int>>{};
  for (var j = 0; j < cands.length; j++) {
    for (final ref in cands[j].references) {
      byReference.putIfAbsent(ref, () => []).add(j);
    }
  }
  const referenceWindow = 5;
  for (var i = 0; i < rows.length; i++) {
    int? best;
    var bestGap = 1 << 30;
    for (final ref in extractReferences(rows[i].narration)) {
      for (final j in byReference[ref] ?? const <int>[]) {
        if (taken.contains(j)) continue;
        if (!_sameDirection(rows[i].direction, cands[j].direction) || !_sameAccount(rows[i], cands[j])) {
          continue;
        }
        final gap = rowDay[i].difference(dayOf[j]).inDays;
        if (gap.abs() > referenceWindow || gap.abs() >= bestGap) continue;
        best = j;
        bestGap = gap.abs();
      }
    }
    if (best != null) {
      taken.add(best);
      chosen[i] = best;
      basis[i] = MatchBasis.reference;
      offset[i] = rowDay[i].difference(dayOf[best]).inDays;
      final theirs = cands[best].primaryAmountMinor;
      conflict[i] = theirs != null && theirs != rows[i].amountMinor;
    }
  }

  // 3. Amount, direction, account, day: the closest pairs first.
  final byAmount = <int, List<int>>{};
  for (var j = 0; j < cands.length; j++) {
    for (final a in cands[j].amountsMinor) {
      byAmount.putIfAbsent(a, () => []).add(j);
    }
  }
  final feasible = <(int, int, int)>[]; // |day gap|, row, candidate
  for (var i = 0; i < rows.length; i++) {
    if (chosen[i] != null) continue;
    for (final j in byAmount[rows[i].amountMinor] ?? const <int>[]) {
      if (taken.contains(j)) continue;
      if (!_sameDirection(rows[i].direction, cands[j].direction) || !_sameAccount(rows[i], cands[j])) {
        continue;
      }
      final gap = rowDay[i].difference(dayOf[j]).inDays;
      if (gap.abs() <= dayWindow) feasible.add((gap.abs(), i, j));
    }
  }
  feasible.sort((a, b) {
    final g = a.$1.compareTo(b.$1);
    if (g != 0) return g;
    final r = a.$2.compareTo(b.$2);
    return r != 0 ? r : a.$3.compareTo(b.$3);
  });
  for (final (_, i, j) in feasible) {
    if (chosen[i] != null || taken.contains(j)) continue;
    taken.add(j);
    chosen[i] = j;
    basis[i] = MatchBasis.amountDate;
    offset[i] = rowDay[i].difference(dayOf[j]).inDays;
  }

  final matches = <SmsMatch>[
    for (var i = 0; i < rows.length; i++)
      SmsMatch(
        rows[i],
        chosen[i] == null ? null : cands[chosen[i]!],
        basis[i],
        dayOffset: offset[i],
        amountConflict: conflict[i],
        ownTransfer: pairOf[i],
      ),
  ];

  var withSms = 0, without = 0, transfers = 0, conflicts = 0, inMinor = 0, outMinor = 0;
  for (final m in matches) {
    if (m.ownTransfer != null) transfers++;
    if (m.amountConflict) conflicts++;
    if (m.hasSms) {
      withSms++;
    } else {
      without++;
      if (m.ownTransfer == null) {
        if (m.row.direction == Direction.credit) inMinor += m.row.amountMinor;
        if (m.row.direction == Direction.debit) outMinor += m.row.amountMinor;
      }
    }
  }
  return SmsReconciliation(
    matches: matches,
    unmatchedCandidates: [
      for (var j = 0; j < cands.length; j++)
        if (!taken.contains(j)) cands[j],
    ],
    ownTransfers: pairs,
    ambiguousTransferRows: ambiguous,
    summary: ReconciliationSummary(
      rows: rows.length,
      withSms: withSms,
      withoutSms: without,
      ownTransferRows: transfers,
      amountConflicts: conflicts,
      addedInMinor: inMinor,
      addedOutMinor: outMinor,
    ),
  );
}
