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
      expect(native.limit, 200);
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
}
