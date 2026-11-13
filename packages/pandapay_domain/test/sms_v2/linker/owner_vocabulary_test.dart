import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'owner_vocabulary_support.dart';

void main() {
  tearDown(installRepoOwnerVocabulary);

  test('the shipped pack carries the words, not the code', () {
    installRepoOwnerVocabulary();
    final v = OwnerVocabulary.current;
    expect(v.honorifics, containsAll(['MR', 'SHRI', 'DR']));
    expect(v.greetingWords, containsAll(['dear', 'hi']));
    expect(v.notNames, containsAll(['CUSTOMER', 'SIR']));
    expect([v.minSightings, v.minSenders, v.maxLearned], [3, 3, 3]);
  });

  test('without a vocabulary nothing is stripped and nothing is learned', () {
    OwnerVocabulary.install(OwnerVocabulary.empty);
    expect(OwnerName.parse('Mr Ishaan Rangnekar')!.words, ['MR', 'ISHAAN', 'RANGNEKAR']);
    expect(greetingName('Dear Ishaan Rangnekar, your order shipped'), isNull);
    // What the person typed still matches.
    final id = OwnerIdentity(names: [OwnerName.parse('Ishaan Rangnekar')!]);
    expect(id.matchesName('ISHAAN RANGNEKAR'), isTrue);
  });

  test('a pack without the section leaves the installed vocabulary alone', () {
    installRepoOwnerVocabulary();
    OwnerVocabulary.installFromPackParams({'accept': 0.8});
    expect(OwnerVocabulary.current.honorifics, isNotEmpty);
    OwnerVocabulary.installFromPackParams({'ownerIdentity': <String, Object?>{}});
    expect(OwnerVocabulary.current.honorifics, isEmpty);
  });

  test('wrong types fall back to nothing, numbers are bounded', () {
    final v = OwnerVocabulary.fromJson({
      'honorifics': 'MR',
      'greetingWords': ['dear', 7, 'a', 'with space'],
      'notNames': [null],
      'minSightings': 0,
      'minSenders': 'x',
      'maxLearned': 500,
    });
    expect(v.honorifics, isEmpty);
    expect(v.greetingWords, ['dear']);
    expect(v.notNames, isEmpty);
    expect([v.minSightings, v.minSenders, v.maxLearned], [3, 3, 3]);
    expect(OwnerVocabulary.fromJson(null).greetingWords, isEmpty);
  });

  test('a rule bundle with the section installs it for the linker and the learner', () {
    OwnerVocabulary.install(OwnerVocabulary.empty);
    OwnerVocabulary.installFromPackParams({
      'ownerIdentity': {
        'honorifics': ['SRI'],
        'greetingWords': ['namaste'],
        'notNames': ['FRIEND'],
      },
    });
    expect(OwnerName.parse('Sri Asha Rao')!.words, ['ASHA', 'RAO']);
    expect(greetingName('Namaste Asha Rao, welcome back'), 'ASHA RAO');
    expect(greetingName('Namaste Dear Friend, welcome'), isNull);
  });
}
