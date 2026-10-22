import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_dismissal_outbox.dart';

void main() {
  test('dismissal survives repository recreation and remains account scoped', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final first = SmsDismissalOutbox(database, 'account-a');
    first.enqueue('a' * 64, {'sourceKey': 'a' * 64, 'reason': 'not_financial'});

    expect(SmsDismissalOutbox(database, 'account-a').pending(), hasLength(1));
    expect(SmsDismissalOutbox(database, 'account-b').pending(), isEmpty);

    SmsDismissalOutbox(database, 'account-a').acknowledge('a' * 64);
    expect(first.pending(), isEmpty);
  });
}
