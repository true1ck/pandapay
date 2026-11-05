import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/local_category_learning.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _namespace = 'user:local-learning';
const _sender = 'HDFCBK';
const _body = 'Rs 1,500.00 debited to SWIGGY from A/C  XXXX4321 on 28-10-2026';
final _occurredAt = DateTime.utc(2026, 10, 28, 6, 30);
final _sourceKey = smsSourceKey(_namespace, _sender, _body);

TransactionEntry _entry({String source = 'sms', String? sourceKey}) =>
    TransactionEntry(
      id: 't-sms',
      sourceKey: sourceKey ?? _sourceKey,
      amount: Money.fromRupees(1500),
      occurredAt: _occurredAt,
      merchantName: 'SWIGGY from A/C',
      categoryId: 'cat-online',
      source: source,
      status: 'active',
    );

void _capture(AppDatabase database) => SmsIntakeRepository(database).capture(
  _namespace,
  QueuedSms(sender: _sender, body: _body, receivedAt: _occurredAt),
);

Iterable<String> _rules(AppDatabase database) =>
    SmsLearningFeedback(database, namespace: _namespace)
        .loadRulesSync()
        .values;

void main() {
  late AppDatabase database;
  setUp(() => database = openInMemoryForTesting());
  tearDown(() => database.close());

  test('a canonical correction trains the on-device rule', () {
    _capture(database);
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(),
      categorySlug: 'dining',
    );
    expect(_rules(database), contains('dining'));
  });

  test('a non-canonical slug records nothing', () {
    _capture(database);
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(),
      categorySlug: 'Weekend Treats',
    );
    expect(_rules(database), isEmpty);
  });

  test('a non-SMS transaction records nothing', () {
    _capture(database);
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(source: 'manual'),
      categorySlug: 'dining',
    );
    expect(_rules(database), isEmpty);
  });

  test('a source key that is not a SHA-256 hex records nothing', () {
    _capture(database);
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(sourceKey: 'not-a-hash'),
      categorySlug: 'dining',
    );
    expect(_rules(database), isEmpty);
  });

  test('an SMS that is no longer on the device records nothing', () {
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(),
      categorySlug: 'dining',
    );
    expect(_rules(database), isEmpty);
  });

  test('a repeated identical SMS abstains', () {
    _capture(database);
    SmsIntakeRepository(database).capture(
      _namespace,
      QueuedSms(
        sender: _sender,
        body: _body,
        receivedAt: _occurredAt.add(const Duration(days: 1)),
      ),
    );
    expect(
      SmsIntakeRepository(database).hasRepeatedOccurrence(_namespace, _sourceKey),
      isTrue,
    );
    recordLocalCategoryCorrection(
      database: database,
      namespace: _namespace,
      original: _entry(),
      categorySlug: 'dining',
    );
    expect(_rules(database), isEmpty);
  });
}
