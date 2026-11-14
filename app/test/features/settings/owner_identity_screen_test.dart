import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/settings/owner_identity_screen.dart';
import 'package:pandapay/features/sms_v2/personal/owner_identity_store.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import '../../support/owner_vocabulary_support.dart';

const _ns = 'user:owner-screen';


Finder _field(String label) => find.ancestor(
  of: find.text('$label *', findRichText: true),
  matching: find.byType(TextField),
);

void main() {
  setUpAll(installRepoOwnerVocabulary);

  late AppDatabase db;
  late ResponseCache cache;
  late OwnerIdentityStore store;

  setUp(() {
    db = openInMemoryForTesting();
    SmsV2Schema.ensure(db.db);
    cache = ResponseCache(db);
    store = OwnerIdentityStore(db.db, namespace: _ns);
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    // A tall screen, so every row is built.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          responseCacheProvider.overrideWith((ref) async => cache),
          cacheNamespaceProvider.overrideWithValue(_ns),
          smsV2RuntimeProvider.overrideWith((ref) async => null),
        ],
        child: const MaterialApp(home: OwnerIdentityScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('starts empty, says how the name is found, and offers the form', (tester) async {
    await pump(tester);
    expect(find.text('Your names & accounts'), findsOneWidget);
    expect(find.textContaining('None yet'), findsOneWidget);
    expect(find.text('First name *', findRichText: true), findsOneWidget);
    expect(find.text('Last name *', findRichText: true), findsOneWidget);
    expect(find.text('Add name'), findsOneWidget);
  });

  testWidgets('a first and a last name are both required', (tester) async {
    await pump(tester);
    await tester.enterText(_field('First name'), 'Asha');
    await tester.tap(find.text('Add name'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(store.entries(), isEmpty);
  });

  testWidgets('adding a name lists it and clears the form', (tester) async {
    await pump(tester);
    await tester.enterText(_field('First name'), 'Asha');
    await tester.enterText(_field('Last name'), 'Rao');
    await tester.tap(find.text('Add name'));
    await tester.pumpAndSettle();

    expect(store.entries(), ['ASHA RAO']);
    expect(find.text('ASHA RAO'), findsOneWidget);
    expect(find.text('You added this'), findsOneWidget);
    expect(find.textContaining('None yet'), findsNothing);
    final first = tester.widget<TextField>(_field('First name'));
    expect(first.controller!.text, isEmpty);
  });

  testWidgets('learned and marked entries say where they came from and can be removed', (tester) async {
    store.noteGreetings([
      for (final s in ['A', 'B', 'C']) (body: 'Dear Asha Rao, hello there', sender: s),
    ]);
    store.markOwn(vpa: 'asha@okaxis', mask: '6543');
    store.markNotOwn(name: 'Kabir Maria Rao');
    await pump(tester);

    expect(find.text('Learned from your messages'), findsOneWidget);
    expect(find.text('UPI ID asha@okaxis'), findsOneWidget);
    expect(find.text('Account ending 6543'), findsOneWidget);
    expect(find.text('KABIR MARIA RAO'), findsOneWidget);
    expect(find.text('Marked as not yours'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('Learned from your messages'), findsNothing);
    // A learned name that is removed is remembered, so it is not learned again.
    expect(store.list().where((e) => e.source == OwnerEntrySource.dismissed), isNotEmpty);
  });

  testWidgets('the profile name counts when it is a real name, not when it is a username', (tester) async {
    db.saveProfileDisplayName(_ns, 'ishaanrangnekar24');
    await pump(tester);
    expect(find.text('From your profile'), findsNothing);

    db.saveProfileDisplayName(_ns, 'Ishaan Rangnekar');
    await pump(tester);
    expect(find.text('Ishaan Rangnekar'), findsOneWidget);
    expect(find.text('From your profile'), findsOneWidget);
  });

  testWidgets('family members and single payments are listed apart and can be removed', (tester) async {
    store.markFamily(name: 'Kabir Maria Rao', vpa: 'kabir@okaxis');
    store.markOnce(sourceKey: 'sms:one', family: true);
    store.markOnce(sourceKey: 'sms:two', family: false);
    store.markOwn(vpa: 'asha@okaxis');
    await pump(tester);

    expect(find.text('Family members you marked'), findsOneWidget);
    expect(find.text('KABIR MARIA RAO'), findsOneWidget);
    expect(find.text('UPI ID kabir@okaxis'), findsOneWidget);
    expect(find.text('Single payments you marked'), findsOneWidget);
    expect(find.text('One payment (Family transfer)'), findsOneWidget);
    expect(find.text('One payment (Self transfer)'), findsOneWidget);
    // Own payees stay in their own section, not mixed with family.
    expect(find.text('Payees you marked as your own'), findsOneWidget);
    expect(find.text('UPI ID asha@okaxis'), findsOneWidget);

    final row = find.ancestor(
      of: find.text('KABIR MARIA RAO'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Remove')));
    await tester.pumpAndSettle();
    expect(store.entries(), isNot(contains('family:payee:KABIR MARIA RAO')));
    expect(store.entries(), contains('family:vpa:kabir@okaxis'));
  });
}
