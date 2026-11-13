import 'package:test/test.dart';

import 'helpers.dart';
import 'owner_vocabulary_support.dart';

/// A payment to a person who is the account owner (by name, by UPI handle, or
/// because the owner marked the payee or the account) is the owner moving their
/// own money, never a payment or income. Anyone else with a similar name is not.
void main() {
  setUpAll(installRepoOwnerVocabulary);

  const owner = ['Ishaan Dattatray Rangnekar'];

  List<String> toPerson({
    String? name,
    String? vpa,
    String? mask,
    List<String> owners = owner,
  }) => shapes(
    linkAll([
      debit(
        'p2p',
        1200000,
        at: '2026-11-02T10:00:00Z',
        inst: hdfcAcct,
        counterparty: party(name: name, vpa: vpa, mask: mask),
      ),
    ], ownerNames: owners),
  );

  List<String> fromPerson({String? name, String? vpa, List<String> owners = owner}) =>
      shapes(
        linkAll([
          credit(
            'p2p',
            1200000,
            at: '2026-11-02T10:00:00Z',
            inst: hdfcAcct,
            counterparty: party(name: name, vpa: vpa),
          ),
        ], ownerNames: owners),
      );

  group('by name', () {
    for (final printed in [
      'ISHAAN DATTATRAY RANGNEKAR',
      'ISHAAN DATTATRAY RANG',
      'ISHAAN RANGNEKAR',
      'RANGNEKAR ISHAAN DATTATRAY',
      'Mr Ishaan D Rangnekar',
    ]) {
      test('a debit to "$printed" is an own transfer', () {
        expect(toPerson(name: printed), ['own_transfer[debit_leg]']);
      });
    }

    for (final printed in [
      'KABIR DATTATRAY RANGNEKAR', // a sibling
      'DATTATRAY RANGNEKAR',
      'ISHAAN RANGNEKAR PATIL',
      'ROHAN RANGNEKAR',
    ]) {
      test('a debit to "$printed" stays a payment', () {
        expect(toPerson(name: printed), isNot(contains('own_transfer[debit_leg]')));
      });
    }

    test('without a usable owner name nothing is claimed', () {
      expect(
        toPerson(name: 'ISHAAN DATTATRAY RANGNEKAR', owners: const ['ishaanrangnekar24']),
        isNot(contains('own_transfer[debit_leg]')),
      );
    });
  });

  group('by UPI handle', () {
    test('a handle built from the owner\'s name, with no name printed', () {
      expect(toPerson(vpa: 'ishaanrangnekar-2@okhdfcbank'), ['own_transfer[debit_leg]']);
      expect(fromPerson(vpa: 'ishaanrangnekar@okicici'), ['own_transfer[credit_leg]']);
    });

    test('a relative\'s handle is not the owner', () {
      expect(toPerson(vpa: 'rohanrangnekar76@okaxis'), isNot(contains('own_transfer[debit_leg]')));
      expect(fromPerson(vpa: 'nikhilrangnekar96@okaxis'), isNot(contains('own_transfer[credit_leg]')));
    });
  });

  group('marked by the owner', () {
    test('a payee marked as their own, however it is printed', () {
      expect(
        toPerson(name: 'VIKRAM RAGHUNATH JOSHI', owners: const ['payee:Vikram Raghunath Joshi']),
        ['own_transfer[debit_leg]'],
      );
      expect(toPerson(name: 'VIKRAM RAGHUNATH JOSHI', owners: const []), isNot(contains('own_transfer[debit_leg]')));
    });

    test('a handle marked as their own', () {
      expect(
        fromPerson(vpa: '9000000001@ybl', owners: const ['vpa:9000000001@ybl']),
        ['own_transfer[credit_leg]'],
      );
    });

    test('an account marked as their own', () {
      expect(
        toPerson(name: 'SOMEONE ELSE', mask: '6543', owners: const ['mask:6543']),
        ['own_transfer[debit_leg]'],
      );
      expect(
        toPerson(name: 'SOMEONE ELSE', mask: '6544', owners: const ['mask:6543']),
        isNot(contains('own_transfer[debit_leg]')),
      );
    });
  });

  group('family, only ever by a mark the person made', () {
    const kin = ['family:payee:Kabir Dattatray Rangnekar'];

    test('a payment to a family member the person marked is left out of spending', () {
      expect(
        toPerson(name: 'KABIR DATTATRAY RANGNEKAR', owners: [...owner, ...kin]),
        ['own_transfer[debit_leg]'],
      );
      expect(
        fromPerson(name: 'KABIR DATTATRAY RANGNEKAR', owners: [...owner, ...kin]),
        ['own_transfer[credit_leg]'],
      );
    });

    test('the same payee unmarked, and a different relative, stay payments', () {
      expect(toPerson(name: 'KABIR DATTATRAY RANGNEKAR'), isNot(contains('own_transfer[debit_leg]')));
      expect(
        toPerson(name: 'ROHAN DATTATRAY RANGNEKAR', owners: [...owner, ...kin]),
        isNot(contains('own_transfer[debit_leg]')),
      );
    });

    test('a family handle or account the person marked', () {
      expect(
        toPerson(name: 'X', vpa: 'kabir@okaxis', owners: const ['family:vpa:kabir@okaxis']),
        ['own_transfer[debit_leg]'],
      );
      expect(
        toPerson(name: 'X', mask: '4321', owners: const ['family:mask:4321']),
        ['own_transfer[debit_leg]'],
      );
    });

    test('a shop is never family by name alone', () {
      expect(toPerson(name: 'RANGNEKAR STORES', owners: [...owner, ...kin]), isNot(contains('own_transfer[debit_leg]')));
    });
  });

  group('a single payment marked by the person', () {
    List<String> one(String key, List<String> owners) => shapes(
      linkAll([
        debit(
          'p2p',
          500000,
          at: '2026-11-03T10:00:00Z',
          inst: hdfcAcct,
          sourceKey: 'sms:one',
          counterparty: party(name: 'RAVI KUMAR JOSHI'),
        ),
        debit(
          'p2p',
          500000,
          at: '2026-11-04T10:00:00Z',
          inst: hdfcAcct,
          sourceKey: 'sms:two',
          counterparty: party(name: 'RAVI KUMAR JOSHI'),
        ),
      ], ownerNames: owners),
    );

    test('only that payment changes; the same payee later is still a payment', () {
      final shapesOut = one('x', const ['once:family:sms:one']);
      expect(shapesOut.where((e) => e.startsWith('own_transfer')), hasLength(1));
      expect(shapesOut, hasLength(2));
      final self = one('x', const ['once:self:sms:two']);
      expect(self.where((e) => e.startsWith('own_transfer')), hasLength(1));
      expect(one('x', const []).where((e) => e.startsWith('own_transfer')), isEmpty);
    });
  });
}
