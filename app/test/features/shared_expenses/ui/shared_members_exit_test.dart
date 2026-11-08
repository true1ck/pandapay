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
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/data/shared_directory.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_invite_inbox.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_members_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_settle_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    group = '22222222-2222-4222-8222-222222222222',
    me = '33333333-3333-4333-8333-333333333333',
    friend = '44444444-4444-4444-8444-444444444444',
    report = '55555555-5555-4555-8555-555555555555';
final sessionNamespace = StateProvider<String>((ref) => 'user:$account');

class Runtime extends SharedExpensesRuntime {
  Runtime({required super.store, required super.remote, required super.cache})
    : super(isCurrent: () => true);
  List<SharedEditorMember> people = const [];
  List<SharedInboxInvite> invites = const [];
  final answered = <String>[];
  final left = <String>[];
  Object? leaveError;
  @override
  Future<void> leaveContext(String contextId) async {
    if (leaveError != null) throw leaveError!;
    left.add(contextId);
  }
  @override
  Future<List<SharedInboxInvite>> inviteInbox() async => invites;
  @override
  Future<List<SharedJoinRequest>> joinRequests() async => const [];
  @override
  Future<String> respondToInboxInvite(
    SharedInboxInvite invite, {
    required bool accept,
  }) async {
    answered.add('${invite.invitationId}:${accept ? 'accept' : 'decline'}');
    return accept ? 'awaiting_owner' : 'declined';
  }

  bool owner = true;
  @override
  Future<SharedRoster> contextRoster(String id) async => SharedRoster(
    name: 'Trip Group',
    ownMemberId: me,
    direct: false,
    canInvite: owner && proposalsEnabled,
    ownerGone: !people.any(
      (m) => m.role == 'owner' && m.state == 'active' && m.profileId != null,
    ),
    members: people,
  );
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
  Future<void> show(
    WidgetTester tester,
    Widget sheet, {
    double width = 430,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: sheet),
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

  testWidgets('owner can hand over to an active member, and cannot leave', (
    tester,
  ) async {
    runtime.people = [
      const SharedEditorMember(me, 'You', profileId: account, role: 'owner'),
      const SharedEditorMember(friend, 'Friend User', profileId: friend),
    ];
    await openMembers(tester);
    expect(find.text('Make owner'), findsOneWidget);
    expect(find.text('Leave this split'), findsNothing);
    expect(find.textContaining('Take over'), findsNothing);
  });

  testWidgets('a member can leave, and sees a deleted account as history', (
    tester,
  ) async {
    runtime.owner = false;
    runtime.people = [
      const SharedEditorMember(
        report,
        'Former member',
        profileId: null,
        role: 'member',
      ),
      const SharedEditorMember(me, 'You', profileId: account),
      const SharedEditorMember(
        friend,
        'Boss',
        profileId: friend,
        role: 'owner',
      ),
    ];
    await openMembers(tester);
    expect(find.text('Leave this split'), findsOneWidget);
    expect(find.text('Make owner'), findsNothing);
    expect(
      find.text('Account no longer active · history kept'),
      findsOneWidget,
    );
    expect(find.textContaining('Take over'), findsNothing);
  });

  testWidgets('members can take over when the owner account is gone', (
    tester,
  ) async {
    runtime.owner = false;
    runtime.people = [
      const SharedEditorMember(
        report,
        'Former member',
        profileId: null,
        role: 'owner',
      ),
      const SharedEditorMember(me, 'You', profileId: account),
    ];
    await openMembers(tester);
    expect(find.textContaining('Take over as owner'), findsOneWidget);
  });

  testWidgets('unjoined people are labelled in expense pickers', (
    tester,
  ) async {
    expect(
      const SharedEditorMember(friend, 'Asha', state: 'invited').label,
      'Asha (not joined yet)',
    );
    expect(const SharedEditorMember(friend, 'Asha').label, 'Asha');
  });

  testWidgets('an invite from a PandaPay user can be accepted or declined', (
    tester,
  ) async {
    runtime.invites = [
      SharedInboxInvite(
        invitationId: report,
        contextId: group,
        contextKind: 'group',
        contextName: 'Goa trip',
        inviterName: 'Riya S.',
      ),
    ];
    await show(tester, SharedInviteInbox(runtime: runtime));
    expect(find.textContaining('Goa trip'), findsWidgets);
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(runtime.answered, ['$report:decline']);
    expect(find.text('Declined.'), findsOneWidget);
  });

  testWidgets('a phone invitation waits for the owner after a join request', (
    tester,
  ) async {
    runtime.invites = [
      SharedInboxInvite(
        invitationId: report,
        contextId: group,
        contextKind: 'group',
        contextName: 'Group split',
        inviterName: 'Riya S.',
      ),
    ];
    var joined = false;
    await show(
      tester,
      SharedInviteInbox(runtime: runtime, onJoined: () => joined = true),
    );
    await tester.tap(find.text('Request to join'));
    await tester.pumpAndSettle();
    expect(runtime.answered, ['$report:accept']);
    expect(
      find.text('Request sent. The split owner will confirm.'),
      findsOneWidget,
    );
    expect(joined, isFalse);
  });

  testWidgets('leaving closes the sheet and reports it to the screen below', (
    tester,
  ) async {
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
    bool? result;
    await show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await SharedMembersSheet.show(
            context,
            runtime: runtime,
            contextId: group,
            groupName: 'Trip Group',
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave this split'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(runtime.left, [group]);
    expect(result, isTrue);
    expect(find.text('Leave this split'), findsNothing);
  });

  testWidgets(
    'leaving with unsettled balances triggers guided Bamboo cannot-leave sheet',
    (tester) async {
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
      runtime.leaveError = const SharedTransportException(
        statusCode: 409,
        code: 'settle_first',
      );
      bool? result;
      await show(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await SharedMembersSheet.show(
              context,
              runtime: runtime,
              contextId: group,
              groupName: 'Trip Group',
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave this split'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(runtime.left, isEmpty);
      expect(result, isNull);
      expect(find.text('Settle up before leaving'), findsOneWidget);
      expect(
        find.textContaining('You have unsettled balances in "Trip Group"'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Settle up'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Stay in split'),
        findsOneWidget,
      );

      // Tapping "Stay in split" dismisses the guard and keeps member on the sheet.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Stay in split'));
      await tester.pumpAndSettle();
      expect(find.text('Settle up before leaving'), findsNothing);
      expect(find.text('Leave this split'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping Settle up in cannot-leave sheet navigates to Settle up',
    (tester) async {
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
      runtime.leaveError = const SharedTransportException(
        statusCode: 409,
        code: 'settle_first',
      );
      await show(
        tester,
        SharedMembersSheet(
          runtime: runtime,
          contextId: group,
          groupName: 'Trip Group',
        ),
      );
      await tester.tap(find.text('Leave this split'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.text('Settle up before leaving'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Settle up'));
      await tester.pumpAndSettle();
      expect(find.text('Settle up before leaving'), findsNothing);
      expect(find.byType(SharedSettleSheet), findsOneWidget);
    },
  );
}
