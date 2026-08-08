import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_backup_xml_parser.dart';

void main() {
  test('parses a standard SMS Backup & Restore export', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<smses count="2">
  <sms protocol="0" address="VM-HDFCBK" date="1704067200000" type="1"
       body="Rs.499.00 spent on HDFC Bank Card x1234 at AMAZON on 01-01-24" readable_date="Jan 1, 2024" />
  <sms protocol="0" address="AX-AxisBk" date="1704153600000" type="1"
       body="INR 1,250.00 spent on Axis Bank Card XX5678 at SWIGGY on 03-01-24" readable_date="Jan 3, 2024" />
</smses>
''';
    final messages = parseSmsBackupXml(xml);
    expect(messages, hasLength(2));
    expect(messages[0].sender, 'VM-HDFCBK');
    expect(messages[0].body, contains('AMAZON'));
    expect(messages[1].sender, 'AX-AxisBk');
    expect(messages[1].body, contains('SWIGGY'));
  });

  test('falls back to from/text attributes for a non-standard export shape', () {
    const xml = '<messages><sms from="VM-ICICI" text="Some message body" /></messages>';
    final messages = parseSmsBackupXml(xml);
    expect(messages, hasLength(1));
    expect(messages.single.sender, 'VM-ICICI');
    expect(messages.single.body, 'Some message body');
  });

  test('skips an sms element missing both sender and body, keeps the rest', () {
    const xml = '''
<smses>
  <sms address="VM-HDFCBK" body="Real message" />
  <sms />
  <sms address="" body="" />
</smses>
''';
    final messages = parseSmsBackupXml(xml);
    expect(messages, hasLength(1));
    expect(messages.single.sender, 'VM-HDFCBK');
  });

  test('an empty <smses> yields zero messages, not an error', () {
    expect(parseSmsBackupXml('<smses></smses>'), isEmpty);
  });

  test('genuinely invalid XML throws SmsBackupParseException, not a raw XmlException', () {
    expect(
      () => parseSmsBackupXml('this is not xml at all <<<'),
      throwsA(isA<SmsBackupParseException>()),
    );
  });
}
