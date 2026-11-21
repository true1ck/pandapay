import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/statement_layouts.dart';
import 'package:test/test.dart';

// Words are placed by hand: 4.5 points a character, 10 points a line. A real
// PDF library gives the same thing (text and a box) for every word.
const _char = 4.5;

PdfWord _left(String text, double left, double top, {int page = 0}) => PdfWord(
  page: page,
  left: left,
  top: top,
  right: left + text.length * _char,
  bottom: top + 8,
  text: text,
  fontSize: 8,
);

PdfWord _right(String text, double right, double top, {int page = 0}) =>
    PdfWord(
      page: page,
      left: right - text.length * _char,
      top: top,
      right: right,
      bottom: top + 8,
      text: text,
      fontSize: 8,
    );

class _Row {
  const _Row(this.date, this.narration, this.debit, this.credit, this.balance);
  final String date, narration;
  final String? debit, credit;
  final String balance;
}

const _head = ['Date', 'Narration', 'Withdrawals', 'Deposits', 'Balance'];

List<PdfWord> _header(double top, {int page = 0}) => [
  _left(_head[0], 30, top, page: page),
  _left(_head[1], 100, top, page: page),
  _right(_head[2], 400, top, page: page),
  _right(_head[3], 470, top, page: page),
  _right(_head[4], 560, top, page: page),
];

List<PdfWord> _rows(List<_Row> rows, double top, {int page = 0}) {
  final out = <PdfWord>[];
  var y = top;
  for (final r in rows) {
    out.add(_left(r.date, 30, y, page: page));
    for (final (i, part) in r.narration.split(' ').indexed) {
      out.add(_left(part, 100 + i * 40, y, page: page));
    }
    if (r.debit != null) out.add(_right(r.debit!, 400, y, page: page));
    if (r.credit != null) out.add(_right(r.credit!, 470, y, page: page));
    out.add(_right(r.balance, 560, y, page: page));
    y += 10;
  }
  return out;
}

String _title(String bank, String account) => '$bank Account $account';

List<PdfWord> _titleWords() => [
  _left('ICICI', 30, 20),
  _left('BANK', 60, 20),
  _left('Account', 30, 30),
  _left('no.', 70, 30),
  _left('912345670011', 90, 30),
];

const _three = [
  _Row('04/01/2026', 'Interest credit', null, '139.00', '1000.00'),
  _Row('05/01/2026', 'UPI shop', '250.00', null, '750.00'),
  _Row('07/01/2026', 'NEFT salary', null, '5000.00', '5750.00'),
];

void main() {
  group('readStatementTable', () {
    test('reads debit, credit and balance from where the amounts sit', () {
      final read = readStatementTable([
        ..._titleWords(),
        ..._header(60),
        ..._rows(_three, 80),
      ])!;
      expect(read.rows, hasLength(3));
      expect(read.rows[0].direction?.wire, 'credit');
      expect(read.rows[0].amountMinor, 13900);
      expect(read.rows[1].direction?.wire, 'debit');
      expect(read.rows[1].amountMinor, 25000);
      expect(read.rows[2].balanceMinor, 575000);
      expect(read.rows[0].narration, 'Interest credit');
      expect(read.accountMask, '0011');
      expect(read.issuerSlug, 'icici');
      expect(read.check.chainBreaks, isEmpty);
      expect(read.check.directionUnknown, isEmpty);
    });

    test('a row that does not follow the running balance is flagged', () {
      final read = readStatementTable([
        ..._header(60),
        ..._rows([
          _three[0],
          const _Row('05/01/2026', 'UPI shop', '250.00', null, '740.00'),
          _three[2],
        ], 80),
      ])!;
      expect(read.check.chainBreaks, isNotEmpty);
      expect(read.check.trusted, isFalse);
    });

    test(
      'an opening-balance row is the opening balance, not a transaction',
      () {
        final read = readStatementTable([
          ..._header(60),
          ..._rows([
            const _Row('01/01/2026', 'Opening Balance', null, null, '861.00'),
            _three[0],
            _three[1],
            _three[2],
          ], 80),
        ])!;
        expect(read.rows, hasLength(3));
        expect(read.openingMinor, 86100);
        expect(read.check.openingMatches, isTrue);
      },
    );

    test('a balance marked Dr is negative', () {
      // Each row is drawn in order, the "Dr" marker right after its balance.
      final words = <PdfWord>[..._header(60)];
      var y = 80.0;
      for (final r in const [
        _Row('04/01/2026', 'Fee', '100.00', null, '50.00'),
        _Row('05/01/2026', 'Fee two', '100.00', null, '50.00'),
        _Row('06/01/2026', 'Fee three', null, '200.00', '150.00'),
      ]) {
        words.addAll(_rows([r], y));
        // Balances of the first row positive, the next two overdrawn.
        if (r.date != '04/01/2026') words.add(_left('Dr', 563, y));
        y += 10;
      }
      final read = readStatementTable(words)!;
      expect(read.rows[0].balanceMinor, 5000);
      expect(read.rows[1].balanceMinor, -5000);
      expect(read.rows[2].balanceMinor, -15000);
    });

    test('dates are read day first unless one can only be month first', () {
      final dayFirst = readStatementTable([
        ..._header(60),
        ..._rows([
          const _Row('03/04/2026', 'a', '10.00', null, '90.00'),
          const _Row('04/04/2026', 'b', '10.00', null, '80.00'),
        ], 80),
      ])!;
      expect(dayFirst.rows.first.date, DateTime.utc(2026, 4, 3));

      final monthFirst = readStatementTable([
        ..._header(60),
        ..._rows([
          const _Row('04/03/2026', 'a', '10.00', null, '90.00'),
          const _Row('04/27/2026', 'b', '10.00', null, '80.00'),
        ], 80),
      ])!;
      expect(monthFirst.rows.first.date, DateTime.utc(2026, 4, 3));
      expect(monthFirst.rows.last.date, DateTime.utc(2026, 4, 27));
    });

    test('a value-date column is set aside, a date in a narration is kept', () {
      final words = <PdfWord>[
        _left('Txn', 30, 50),
        _left('Date', 30, 60),
        _left('Value', 95, 50),
        _left('Date', 95, 60),
        _left('Description', 160, 60),
        _right('Debit', 400, 60),
        _right('Credit', 470, 60),
        _right('Balance', 560, 60),
      ];
      var y = 80.0;
      for (final (i, bal) in ['900.00', '800.00', '1800.00'].indexed) {
        words.addAll([
          _left('0${i + 1}/02/2026', 30, y),
          _left('0${i + 1}/02/2026', 95, y),
          _left('Interest', 160, y),
          _left('to', 200, y),
          _left('29-03-2026', 215, y),
          if (i < 2) _right('100.00', 400, y) else _right('1000.00', 470, y),
          _right(bal, 560, y),
        ]);
        y += 10;
      }
      final read = readStatementTable(words)!;
      expect(read.rows, hasLength(3));
      expect(read.rows.first.date, DateTime.utc(2026, 2, 1));
      expect(read.rows.first.narration, 'Interest to 29-03-2026');
    });

    test('a page with no header takes the columns of the page before', () {
      final read = readStatementTable([
        ..._header(60),
        ..._rows([_three[0], _three[1]], 80),
        // page two: no header, same columns
        ..._rows([_three[2]], 40, page: 1),
      ])!;
      expect(read.rows, hasLength(3));
      expect(read.check.chainBreaks, isEmpty);
      expect(read.unreadPages, isEmpty);
    });

    test('a footer after the table is not part of the last narration', () {
      final read = readStatementTable([
        ..._header(60),
        ..._rows(_three, 80),
        _left('Page', 30, 300),
        _left('1', 60, 300),
        _left('Legends', 100, 330),
        _left('for', 140, 330),
        _left('transactions', 160, 330),
      ])!;
      expect(read.rows.last.narration, 'NEFT salary');
    });

    test('a page that prints dates it cannot read is named, not skipped', () {
      final read = readStatementTable([
        ..._header(60),
        ..._rows(_three, 80),
        // page two: dates in another column, no amounts that line up
        _left('08/01/2026', 200, 40, page: 1),
        _left('09/01/2026', 200, 50, page: 1),
        _left('10/01/2026', 200, 60, page: 1),
        _left('hello', 300, 40, page: 1),
      ])!;
      expect(read.rows, hasLength(3));
      expect(read.unreadPages, [2]);
    });

    test('declines what it cannot prove', () {
      // One amount column and no balance and no markers: nothing says which
      // way the money went, so this is not a table the reader will guess at.
      final words = <PdfWord>[
        _left('Date', 30, 60),
        _left('Description', 100, 60),
        _right('Amount', 400, 60),
      ];
      var y = 80.0;
      for (final a in ['100.00', '200.00', '300.00']) {
        words.addAll([
          _left('0${y ~/ 10 - 7}/01/2026', 30, y),
          _left('Shop', 100, y),
          _right(a, 400, y),
        ]);
        y += 10;
      }
      expect(readStatementTable(words), isNull);
      expect(readStatementTable(const []), isNull);
    });

    test('verifyStatement agrees with the columns on a real balance chain', () {
      final read = readStatementTable([..._header(60), ..._rows(_three, 80)])!;
      final check = verifyStatement(read.rows);
      expect(check.chainBreaks, isEmpty);
      expect(check.verifiedSomething, isTrue);
    });
  });
}
