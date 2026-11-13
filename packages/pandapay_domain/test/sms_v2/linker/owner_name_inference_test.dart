import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';
import 'owner_vocabulary_support.dart';

void main() {
  setUpAll(installRepoOwnerVocabulary);

  group('greetingName', () {
    test('reads a name after the usual greetings', () {
      expect(greetingName('Dear Ishaan Dattatray Rangnekar, your order has shipped'), 'ISHAAN DATTATRAY RANGNEKAR');
      expect(greetingName('Hi Ishaan Rangnekar! Your bill is ready'), 'ISHAAN RANGNEKAR');
      expect(greetingName('Hello Mr Ishaan Rangnekar - thank you'), 'ISHAAN RANGNEKAR');
      expect(greetingName('DEAR ISHAAN RANGNEKAR, RS 500 DEBITED'), 'ISHAAN RANGNEKAR');
      expect(greetingName('Namaste Asha Maria Rao: welcome'), 'ASHA MARIA RAO');
    });

    test('a stock word or a single name is not a person', () {
      for (final body in [
        'Dear Customer, your payment is due',
        'Dear Valued Customer, thank you',
        'Dear Ishaan, your payment is due',
        'Hi there, welcome',
        'Dear Card Holder, your card',
        'Dear Sir, kindly',
        'Dear Customer Care Team, hello',
        'No greeting here at all',
        'Hello from Ishaan Rangnekar and team,',
      ]) {
        expect(greetingName(body), isNull, reason: body);
      }
    });
  });

  group('OwnerNameSignals', () {
    OwnerNameSignals seen(Map<String, List<String>> bySender) {
      final s = OwnerNameSignals();
      bySender.forEach((name, senders) {
        for (final sender in senders) {
          s.add(name, sender);
        }
      });
      return s;
    }

    test('a name seen often from several senders is the owner', () {
      final s = seen({
        'ISHAAN RANGNEKAR': ['SHOPA', 'BROKERB', 'BANKC', 'APPD', 'SHOPA'],
      });
      expect(s.promoted().map((n) => n.toString()), ['ISHAAN RANGNEKAR']);
    });

    test('a relative greeted by one site is not', () {
      final s = seen({
        'ISHAAN RANGNEKAR': ['SHOPA', 'BROKERB', 'BANKC'],
        'SUNITA PATEL': ['POLBAZ', 'POLBAZ', 'POLBAZ', 'POLBAZ', 'POLBAZ', 'POLBAZ'],
      });
      expect(s.promoted().map((n) => n.toString()), ['ISHAAN RANGNEKAR']);
    });

    test('two senders, or two sightings, are not enough', () {
      expect(seen({'A B': ['X', 'Y', 'X', 'Y']}).promoted(), isEmpty);
      expect(seen({'A B': ['X', 'Y']}).promoted(), isEmpty);
    });

    test('both forms of one person are kept, most seen first, capped', () {
      final s = seen({
        'ISHAAN RANGNEKAR': ['A', 'B', 'C', 'D', 'E'],
        'ISHAAN DATTATRAY RANGNEKAR': ['A', 'B', 'C'],
        'ASHA RAO': ['A', 'B', 'C'],
        'RAVI JOSHI': ['A', 'B', 'C'],
      });
      final names = s.promoted(max: 3).map((n) => n.toString()).toList();
      expect(names.first, 'ISHAAN RANGNEKAR');
      expect(names, hasLength(3));
    });

    test('sender case does not make two senders', () {
      final s = OwnerNameSignals()
        ..add('A B', 'hdfcbk')
        ..add('A B', 'HDFCBK')
        ..add('A B', 'HDFCBK');
      expect(s.seen['A B']!.senders, {'HDFCBK'});
      expect(s.promoted(), isEmpty);
    });

    test('survives a round trip through json', () {
      final s = seen({'ISHAAN RANGNEKAR': ['A', 'B', 'C']});
      final back = OwnerNameSignals.fromJson(s.toJson());
      expect(back.promoted().map((n) => n.toString()), ['ISHAAN RANGNEKAR']);
    });
  });
}
