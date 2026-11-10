import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/pipeline/failure_words.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('each failure kind gets its own fixed word', () {
    expect(failureKind(StateError('x')), 'StateError');
    expect(failureKind(RangeError('x')), 'RangeError');
    expect(failureKind(ArgumentError('x')), 'ArgumentError');
    expect(failureKind(const FormatException('x')), 'FormatException');
    expect(failureKind(UnsupportedError('x')), 'UnsupportedError');
    expect(failureKind(Object()), 'Error');
  });

  test('a state error keeps its own message, with long numbers blanked', () {
    expect(
      describeFailure(StateError('Shared intake has not committed a decision')),
      'StateError: Shared intake has not committed a decision',
    );
    expect(
      describeFailure(StateError('Event 1234567890123 unknown')),
      'StateError: Event # unknown',
    );
  });

  test('a database error says its message and code', () {
    final db = sqlite3.openInMemory();
    try {
      db.execute('SELECT * FROM no_such_table');
      fail('should have thrown');
    } on SqliteException catch (error) {
      expect(describeFailure(error), startsWith('SqliteException: '));
      expect(describeFailure(error), contains('(1)'));
    } finally {
      db.dispose();
    }
  });

  test('a long message is cut and a kind with no message is just the kind', () {
    final long = describeFailure(StateError('a' * 400));
    expect(long.length, lessThan(140));
    expect(describeFailure(const FormatException('secret body text')), 'FormatException');
    expect(describeFailure(Object()), 'Error');
  });
}
