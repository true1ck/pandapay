import '../contract/enums.dart';

/// One printed line of a bank statement, after parsing and before it is trusted.
///
/// Pure data. Reading a PDF into rows is the importer's job (E1); this file only
/// decides whether the rows can be believed ([verifyStatement]) and later which
/// of them an SMS already explains (`statement_match.dart`).
final class StatementRow {
  const StatementRow({
    required this.index,
    required this.date,
    required this.amountMinor,
    this.direction,
    this.balanceMinor,
    this.narration = '',
    this.accountMask,
    this.issuerSlug,
    this.accountId = '',
  });

  /// Position in the printed statement, 0-based. Stable across [verifyStatement]
  /// reordering, so a finding can be traced to the printed line.
  final int index;

  /// The calendar date the bank printed. Only year, month and day are read.
  final DateTime date;

  /// Always positive, in paise.
  final int amountMinor;

  /// Null when the layout prints no debit/credit column; [verifyStatement]
  /// infers it from the running balance.
  final Direction? direction;

  /// The running balance printed after this row, when the layout has one.
  final int? balanceMinor;

  /// The bank's narration, as printed (reference numbers, names, UPI ids).
  final String narration;

  /// The account number as printed (digits only; any length of ending).
  final String? accountMask;
  final String? issuerSlug;

  /// Which statement the row came from. Rows of two different statements can be
  /// the two legs of a transfer between the person's own accounts.
  final String accountId;

  StatementRow copyWith({Direction? direction}) => StatementRow(
    index: index,
    date: date,
    amountMinor: amountMinor,
    direction: direction ?? this.direction,
    balanceMinor: balanceMinor,
    narration: narration,
    accountMask: accountMask,
    issuerSlug: issuerSlug,
    accountId: accountId,
  );

  int get _signed => direction == Direction.credit ? amountMinor : -amountMinor;
}

/// What [verifyStatement] found.
final class StatementCheck {
  const StatementCheck({
    required this.rows,
    required this.chainBreaks,
    required this.directionUnknown,
    required this.reversed,
    required this.verifiedSomething,
    this.openingMatches,
    this.closingMatches,
    this.debitTotalMatches,
    this.creditTotalMatches,
    this.debitCountMatches,
    this.creditCountMatches,
  });

  /// The rows oldest first, with `direction` filled in where it could be read
  /// from the balance. Use these, not the printed order, for everything after.
  final List<StatementRow> rows;

  /// Rows whose printed balance does not follow from the row before it: the row
  /// itself was misread, or a row between the two is missing. Both mean "do not
  /// trust this row yet".
  final List<int> chainBreaks;

  /// Rows whose direction could be neither read nor inferred.
  final List<int> directionUnknown;

  /// True when the statement was printed newest first and was turned around.
  final bool reversed;

  /// False when the statement printed nothing to check against (no balances and
  /// no totals). Such a statement is never trusted.
  final bool verifiedSomething;

  final bool? openingMatches;
  final bool? closingMatches;
  final bool? debitTotalMatches;
  final bool? creditTotalMatches;
  final bool? debitCountMatches;
  final bool? creditCountMatches;

  /// Printed indexes of rows that must be shown to the person, not imported.
  Set<int> get suspectRows => {...chainBreaks, ...directionUnknown};

  List<String> get problems => [
    if (rows.isEmpty) 'the statement has no rows',
    if (!verifiedSomething && rows.isNotEmpty)
      'the statement prints no balance or total to check the rows against',
    if (chainBreaks.isNotEmpty)
      '${chainBreaks.length} row(s) do not follow the running balance',
    if (directionUnknown.isNotEmpty)
      '${directionUnknown.length} row(s) have no readable direction',
    if (openingMatches == false) 'the opening balance does not match the first row',
    if (closingMatches == false) 'the closing balance does not match the last row',
    if (debitTotalMatches == false) 'the rows do not add up to the printed total of debits',
    if (creditTotalMatches == false) 'the rows do not add up to the printed total of credits',
    if (debitCountMatches == false) 'the number of debit rows differs from the printed count',
    if (creditCountMatches == false) 'the number of credit rows differs from the printed count',
  ];

  /// Every row can be believed: the balance chain holds from the first row to
  /// the last, every printed total and count agrees, and something was checked.
  bool get trusted => problems.isEmpty;
}

/// Checks parsed [printed] rows against what the statement itself prints.
///
/// A parser that reads one digit wrong, or drops a row, produces a statement
/// that looks fine. The running balance catches both: every row's balance must
/// equal the row before it plus or minus the row's amount. So does the total of
/// debits and credits, and the opening and closing balance.
///
/// - Rows may be printed oldest or newest first; a statement whose first date is
///   after its last is turned around.
/// - A layout with no debit/credit column (only an amount and a balance) has its
///   directions inferred from the change in balance. The first row needs the
///   opening balance for that.
/// - A break does not stop the check: the next row is compared with this row's
///   printed balance, so one misread row marks one row, and a missing row marks
///   the row after the gap.
StatementCheck verifyStatement(
  List<StatementRow> printed, {
  int? openingMinor,
  int? closingMinor,
  int? printedDebitMinor,
  int? printedCreditMinor,
  int? printedDebitCount,
  int? printedCreditCount,
}) {
  if (printed.isEmpty) {
    return const StatementCheck(
      rows: [],
      chainBreaks: [],
      directionUnknown: [],
      reversed: false,
      verifiedSomething: false,
    );
  }
  final reversed = printed.first.date.isAfter(printed.last.date);
  final ordered = reversed ? printed.reversed.toList() : [...printed];

  final rows = <StatementRow>[];
  final breaks = <int>[];
  final unknown = <int>[];
  var transitions = 0;
  int? previous = openingMinor;

  for (var i = 0; i < ordered.length; i++) {
    var row = ordered[i];
    final balance = row.balanceMinor;
    if (previous != null && balance != null) {
      transitions++;
      final delta = balance - previous;
      if (row.direction == null) {
        if (delta == row.amountMinor) {
          row = row.copyWith(direction: Direction.credit);
        } else if (delta == -row.amountMinor) {
          row = row.copyWith(direction: Direction.debit);
        } else {
          breaks.add(row.index);
        }
      } else if (delta != row._signed) {
        breaks.add(row.index);
      }
    } else if (row.direction == null) {
      // Nothing to infer it from: the first row of a statement with no opening
      // balance, or a row after one printed without a balance.
      unknown.add(row.index);
    }
    rows.add(row);
    previous = balance;
  }

  var debits = 0, credits = 0, debitCount = 0, creditCount = 0;
  for (final r in rows) {
    if (r.direction == Direction.debit) {
      debits += r.amountMinor;
      debitCount++;
    } else if (r.direction == Direction.credit) {
      credits += r.amountMinor;
      creditCount++;
    }
  }

  final first = rows.first, last = rows.last;
  bool? opening;
  if (openingMinor != null && first.balanceMinor != null && first.direction != null) {
    opening = openingMinor + first._signed == first.balanceMinor;
  }
  bool? closing;
  if (closingMinor != null && last.balanceMinor != null) {
    closing = last.balanceMinor == closingMinor;
  }
  final haveDirections = unknown.isEmpty;
  return StatementCheck(
    rows: rows,
    chainBreaks: breaks,
    directionUnknown: unknown,
    reversed: reversed,
    verifiedSomething: transitions > 0 ||
        printedDebitMinor != null ||
        printedCreditMinor != null ||
        closing != null,
    openingMatches: opening,
    closingMatches: closing,
    debitTotalMatches: printedDebitMinor == null || !haveDirections ? null : debits == printedDebitMinor,
    creditTotalMatches: printedCreditMinor == null || !haveDirections ? null : credits == printedCreditMinor,
    debitCountMatches: printedDebitCount == null || !haveDirections ? null : debitCount == printedDebitCount,
    creditCountMatches: printedCreditCount == null || !haveDirections ? null : creditCount == printedCreditCount,
  );
}
