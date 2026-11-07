import 'package:pandapay_domain/src/sms_v2/linker/person_name.dart';
import 'package:test/test.dart';

// Every name here is invented.
void main() {
  group('namesDescribeSamePerson', () {
    test('a name cut short by the bank is the same person', () {
      expect(
        namesDescribeSamePerson('ASHA RAO', 'ASHA MARIA RAO'),
        isTrue,
      );
      expect(
        namesDescribeSamePerson('ASHA MARIA', 'ASHA MARIA RAO'),
        isTrue,
      );
    });

    test('an initial stands for the word it starts', () {
      expect(
        namesDescribeSamePerson('ASHA MARIA R', 'ASHA MARIA RAO'),
        isTrue,
      );
    });

    test('words run together match when long enough', () {
      expect(
        namesDescribeSamePerson('ASHAMARIAR', 'ASHA MARIA RAO'),
        isTrue,
      );
      expect(namesDescribeSamePerson('ASHARAO', 'ASHA RAO'), isFalse,
          reason: 'too short to trust');
    });

    test('a shared first name alone is not the same person', () {
      expect(namesDescribeSamePerson('ASHA RAO', 'ASHA IYER'), isFalse);
      expect(namesDescribeSamePerson('ASHA', 'ASHA RAO'), isFalse);
    });

    test('punctuation, case and digits do not matter', () {
      expect(
        namesDescribeSamePerson('asha.maria  rao', 'ASHA-MARIA RAO'),
        isTrue,
      );
    });

    test('empty names never match', () {
      expect(namesDescribeSamePerson(null, 'ASHA RAO'), isFalse);
      expect(namesDescribeSamePerson('', ''), isFalse);
    });
  });

  group('nameIsOneOf', () {
    const owner = ['Asha Maria Rao'];

    test('the full name, a cut name and first plus last all match', () {
      expect(nameIsOneOf('ASHA MARIA RAO', owner), isTrue);
      expect(nameIsOneOf('ASHA MARIA', owner), isTrue);
      expect(nameIsOneOf('ASHA RAO', owner), isTrue);
    });

    test('someone else with the same first name does not match', () {
      expect(nameIsOneOf('ASHA IYER', owner), isFalse);
      expect(nameIsOneOf('ZOMATO', owner), isFalse);
    });

    test('a one-word owner name matches nothing', () {
      expect(nameIsOneOf('ASHA', const ['Asha']), isFalse);
      expect(nameIsOneOf('ASHA RAO', const ['Asha']), isFalse);
    });

    test('no owner names match nothing', () {
      expect(nameIsOneOf('ASHA MARIA RAO', const []), isFalse);
    });
  });
}
