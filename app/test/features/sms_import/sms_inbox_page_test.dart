import 'package:flutter_test/flutter_test.dart';
import 'package:telephony/telephony.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';

class _Telephony implements Telephony {
  List<SmsMessage> rows = [];
  SmsFilter? filter;
  List<SmsColumn>? columns;
  int? limit;
  @override
  Future<List<SmsMessage>> getInboxSms({
    List<SmsColumn> columns = const [],
    SmsFilter? filter,
    List<OrderBy>? sortOrder,
    int? queryLimit,
  }) async {
    this.filter = filter;
    this.columns = columns;
    limit = queryLimit;
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'page query excludes completed IDs and advances past OTP/nonfinancial rows',
    () async {
      final native = _Telephony();
      const columns = [
        SmsColumn.ID,
        SmsColumn.ADDRESS,
        SmsColumn.BODY,
        SmsColumn.DATE,
      ];
      SmsMessage row(int id, String body) => SmsMessage.fromMap({
        '_id': '$id',
        'address': 'VM-BANK',
        'body': body,
        'date': '1792281600000',
      }, columns);
      native.rows = [
        row(11, 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.'),
        row(12, 'Your OTP is 123456. Do not share it.'),
        row(13, 'Your parcel has shipped.'),
      ];
      final page = await SmsListenerService(
        telephony: native,
      ).readInboxPage(afterId: 10, throughId: 13);
      expect(native.filter!.selectionArgs, ['10', '13']);
      expect(native.filter!.selection, contains('>'));
      expect(native.limit, 25);
      expect(page.messages.single.id, 11);
      expect(page.rowCount, 3);
      expect(page.lastId, 13);
    },
  );

  test('head query requests one ID without transferring SMS bodies', () async {
    final native = _Telephony();
    native.rows = [
      SmsMessage.fromMap({'_id': '42'}, const [SmsColumn.ID]),
    ];
    expect(await SmsListenerService(telephony: native).inboxHeadId(), 42);
    expect(native.columns, [SmsColumn.ID]);
    expect(native.limit, 1);
  });

  test('native numeric SMS fields decode without a type error', () {
    const columns = [
      SmsColumn.ID,
      SmsColumn.ADDRESS,
      SmsColumn.BODY,
      SmsColumn.DATE,
      SmsColumn.DATE_SENT,
      SmsColumn.READ,
      SmsColumn.SEEN,
      SmsColumn.STATUS,
      SmsColumn.SUBSCRIPTION_ID,
      SmsColumn.THREAD_ID,
      SmsColumn.TYPE,
    ];

    final message = SmsMessage.fromMap({
      '_id': 42,
      'address': 'VM-ICICIB',
      'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
      'date': 1792281600000,
      'date_sent': 1792281599000,
      'read': 1,
      'seen': 0,
      'status': 0,
      'sub_id': 2,
      'thread_id': 7,
      'type': 1,
    }, columns);

    expect(message.id, 42);
    expect(message.address, 'VM-ICICIB');
    expect(message.date, 1792281600000);
    expect(message.dateSent, 1792281599000);
    expect(message.read, isTrue);
    expect(message.seen, isFalse);
    expect(message.status, SmsStatus.STATUS_COMPLETE);
    expect(message.subscriptionId, 2);
    expect(message.threadId, 7);
    expect(message.type, SmsType.MESSAGE_TYPE_INBOX);
  });

  test('unknown native SMS enum values do not crash decoding', () {
    final message = SmsMessage.fromMap({
      'type': 999,
    }, const [SmsColumn.TYPE]);

    expect(message.type, isNull);
  });

  test('readInboxSms filters using capturesFinancialSms with sender', () async {
    final native = _Telephony();
    const columns = [
      SmsColumn.ID,
      SmsColumn.ADDRESS,
      SmsColumn.BODY,
      SmsColumn.DATE,
    ];
    SmsMessage row(int id, String address, String body) => SmsMessage.fromMap({
      '_id': '$id',
      'address': address,
      'body': body,
      'date': '1792281600000',
    }, columns);
    native.rows = [
      row(1, 'VM-HDFCBK', 'INR 500 purchase declined on credit card XX4321.'),
      row(2, 'TX-PROMO', 'Flat 50% off on your next order! Shop now.'),
      row(3, 'VM-OTPSMS', '123456 is your one-time password. Valid for 10 minutes.'),
      row(4, 'AX-AxisBk', 'INR 1250.00 debited from Axis Bank Card XX5678 at SWIGGY'),
    ];
    final result = await SmsListenerService(telephony: native).readInboxSms();
    expect(result.map((m) => m.id), [1, 4]);
  });
}
