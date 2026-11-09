import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/sms_v2.dart';

/// A deterministic synthetic SMS history. Every body comes from the public
/// golden scenarios, golden cases or rule examples, then amounts, card digits,
/// reference numbers and dates are varied. It contains no private data.
class SyntheticCorpus {
  SyntheticCorpus(this.messages, this.byOrigin);
  final List<QueuedSms> messages;
  final Map<String, int> byOrigin;

  /// Roughly 40% scenario groups (purchase then refund, mandate then charge,
  /// IPO block then allotment and so on, so the linker has real work),
  /// 30% golden single messages (including promotions, OTPs and unknowns) and
  /// 30% rule examples. Dates spread over [spanDays] days ending before the
  /// golden fixtures' own month.
  static SyntheticCorpus generate(
    RuleBundle bundle, {
    int count = 20000,
    int seed = 7,
    int spanDays = 730,
  }) {
    final random = Random(seed);
    // The picks below index into these lists, so their order must not depend on
    // the file system: macOS and Linux list a folder in different orders, and an
    // unsorted list drew a different sample for the same seed on CI.
    final scenarios = <List<_Template>>[
      for (final file in _filesUnder('../tools/sms_golden/scenarios'))
        if (file.path.endsWith('.json'))
          [
            for (final m
                in (jsonDecode(file.readAsStringSync()) as Map)['messages']
                    as List)
              _Template(
                m['sender'] as String,
                m['body'] as String,
                DateTime.parse(m['observedAt'] as String),
              ),
          ],
    ];
    final golden = <_Template>[];
    for (final file in _filesUnder('../tools/sms_golden/cases', recursive: true)) {
      if (!file.path.endsWith('.json')) continue;
      for (final m in (jsonDecode(file.readAsStringSync()) as Map)['messages'] as List) {
        golden.add(
          _Template(
            m['sender'] as String,
            m['body'] as String,
            DateTime.parse(m['observedAt'] as String),
          ),
        );
      }
    }
    final examples = <_Template>[
      for (final rule in bundle.rules)
        for (final example in rule.examples)
          _Template(
            example.sender == '*' || example.sender.isEmpty
                ? (rule.senders.firstWhere(
                    (s) => s != '*',
                    orElse: () => 'VM-HDFCBK-S',
                  ))
                : example.sender,
            example.body,
            DateTime.utc(2026, 11, 20, 9),
          ),
    ];
    final out = <QueuedSms>[];
    final origin = {'scenario': 0, 'golden': 0, 'ruleExample': 0};
    var serial = 0;
    final seen = <String>{};
    while (out.length < count) {
      final pick = random.nextDouble();
      final shift = random.nextInt(spanDays);
      final amounts = <String, String>{};
      final masks = <String, String>{};
      final List<_Template> group;
      final String kind;
      if (pick < .4) {
        group = scenarios[random.nextInt(scenarios.length)];
        kind = 'scenario';
      } else if (pick < .7) {
        group = [golden[random.nextInt(golden.length)]];
        kind = 'golden';
      } else {
        group = [examples[random.nextInt(examples.length)]];
        kind = 'ruleExample';
      }
      for (final template in group) {
        if (out.length >= count) break;
        final observed = template.observedAt
            .subtract(Duration(days: shift, minutes: random.nextInt(600)));
        serial++;
        final body = _vary(template.body, random, amounts, masks, shift, serial);
        // A repeated body would be a replay, not a new message.
        if (!seen.add('${template.sender}|$body')) continue;
        out.add(QueuedSms(sender: template.sender, body: body, receivedAt: observed));
        origin[kind] = origin[kind]! + 1;
      }
    }
    out.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    return SyntheticCorpus(out, origin);
  }

  /// The files in [path], sorted by path so the order is the same everywhere.
  static List<File> _filesUnder(String path, {bool recursive = false}) =>
      Directory(path).listSync(recursive: recursive).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  static final _amount = RegExp(
    r'(?<=(?:Rs\.?|INR|₹)\s?)\d[\d,]*(?:\.\d{1,2})?',
    caseSensitive: false,
  );
  static final _mask = RegExp(
    r'(?<=(?:XX|xx|x|X|\*|ending |ending with |no\. )\s?)\d{4}(?!\d)',
  );
  static final _reference = RegExp(r'(?<!\d)\d{12}(?!\d)');
  static final _dmyDash = RegExp(r'(?<!\d)(\d{2})-(\d{2})-(\d{2,4})(?!\d)');
  static final _ymdDash = RegExp(r'(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)');
  static final _dmyMon = RegExp(
    r'(?<!\d)(\d{2})-(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-(\d{2})(?!\d)',
    caseSensitive: false,
  );
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _vary(
    String body,
    Random random,
    Map<String, String> amounts,
    Map<String, String> masks,
    int shiftDays,
    int serial,
  ) {
    var text = body.replaceAllMapped(_amount, (m) {
      final old = m[0]!;
      return amounts.putIfAbsent(old, () {
        final rupees = 10 + random.nextInt(49990);
        return old.contains('.')
            ? '$rupees.${_two(random.nextInt(100))}'
            : '$rupees';
      });
    });
    text = text.replaceAllMapped(
      _mask,
      (m) => masks.putIfAbsent(
        m[0]!,
        () => (1000 + (random.nextInt(8) * 1111 + 17) % 9000).toString(),
      ),
    );
    // The serial number keeps every body unique so no message is a replay.
    text = text.replaceAllMapped(
      _reference,
      (m) => '${(100000000000 + serial * 7919 + random.nextInt(7919)) % 1000000000000}'
          .padLeft(12, '1'),
    );
    DateTime shifted(int y, int mo, int d) =>
        DateTime.utc(y, mo, d).subtract(Duration(days: shiftDays));
    text = text.replaceAllMapped(_ymdDash, (m) {
      final d = shifted(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      return '${d.year}-${_two(d.month)}-${_two(d.day)}';
    });
    text = text.replaceAllMapped(_dmyMon, (m) {
      final month = _months.indexWhere(
        (x) => x.toLowerCase() == m[2]!.toLowerCase(),
      );
      final d = shifted(2000 + int.parse(m[3]!), month + 1, int.parse(m[1]!));
      return '${_two(d.day)}-${_months[d.month - 1]}-${_two(d.year % 100)}';
    });
    text = text.replaceAllMapped(_dmyDash, (m) {
      final month = int.parse(m[2]!);
      final day = int.parse(m[1]!);
      if (month < 1 || month > 12 || day < 1 || day > 31) return m[0]!;
      final yearText = m[3]!;
      final year = yearText.length == 2 ? 2000 + int.parse(yearText) : int.parse(yearText);
      final d = shifted(year, month, day);
      return '${_two(d.day)}-${_two(d.month)}-'
          '${yearText.length == 2 ? _two(d.year % 100) : d.year}';
    });
    return text;
  }
}

class _Template {
  const _Template(this.sender, this.body, this.observedAt);
  final String sender, body;
  final DateTime observedAt;
}
