import 'dart:convert';
import 'dart:io';

import 'package:sms_rules_cli/cluster.dart';
import 'package:sms_rules_cli/messages_io.dart';
import 'package:test/test.dart';

// Fake "real-looking" export. All names, numbers and amounts are invented.
const _fakeCsv = '''sender,body,observedAt
VM-HDFCBK-S,"Rs.7,845.50 debited from A/c XX4821 on 14-09-26 to VPA priya.nair84@okhdfcbank (PRIYA NAIR) (UPI Ref No 427711903388). Avl bal Rs 61,204.17",2026-09-14T10:00:00Z
AX-ICICIT-S,"Dear Mr. Anand Venkataraman, INR 12,499.00 spent using ICICI Bank Card XX6035 on 03-Oct-26 on SWIGGY. Avl Limit: INR 2,31,870.25.",2026-10-03T10:00:00Z
VM-KOTAKB-S,"Sent Rs.1,250.00 from Kotak Bank AC X3390 to ramesh.kulkarni@okaxis on 09-11-26.UPI Ref 431122009988.",2026-11-09T10:00:00Z
''';

void main() {
  group('CSV and JSONL input', () {
    test('parses quoted CSV with commas inside', () {
      final msgs = parseCsvMessages(_fakeCsv);
      expect(msgs.length, 3);
      expect(msgs[0].sender, 'VM-HDFCBK-S');
      expect(msgs[0].body, contains('Rs.7,845.50'));
      expect(msgs[2].observedAt, DateTime.utc(2026, 11, 9, 10));
    });

    test('parses JSONL', () {
      final msgs = parseJsonlMessages(
        '{"sender":"A","body":"x","observedAt":"2026-11-01T00:00:00Z"}\n\n'
        '{"sender":"B","body":"y","observedAt":"2026-11-02T00:00:00Z"}\n',
      );
      expect(msgs.map((m) => m.sender), ['A', 'B']);
    });
  });

  group('redact command', () {
    test('writes JSONL with no original name, number or amount', () async {
      final dir = Directory.systemTemp.createTempSync('redact_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/in.csv').writeAsStringSync(_fakeCsv);
      final r = await Process.run('dart', [
        'run', 'bin/sms_rules.dart', 'redact',
        '--in', '${dir.path}/in.csv', '--out', '${dir.path}/out.jsonl', '--salt', 'fixed',
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final out = File('${dir.path}/out.jsonl').readAsStringSync();
      for (final secret in [
        '7,845.50', '4821', '427711903388', 'PRIYA', 'NAIR', 'priya.nair84', '61,204.17',
        'Anand', 'Venkataraman', '12,499.00', '6035', '2,31,870.25',
        'ramesh', 'kulkarni', '3390', '431122009988', '1,250.00',
      ]) {
        expect(out.toLowerCase().contains(secret.toLowerCase()), isFalse, reason: '$secret survived');
      }
      expect(out, contains('SWIGGY'));
      final lines = const LineSplitter().convert(out);
      expect(lines.length, 3);
      expect(jsonDecode(lines.first), containsPair('sender', 'VM-HDFCBK-S'));
    });
  });

  group('clustering', () {
    RawSms sms(String sender, String body, [int day = 1]) =>
        RawSms(sender: sender, body: body, observedAt: DateTime.utc(2026, 11, day));

    test('the same template with different values is one cluster', () {
      final msgs = [
        for (var i = 0; i < 6; i++)
          sms('VM-HDFCBK-S', 'Rs.${100 + i * 7}.00 spent on HDFC Bank Card x${5678 + i} at SWIGGY on 0${1 + i}-11-26. Avl Lmt: Rs.${45000 - i},000.00', i + 1),
      ];
      final t = clusterMessages(msgs);
      expect(t.length, 1);
      expect(t.single.count, 6);
      expect(t.single.brand, 'HDFCBK');
      expect(t.single.samples.length, 3);
      expect(t.single.firstSeen, DateTime.utc(2026, 11, 1));
      expect(t.single.lastSeen, DateTime.utc(2026, 11, 6));
    });

    test('rare merchant and person names collapse into one template', () {
      final names = ['Lakshmi', 'Gauri', 'Meenal', 'Tarun', 'Ishaan', 'Vedika', 'Kabir'];
      final msgs = [
        for (final n in names)
          sms('AX-AXISBK-S', 'Rs.500.00 paid to $n via UPI on 01-11-26. Not you? Call 18001234567'),
        for (var i = 0; i < 6; i++) sms('AX-AXISBK-S', 'Rs.500.00 paid to SWIGGY via UPI on 01-11-26. Not you? Call 18001234567'),
      ];
      final t = clusterMessages(msgs);
      expect(t.length, 2, reason: t.map((e) => e.skeleton).join('\n'));
      expect(t.first.count, 7);
      expect(t.first.skeleton, contains('<W>'));
      expect(t.last.skeleton, contains('SWIGGY'));
      // sorted by count
      expect(t.first.count, greaterThanOrEqualTo(t.last.count));
    });

    test('different brands with the same skeleton stay apart', () {
      final t = clusterMessages([
        sms('VM-HDFCBK-S', 'Rs.1.00 debited'),
        sms('VM-SBIBNK-S', 'Rs.1.00 debited'),
      ]);
      expect(t.length, 2);
    });
  });
}
