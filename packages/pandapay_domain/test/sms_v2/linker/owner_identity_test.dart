import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';
import 'owner_vocabulary_support.dart';

OwnerIdentity _id(String name) => OwnerIdentity(names: [OwnerName.parse(name)!]);

void main() {
  setUpAll(installRepoOwnerVocabulary);

  group('an owner name needs a first and a last word', () {
    test('a username-style or one-word name is not a name', () {
      expect(OwnerName.parse('ishaanrangnekar24'), isNull);
      expect(OwnerName.parse('Ishaan'), isNull);
      expect(OwnerName.parse(''), isNull);
      expect(OwnerName.parse(null), isNull);
      expect(OwnerName.parse('Mr Ishaan'), isNull, reason: 'honorific is not a word');
    });

    test('reading order gives first, middle and last', () {
      final n = OwnerName.parse('Mr Ishaan Dattatray Rangnekar')!;
      expect(n.first, 'ISHAAN');
      expect(n.middles, ['DATTATRAY']);
      expect(n.last, 'RANGNEKAR');
    });

    test('typed parts build the same name', () {
      final a = OwnerName.fromParts(first: 'Ishaan', last: 'Rangnekar')!;
      expect(a.words, ['ISHAAN', 'RANGNEKAR']);
      expect(OwnerName.fromParts(first: 'S', last: 'Rangnekar'), isNull);
    });
  });

  group('a three-word owner: every way a bank prints it', () {
    final id = _id('Ishaan Dattatray Rangnekar');
    for (final printed in [
      'ISHAAN DATTATRAY RANGNEKAR',
      'ishaan dattatray rangnekar',
      'ISHAAN DATTATRAY RANG', // cut short by the bank
      'ISHAAN DATTATRAY RAN',
      'ISHAAN RANGNEKAR', // first and last
      'ISHAAN D RANGNEKAR', // middle as an initial
      'ISHAAN DATTATRAY R', // last name as an initial, middle in full
      'ISHAAN DATTATRAY', // cut before the surname
      'MR ISHAAN DATTATRAY RANGNEKAR',
      'Mrs. Ishaan Rangnekar',
      'RANGNEKAR ISHAAN DATTATRAY', // surname first
      'RANGNEKAR ISHAAN',
      'ISHAANRANGNEKAR', // run together
      'ISHAANDATTATRAYRANG', // run together and cut short
      'ISHAAN RANG',
      'ishaanrangnekar-2@okhdfcbank', // a handle printed as a name
      'ishaanrangnekar@okicici',
    ]) {
      test('matches "$printed"', () => expect(id.matchesName(printed), isTrue));
    }
  });

  group('a three-word owner: people who are not the owner', () {
    final id = _id('Ishaan Dattatray Rangnekar');
    for (final printed in [
      'KABIR DATTATRAY RANGNEKAR', // a sibling: middle and last name shared
      'KABIR S RANGNEKAR',
      'DATTATRAY RANGNEKAR', // no first name
      'ISHAAN', // first name alone
      'RANGNEKAR', // surname alone
      'DATTATRAY',
      'S RANGNEKAR',
      'ISHAAN R', // an initial is too thin
      'ISHAAN RANGNEKAR PATIL', // an extra full word: someone else
      'ISHAAN RAMESH RANGNEKAR', // a different middle name
      'ISHAAN DATTATRAY PATIL',
      'ISHAANA RANGNEKAR', // a similar first name
      'ISHAAN RANGNEKARE',
      'ISHAAN DATT', // a clipped middle name is not evidence
      'rohanrangnekar76@okaxis', // a relative's handle
      'nikhilrangnekar96@okaxis',
      'ishaanrangnekarpatil@okaxis',
      'patelneel3@okicici',
      '9000000001@ybl',
      '',
    ]) {
      test('does not match "$printed"', () => expect(id.matchesName(printed), isFalse));
    }
  });

  group('a two-word owner (no middle name given)', () {
    final id = _id('Ishaan Rangnekar');
    test('matches the prints that add nothing the owner did not give', () {
      for (final printed in [
        'ISHAAN RANGNEKAR',
        'RANGNEKAR ISHAAN',
        'ISHAANRANGNEKAR',
        'ISHAAN RANG',
        'MR ISHAAN RANGNEKAR',
        'ishaanrangnekar-1@okhdfcbank',
      ]) {
        expect(id.matchesName(printed), isTrue, reason: printed);
      }
    });
    test('a middle name the owner did not give is never guessed', () {
      // The bank prints the father's name; a sibling prints the same words. The
      // person confirms it once instead (see the "confirmed" test below).
      for (final printed in [
        'ISHAAN DATTATRAY RANGNEKAR',
        'ISHAAN D RANGNEKAR',
        'ISHAAN DATTATRAY RANG',
        'RANGNEKAR ISHAAN DATTATRAY',
        'MR ISHAAN DATTATRAY RANGNEKAR',
      ]) {
        expect(id.matchesName(printed), isFalse, reason: printed);
      }
    });
    test('once the person confirms the printed name it matches, and only it', () {
      final confirmed = OwnerIdentity(
        names: [OwnerName.parse('Ishaan Rangnekar')!],
        payeeNames: ['ISHAAN DATTATRAY RANGNEKAR'],
      );
      expect(confirmed.matchesName('ISHAAN DATTATRAY RANGNEKAR'), isTrue);
      expect(confirmed.matchesName('Mr Ishaan Dattatray Rangnekar'), isTrue);
      expect(confirmed.matchesName('KABIR DATTATRAY RANGNEKAR'), isFalse);
      expect(confirmed.matchesName('ISHAAN RAMESH RANGNEKAR'), isFalse);
    });
    test('refuses a first name, a surname, a relative or an extra surname', () {
      for (final printed in [
        'ISHAAN',
        'RANGNEKAR',
        'ISHAAN R',
        'ISHAAN DATTATRAY', // no last name at all
        'ISHAAN DATTATRAY R',
        'KABIR RANGNEKAR',
        'KABIR DATTATRAY RANGNEKAR', // a sibling
        'ISHAAN RANGNEKAR PATIL', // an extra word after the last name
        'PATIL ISHAAN RANGNEKAR', // an extra word before
        'DATTATRAY ISHAAN RANGNEKAR', // a middle word in the wrong place
        'rohanrangnekar76@okaxis',
      ]) {
        expect(id.matchesName(printed), isFalse, reason: printed);
      }
    });
  });

  group('typed parts', () {
    final id = OwnerIdentity(
      names: [OwnerName.fromParts(first: 'Ishaan', last: 'Rangnekar')!],
    );
    test('behave like a two-word name', () {
      expect(id.matchesName('ISHAAN RANGNEKAR'), isTrue);
      expect(id.matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
      expect(id.matchesName('KABIR DATTATRAY RANGNEKAR'), isFalse);
    });
  });

  group('handles', () {
    final id = _id('Ishaan Dattatray Rangnekar');
    test('built from the name, with digits, dots or hyphens', () {
      for (final v in [
        'ishaanrangnekar@okicici',
        'ishaanrangnekar-4@okaxis',
        'ishaan.rangnekar2@okhdfcbank',
        'rangnekarishaan@oksbi',
        'IshaanRangnekar@ybl',
        'ishaandattatrayrangnekar@upi',
      ]) {
        expect(id.matchesVpa(v), isTrue, reason: v);
      }
    });
    test('a handle that is not the name is refused', () {
      for (final v in ['ishaan@okaxis', 'rangnekar@okaxis', 'ishaanrangnekarpatil@ybl', null, '']) {
        expect(id.matchesVpa(v), isFalse, reason: '$v');
      }
    });
    test('a handle the person marked matches exactly', () {
      final marked = OwnerIdentity(vpas: ['9000000001@ybl']);
      expect(marked.matchesVpa('9000000001@YBL'), isTrue);
      expect(marked.matchesVpa('9527190867@ybl'), isFalse);
      expect(marked.matchesName('9000000001@ybl'), isTrue);
    });
  });

  group('payees and accounts the person marked as their own', () {
    final id = OwnerIdentity(
      payeeNames: ['Vikram Raghunath Joshi', 'Solo'],
      accountMasks: ['6543', '12'],
    );
    test('a marked payee name matches however it is cased', () {
      expect(id.matchesName('VIKRAM RAGHUNATH JOSHI'), isTrue);
      expect(id.matchesName('Vikram Raghunath'), isFalse, reason: 'only the marked name');
    });
    test('a one-word payee is not stored', () => expect(id.matchesName('Solo'), isFalse));
    test('account digits match exactly and need four digits', () {
      expect(id.matchesAccountMask('6543'), isTrue);
      expect(id.matchesAccountMask('6544'), isFalse);
      expect(id.matchesAccountMask('12'), isFalse);
    });
  });

  group('entries', () {
    test('survive a round trip through plain strings', () {
      final id = OwnerIdentity(
        names: [OwnerName.parse('Ishaan Dattatray Rangnekar')!],
        vpas: ['a@b'],
        payeeNames: ['Vikram Joshi'],
        accountMasks: ['6543'],
      );
      final back = OwnerIdentity.fromEntries(id.toEntries());
      expect(back.names, id.names);
      expect(back.vpas, id.vpas);
      expect(back.payeeNames, id.payeeNames);
      expect(back.accountMasks, id.accountMasks);
    });
    test('a plain one-word string is dropped, not guessed', () {
      expect(OwnerIdentity.fromEntries(['ishaanrangnekar24', 'Ishaan']).isEmpty, isTrue);
    });
    test('an empty identity claims nothing', () {
      final id = OwnerIdentity();
      expect(id.matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
      expect(id.matchesVpa('ishaanrangnekar@okicici'), isFalse);
    });
  });

  group('"not me" overrides every match', () {
    final id = OwnerIdentity(
      names: [OwnerName.parse('Ishaan Rangnekar')!],
      notNames: ['ISHAAN DATTATRAY RANGNEKAR'],
      notVpas: ['ishaanrangnekar-9@okaxis'],
      accountMasks: ['6543'],
      notMasks: ['6543'],
    );
    test('a printed name the person rejected stops matching', () {
      expect(id.matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
      expect(id.matchesName('ISHAAN RANGNEKAR'), isTrue, reason: 'other prints still match');
    });
    test('a handle built from the name but rejected stops matching', () {
      expect(id.matchesVpa('ishaanrangnekar-9@okaxis'), isFalse);
      expect(id.matchesVpa('ishaanrangnekar-1@okaxis'), isTrue);
    });
    test('an account marked and then rejected is not the owner', () {
      expect(id.matchesAccountMask('6543'), isFalse);
    });
    test('survives the entries round trip', () {
      final back = OwnerIdentity.fromEntries(id.toEntries());
      expect(back.notNames, id.notNames);
      expect(back.notVpas, id.notVpas);
      expect(back.notMasks, id.notMasks);
      expect(back.matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
    });
  });

  group('family marks', () {
    final id = OwnerIdentity(
      names: [OwnerName.parse('Ishaan Dattatray Rangnekar')!],
      familyNames: ['Kabir Dattatray Rangnekar'],
      familyVpas: ['kabir@okaxis'],
      familyMasks: ['4321'],
    );
    test('a marked family payee is family, by name, handle or account', () {
      expect(id.isFamilyPayee(name: 'KABIR DATTATRAY RANGNEKAR'), isTrue);
      expect(id.isFamilyPayee(name: 'Mr Kabir Dattatray Rangnekar'), isTrue);
      expect(id.isFamilyPayee(vpa: 'KABIR@okaxis'), isTrue);
      expect(id.isFamilyPayee(mask: '4321'), isTrue);
    });
    test('nothing is family unless the person marked it', () {
      expect(id.isFamilyPayee(name: 'ROHAN DATTATRAY RANGNEKAR'), isFalse);
      expect(id.isFamilyPayee(name: 'KABIR'), isFalse);
      expect(id.isFamilyPayee(vpa: 'rohan@okaxis'), isFalse);
      expect(id.isFamilyPayee(mask: '9999'), isFalse);
      expect(OwnerIdentity().isFamilyPayee(name: 'KABIR DATTATRAY RANGNEKAR'), isFalse);
    });
    test('a family member is never matched as the owner', () {
      expect(id.matchesName('KABIR DATTATRAY RANGNEKAR'), isFalse);
    });
    test('a single payment can be marked without marking its payee', () {
      final once = OwnerIdentity(onceFamily: ['sms:42'], onceSelf: ['sms:43']);
      expect(once.isFamilyTransfer(sourceKey: 'sms:42'), isTrue);
      expect(once.isFamilyTransfer(sourceKey: 'sms:43'), isFalse);
      expect(once.isMarkedSelfOnce('sms:43'), isTrue);
      expect(once.isMarkedSelfOnce('sms:42'), isFalse);
      expect(once.isMarkedSelfOnce(null), isFalse);
      expect(once.isFamilyTransfer(name: 'ANYONE ELSE', sourceKey: 'sms:99'), isFalse);
    });
    test('entries round-trip', () {
      final again = OwnerIdentity.fromEntries(id.toEntries());
      expect(again.familyNames, id.familyNames);
      expect(again.familyVpas, id.familyVpas);
      expect(again.familyMasks, id.familyMasks);
      final once = OwnerIdentity.fromEntries(
        OwnerIdentity(onceFamily: ['a'], onceSelf: ['b']).toEntries(),
      );
      expect(once.onceFamily, {'a'});
      expect(once.onceSelf, {'b'});
      expect(OwnerIdentity.fromEntries(const []).isEmpty, isTrue);
    });
  });
}
