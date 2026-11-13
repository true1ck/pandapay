import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/personal/owner_identity_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../../support/owner_vocabulary_support.dart';

void main() {
  setUpAll(installRepoOwnerVocabulary);

  late Database db;
  late OwnerIdentityStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = OwnerIdentityStore(db, namespace: 'user:a');
  });
  tearDown(() => db.dispose());

  group('names', () {
    test('a first and a last name are required', () {
      expect(() => store.addName(first: 'Ishaan', last: ''), throwsArgumentError);
      expect(() => store.addName(first: '', last: 'Rangnekar'), throwsArgumentError);
      expect(store.entries(), isEmpty);
    });

    test('a typed name matches itself; a middle name it lacks is not guessed', () {
      store.addName(first: 'Ishaan', last: 'Rangnekar');
      expect(store.entries(), ['ISHAAN RANGNEKAR']);
      expect(store.identity().matchesName('ISHAAN RANGNEKAR'), isTrue);
      expect(store.identity().matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
      expect(store.identity().matchesName('KABIR DATTATRAY RANGNEKAR'), isFalse);
      store.addName(first: 'Ishaan', middle: 'Dattatray', last: 'Rangnekar');
      expect(store.identity().matchesName('ISHAAN DATTATRAY RANGNEKAR'), isTrue);
      expect(store.identity().matchesName('KABIR DATTATRAY RANGNEKAR'), isFalse);
    });

    test('a username-style profile name is not a name; a real one is', () {
      expect(store.entries(profileName: 'ishaanrangnekar24'), isEmpty);
      expect(store.entries(profileName: 'Ishaan Rangnekar'), ['Ishaan Rangnekar']);
      expect(store.identity(profileName: 'Ishaan Rangnekar').matchesName('ISHAAN RANGNEKAR'), isTrue);
    });

    test('accounts do not see each other\'s identity', () {
      store.addName(first: 'Ishaan', last: 'Rangnekar');
      expect(OwnerIdentityStore(db, namespace: 'user:b').entries(), isEmpty);
    });
  });

  group('marking a payment', () {
    test('a payee, a handle and an account can be marked as the owner\'s own', () {
      store.markOwn(name: 'Vikram Raghunath Joshi', vpa: '9000000001@YBL', mask: '6543');
      final id = store.identity();
      expect(id.matchesName('VIKRAM RAGHUNATH JOSHI'), isTrue);
      expect(id.matchesVpa('9000000001@ybl'), isTrue);
      expect(id.matchesAccountMask('6543'), isTrue);
    });

    test('"not me" beats a name that matches, and undoes a mark', () {
      store.addName(first: 'Ishaan', last: 'Rangnekar');
      store.markNotOwn(name: 'ISHAAN DATTATRAY RANGNEKAR');
      expect(store.identity().matchesName('ISHAAN DATTATRAY RANGNEKAR'), isFalse);
      expect(store.identity().matchesName('ISHAAN RANGNEKAR'), isTrue);

      store.markOwn(name: 'Vikram Joshi');
      expect(store.identity().matchesName('VIKRAM JOSHI'), isTrue);
      store.markNotOwn(name: 'Vikram Joshi');
      expect(store.identity().matchesName('VIKRAM JOSHI'), isFalse);
      store.markOwn(name: 'Vikram Joshi');
      expect(store.identity().matchesName('VIKRAM JOSHI'), isTrue, reason: 'marking again undoes "not me"');
    });

    test('a one-word payee or a short account is not stored', () {
      store.markOwn(name: 'Vikram', mask: '12');
      expect(store.entries(), isEmpty);
    });
  });

  group('learning from greetings', () {
    ({String body, String sender}) m(String name, String sender) =>
        (body: 'Dear $name, your order is confirmed', sender: sender);

    test('a name seen often from several senders is learned', () {
      final changed = store.noteGreetings([
        for (final s in ['SHOPA', 'BROKERB', 'BANKC', 'SHOPA']) m('Ishaan Rangnekar', s),
      ]);
      expect(changed, isTrue);
      expect(store.entries(), ['ISHAAN RANGNEKAR']);
      expect(store.list().single.source, OwnerEntrySource.inferred);
    });

    test('one sender, however often, is not enough', () {
      final changed = store.noteGreetings([
        for (var i = 0; i < 10; i++) m('Sunita Patel', 'POLBAZ'),
      ]);
      expect(changed, isFalse);
      expect(store.entries(), isEmpty);
    });

    test('evidence adds up across batches', () {
      expect(store.noteGreetings([m('Ishaan Rangnekar', 'A'), m('Ishaan Rangnekar', 'B')]), isFalse);
      expect(store.noteGreetings([m('Ishaan Rangnekar', 'C')]), isTrue);
      expect(store.entries(), ['ISHAAN RANGNEKAR']);
    });

    test('a removed learned name is not learned again', () {
      store.noteGreetings([for (final s in ['A', 'B', 'C']) m('Ishaan Rangnekar', s)]);
      store.remove('ISHAAN RANGNEKAR');
      expect(store.entries(), isEmpty);
      store.noteGreetings([for (final s in ['D', 'E', 'F']) m('Ishaan Rangnekar', s)]);
      expect(store.entries(), isEmpty);
    });

    test('a typed name is not duplicated by the same learned name', () {
      store.addName(first: 'Ishaan', last: 'Rangnekar');
      final changed = store.noteGreetings([for (final s in ['A', 'B', 'C']) m('Ishaan Rangnekar', s)]);
      expect(changed, isFalse);
      expect(store.entries(), ['ISHAAN RANGNEKAR']);
    });

    test('at most three names are learned', () {
      store.noteGreetings([
        for (final n in ['Asha Rao', 'Ravi Joshi', 'Sita Pai', 'Omar Khan'])
          for (final s in ['A', 'B', 'C']) m(n, s),
      ]);
      expect(store.entries(), hasLength(OwnerVocabulary.current.maxLearned));
    });

    test('messages without a name change nothing', () {
      expect(
        store.noteGreetings([(body: 'Dear Customer, your payment is due', sender: 'A')]),
        isFalse,
      );
    });
  });

  test('removing a typed or marked row deletes it', () {
    store.addName(first: 'Ishaan', last: 'Rangnekar');
    store.markOwn(vpa: 'a@b');
    store.remove('ISHAAN RANGNEKAR');
    store.remove('vpa:a@b');
    expect(store.list(), isEmpty);
  });

  group('family and single payments', () {
    test('a family payee is stored apart from your own names', () {
      store.markFamily(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis', mask: '4321');
      expect(store.entries(), containsAll([
        'family:payee:KABIR MARIA RAO',
        'family:vpa:kabir@okaxis',
        'family:mask:4321',
      ]));
      final id = store.identity();
      expect(id.isFamilyPayee(name: 'KABIR MARIA RAO'), isTrue);
      expect(id.matchesName('KABIR MARIA RAO'), isFalse);
      expect(store.list().every((e) => e.source == OwnerEntrySource.marked), isTrue);
    });

    test('marking family replaces a "mine" or "not mine" mark, and the reverse', () {
      store.markOwn(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis');
      store.markNotOwn(mask: '4321');
      store.markFamily(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis', mask: '4321');
      expect(store.entries().where((e) => e.startsWith('payee:') || e.startsWith('vpa:') || e.startsWith('not:')), isEmpty);
      store.markOwn(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis');
      expect(store.entries().where((e) => e.startsWith('family:payee:') || e.startsWith('family:vpa:')), isEmpty);
      expect(store.entries(), contains('family:mask:4321'));
    });

    test('taking the family mark back removes it', () {
      store.markFamily(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis');
      store.unmarkFamily(name: 'Kabir Maria Rao', vpa: 'KABIR@okaxis');
      expect(store.entries(), isEmpty);
    });

    test('a single payment is marked by its message and replaced by the other kind', () {
      store.markOnce(sourceKey: 'sms:1', family: true);
      expect(store.entries(), ['once:family:sms:1']);
      expect(store.identity().isFamilyTransfer(sourceKey: 'sms:1'), isTrue);
      store.markOnce(sourceKey: 'sms:1', family: false);
      expect(store.entries(), ['once:self:sms:1']);
      expect(store.identity().isMarkedSelfOnce('sms:1'), isTrue);
      store.clearOnce('sms:1');
      expect(store.entries(), isEmpty);
      store.markOnce(sourceKey: '  ', family: true);
      expect(store.entries(), isEmpty);
    });

    test('marksOnly is empty rather than failing when the table is missing', () {
      final bare = sqlite3.openInMemory();
      addTearDown(bare.dispose);
      expect(OwnerIdentityStore(bare, namespace: 'x').marksOnly().isEmpty, isTrue);
    });
  });

  group('the owner tables arrive as their own migration', () {
    test('a database already at version 4 (subscriptions) gains them and keeps its data', () {
      final old = sqlite3.openInMemory();
      addTearDown(old.dispose);
      SmsV2Schema.ensure(old);
      old.execute('DROP TABLE v2_owner_identity');
      old.execute('DROP TABLE v2_owner_signals');
      old.execute("UPDATE sms_v2_schema_version SET version=4 WHERE module='sms_v2'");
      old.execute(
        "INSERT INTO v2_events (namespace, event_id, type, status, payload, dirty) VALUES ('a','e1','purchase','complete','{}',0)",
      );
      SmsV2Schema.ensure(old);
      expect(SmsV2Schema.installedVersion(old), SmsV2Schema.version);
      expect(SmsV2Schema.version, greaterThanOrEqualTo(5));
      expect(old.select('SELECT * FROM v2_events'), hasLength(1));
      final store = OwnerIdentityStore(old, namespace: 'a');
      store.addName(first: 'Asha', last: 'Rao');
      expect(store.entries(), ['ASHA RAO']);
    });

    test('both table lists name them', () {
      expect(SmsV2Schema.tableNames, containsAll(['v2_owner_identity', 'v2_owner_signals']));
    });
  });
}
