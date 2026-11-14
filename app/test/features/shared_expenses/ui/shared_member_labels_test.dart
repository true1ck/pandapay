import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart' show cacheNamespaceProvider;
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/data/shared_directory.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_invite_inbox.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_join_requests_page.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_members_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_rename_member_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    group = '22222222-2222-4222-8222-222222222222',
    me = '33333333-3333-4333-8333-333333333333',
    friend = '44444444-4444-4444-8444-444444444444',
    other = '55555555-5555-4555-8555-555555555555';
final sessionNamespace = StateProvider<String>((ref) => 'user:$account');

const dot = '••';

class Runtime extends SharedExpensesRuntime {
  Runtime({required super.store, required super.remote, required super.cache})
    : super(isCurrent: () => true);
  List<SharedEditorMember> people = const [];
  List<SharedJoinRequest> requests = const [];
  bool owner = true, direct = false;
  @override
  Future<List<SharedInboxInvite>> inviteInbox() async => const [];
  @override
  Future<List<SharedJoinRequest>> joinRequests() async => requests;

  /// Applies queued renames the way the real roster does.
  @override
  Future<SharedRoster> contextRoster(String id) async {
    final queued = <Object?, Object?>{
      for (final op in store.readPendingOperations(contextId: id).items)
        if (op.command.kind == 'member.rename')
          (op.command.toJson()['payload'] as Map)['memberId']:
              (op.command.toJson()['payload'] as Map)['displayName'],
    };
    return SharedRoster(
      name: 'Trip Group',
      ownMemberId: me,
      direct: direct,
      canInvite: owner && proposalsEnabled,
      members: [
        for (final m in people)
          queued[m.id] == null || m.id == me
              ? m
              : SharedEditorMember(
                  m.id,
                  queued[m.id] as String,
                  state: m.state,
                  role: m.role,
                  profileId: m.profileId,
                  phoneSuffix: m.phoneSuffix,
                  rawName: queued[m.id] as String,
                ),
      ],
    );
  }
}

void main() {
  late AppDatabase db;
  late Runtime runtime;
  late AuthenticatedHttpClient client;
  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    runtime = Runtime(
      store: SharedExpensesStore(db, namespace: 'user:$account'),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: 'user:$account',
        client: client,
        accessToken: () => null,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
    )..capabilities = {'reads': true, 'proposals': true, 'settlements': true};
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
    BambooFonts.useSystemFontsForTests = false;
  });

  Future<void> show(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          cacheNamespaceProvider.overrideWith(
            (ref) => ref.watch(sessionNamespace),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMembers(WidgetTester tester) => show(
    tester,
    SharedMembersSheet(
      runtime: runtime,
      contextId: group,
      groupName: 'Trip Group',
    ),
  );

  test('name validation: empty and over 40 characters are refused', () {
    expect(sharedMemberNameError(''), 'Enter a name.');
    expect(sharedMemberNameError('   '), 'Enter a name.');
    expect(sharedMemberNameError('a' * 41), contains('40'));
    expect(sharedMemberNameError('a' * 40), isNull);
    expect(sharedMemberNameError('Rahul K'), isNull);
  });

  test('runtime refuses a bad name before anything is queued', () async {
    await expectLater(
      runtime.renameMember(contextId: group, memberId: friend, name: '  '),
      throwsFormatException,
    );
    await expectLater(
      runtime.renameMember(contextId: group, memberId: friend, name: 'a' * 41),
      throwsFormatException,
    );
    expect(runtime.store.readPendingOperations().items, isEmpty);
  });

  testWidgets('rename dialog shows inline errors and returns a clean name', (
    tester,
  ) async {
    String? result = 'untouched';
    await show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showSharedRenameMemberDialog(
            context,
            title: 'Edit name',
            initialName: 'Rahul',
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('rename-member-field'));
    await tester.enterText(field, '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name.'), findsOneWidget);
    await tester.enterText(field, 'a' * 41);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('40 characters'), findsOneWidget);
    await tester.enterText(field, '  Rahul   K ');
    await tester.pump();
    expect(find.textContaining('40 characters'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'Rahul K');
  });

  testWidgets('owner renames a member and the list updates at once', (
    tester,
  ) async {
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(friend, 'Rahul', profileId: friend),
    ];
    await openMembers(tester);
    expect(find.text('Rahul'), findsOneWidget);
    await tester.tap(find.byKey(Key('edit-name-$friend')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-member-field')),
      'Rahul Kumar',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Rahul Kumar'), findsOneWidget);
    expect(find.text('Rahul'), findsNothing);
    // Success feedback: saved on the phone, waiting for the server.
    expect(find.text("Saved. It will sync in the background."), findsOneWidget);
    final queued = runtime.store
        .readPendingOperations(contextId: group)
        .items
        .where((o) => o.command.kind == 'member.rename')
        .toList();
    expect(queued, hasLength(1));
    expect(queued.single.command.toJson()['payload'], {
      'contextId': group,
      'memberId': friend,
      'displayName': 'Rahul Kumar',
    });
  });

  testWidgets('who may edit: owner edits anyone, a member only themselves', (
    tester,
  ) async {
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(friend, 'Rahul', profileId: friend),
      const SharedEditorMember(other, 'Gone', state: 'left'),
    ];
    await openMembers(tester);
    expect(find.byKey(Key('edit-name-$me')), findsOneWidget);
    expect(find.byKey(Key('edit-name-$friend')), findsOneWidget);
    expect(find.byKey(Key('edit-name-$other')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    runtime.owner = false;
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account),
      const SharedEditorMember(
        friend,
        'Boss',
        profileId: friend,
        role: 'owner',
      ),
    ];
    await openMembers(tester);
    expect(find.byKey(Key('edit-name-$me')), findsOneWidget);
    expect(find.byKey(Key('edit-name-$friend')), findsNothing);
  });

  testWidgets('two people with the same name are told apart by number', (
    tester,
  ) async {
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(
        friend,
        'Rahul',
        profileId: friend,
        phoneSuffix: '4821',
      ),
      const SharedEditorMember(
        other,
        'Rahul',
        profileId: other,
        phoneSuffix: '1190',
      ),
    ];
    await openMembers(tester);
    expect(find.byKey(Key('member-hint-$friend')), findsOneWidget);
    expect(find.text('${dot}4821'), findsOneWidget);
    expect(find.text('${dot}1190'), findsOneWidget);
  });

  testWidgets('unique names get no extra line', (tester) async {
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(
        friend,
        'Rahul',
        profileId: friend,
        phoneSuffix: '4821',
      ),
    ];
    await openMembers(tester);
    expect(find.textContaining(dot), findsNothing);
  });

  Future<void> inbox(WidgetTester tester, SharedJoinRequest request) async {
    runtime.requests = [request];
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SharedJoinRequestsPage(runtime: runtime),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SharedJoinRequest join(Map<String, Object?> extra) =>
      SharedJoinRequest.fromJson({
        'invitationId': '66666666-6666-4666-8666-666666666666',
        'contextId': group,
        'contextName': 'Goa',
        ...extra,
      });

  testWidgets('request row: label as title, signed-in line when it differs', (
    tester,
  ) async {
    await inbox(
      tester,
      join({
        'memberName': 'Rahul',
        'claimantName': 'Rahul Kumar',
        'claimantProfileName': 'Rahul Kumar',
        'claimantPhoneSuffix': '4821',
      }),
    );
    expect(find.text('Rahul'), findsOneWidget);
    expect(
      find.text('Signed in as Rahul Kumar \u00b7 \u2022\u20224821'),
      findsOneWidget,
    );
  });

  testWidgets('request row without profile data falls back gracefully', (
    tester,
  ) async {
    await inbox(tester, join({'memberName': 'Rahul'}));
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.textContaining('Signed in as'), findsNothing);
  });

  testWidgets('request row shows no duplicate line when names match', (
    tester,
  ) async {
    await inbox(
      tester,
      join({'memberName': 'Asha', 'claimantProfileName': 'Asha'}),
    );
    expect(find.textContaining('Signed in as'), findsNothing);
  });

  Map<String, Object?> ctxRow(String id, String name, {String? suffix}) => {
    'contextId': id,
    'name': name,
    'owedMinor': '0',
    'owingMinor': '0',
    'expenseCount': '0',
    'counterpartPhoneSuffix': ?suffix,
  };

  test('renaming a friend retitles the friend split at once', () async {
    final rows = [ctxRow(group, 'Rahul'), ctxRow(other, 'Asha')];
    expect(runtime.contextRows(rows).map((r) => r.title), ['Rahul', 'Asha']);
    await runtime.renameMember(
      contextId: group,
      memberId: friend,
      name: 'Rahul Kumar',
      directCounterpart: true,
    );
    expect(runtime.contextRows(rows).map((r) => r.title), [
      'Rahul Kumar',
      'Asha',
    ]);
  });

  test('renaming yourself does not retitle the friend split', () async {
    await runtime.renameMember(contextId: group, memberId: me, name: 'Sujay K');
    expect(runtime.contextRows([ctxRow(group, 'Rahul')]).single.title, 'Rahul');
  });

  test('friend rows with the same title get a number ending', () {
    final rows = runtime.contextRows([
      ctxRow(group, 'Rahul', suffix: '4821'),
      ctxRow(other, 'Rahul', suffix: '1190'),
      ctxRow(friend, 'Asha', suffix: '7777'),
    ]);
    expect(rows.map((r) => r.subtitle), ['${dot}4821', '${dot}1190', null]);
    final unknown = runtime.contextRows([
      ctxRow(group, 'Rahul'),
      ctxRow(other, 'Rahul'),
    ]);
    expect(unknown.map((r) => r.subtitle), [null, null]);
  });

  testWidgets('editing a friend in a direct split retitles the friend list', (
    tester,
  ) async {
    runtime.direct = true;
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(friend, 'Rahul', profileId: friend),
    ];
    await openMembers(tester);
    await tester.tap(find.byKey(Key('edit-name-$friend')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-member-field')),
      'Rahul Kumar',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      runtime.contextRows([ctxRow(group, 'Rahul')]).single.title,
      'Rahul Kumar',
    );
  });

  testWidgets('120-char label at 2x font scale never overflows', (
    tester,
  ) async {
    final long = 'Ramachandran ' * 9 + 'Iyer';
    expect(long.length, greaterThan(115));
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    runtime.requests = [
      join({
        'memberName': long,
        'claimantProfileName': 'Different ${'Name ' * 25}',
        'claimantPhoneSuffix': '4821',
      }),
    ];
    Widget scaled(Widget home) => ProviderScope(
      overrides: [
        sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.0)),
          child: c!,
        ),
        home: home,
      ),
    );
    await tester.pumpWidget(scaled(SharedJoinRequestsPage(runtime: runtime)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ramachandran'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      scaled(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSharedRenameMemberDialog(
                context,
                title: 'Edit name',
                initialName: long,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rename-member-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('members sheet with a 120-char label at 2x does not overflow', (
    tester,
  ) async {
    final long = 'Ramachandran ' * 9 + 'Iyer';
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      SharedEditorMember(friend, long, profileId: friend, rawName: long),
      SharedEditorMember(other, long, profileId: other, phoneSuffix: '1190'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          cacheNamespaceProvider.overrideWith(
            (ref) => ref.watch(sessionNamespace),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: c!,
          ),
          home: Scaffold(
            body: SharedMembersSheet(
              runtime: runtime,
              contextId: group,
              groupName: 'Trip Group',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('7 requests at 2x: one summary row, friends list reachable', (
    tester,
  ) async {
    final long = 'Ramachandran ' * 9 + 'Iyer';
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    runtime.requests = [
      for (var n = 0; n < 7; n++)
        SharedJoinRequest.fromJson({
          'invitationId': '66666666-6666-4666-8666-66666666666$n',
          'contextId': group,
          'contextName': 'Goa',
          'memberName': n == 3 ? long : 'Person $n',
        }),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: c!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                SharedInviteInbox(runtime: runtime),
                Expanded(
                  child: ListView(
                    children: [
                      for (var n = 0; n < 20; n++)
                        ListTile(title: Text('Friend row $n')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('7 people want to join'), findsOneWidget);
    expect(find.text('Friend row 0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Friend row 19'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.takeException(), isNull);
  });
}
