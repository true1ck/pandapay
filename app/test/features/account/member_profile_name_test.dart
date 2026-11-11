import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/member_avatar_api.dart';
import 'package:pandapay/features/account/avatar_providers.dart';
import 'package:pandapay/features/account/member_avatar.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MemberAvatarApi apiWith(MockClient client) =>
    MemberAvatarApi(apiBaseUrl: 'https://api.test', accessToken: 'tok', client: client);

void main() {
  group('profileNameDiffers', () {
    test('a different name is worth showing', () {
      expect(profileNameDiffers('Mum', 'Asha Rao'), isTrue);
    });

    test('the same name is not, whatever the case or spacing', () {
      expect(profileNameDiffers('Asha Rao', 'asha  rao'), isFalse);
      expect(profileNameDiffers(' Asha Rao ', 'Asha Rao'), isFalse);
    });

    test('no profile name is nothing to show', () {
      expect(profileNameDiffers('Mum', null), isFalse);
      expect(profileNameDiffers('Mum', '   '), isFalse);
    });
  });

  group('MemberAvatarApi.profileName', () {
    test('asks the API for the co-member name and trims it', () async {
      late http.Request seen;
      final api = apiWith(MockClient((r) async {
        seen = r;
        return json({'profile_name': '  Asha Rao '});
      }));
      expect(await api.profileName('p-1'), 'Asha Rao');
      expect(seen.url.path, '/avatars/p-1/profile-name');
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('no name, an empty name and a 404 are all null', () async {
      expect(await apiWith(MockClient((_) async => json({'profile_name': null}))).profileName('p'), isNull);
      expect(await apiWith(MockClient((_) async => json({'profile_name': '  '}))).profileName('p'), isNull);
      expect(await apiWith(MockClient((_) async => json({'error': 'not_found'}, 404))).profileName('p'), isNull);
    });

    test('a server failure throws', () async {
      await expectLater(
        apiWith(MockClient((_) async => json({'error': 'avatar_unavailable'}, 503))).profileName('p'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('MemberProfileNameLine', () {
    Future<List<http.Request>> pump(
      WidgetTester tester, {
      required String savedName,
      required http.Response Function(http.Request) reply,
      String profileId = 'p-1',
    }) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarApiProvider.overrideWithValue(
              apiWith(MockClient((r) async {
                requests.add(r);
                return reply(r);
              })),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: MemberProfileNameLine(profileId: profileId, savedName: savedName)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return requests;
    }

    testWidgets('shows the real name under a different saved name', (tester) async {
      await pump(tester, savedName: 'Mum', reply: (_) => json({'profile_name': 'Asha Rao'}));
      expect(find.text('PandaPay name: Asha Rao'), findsOneWidget);
    });

    testWidgets('shows nothing when it is the same name', (tester) async {
      await pump(tester, savedName: 'asha rao', reply: (_) => json({'profile_name': 'Asha Rao'}));
      expect(find.textContaining('PandaPay name'), findsNothing);
    });

    testWidgets('shows nothing when there is no name, a 404 or a failure', (tester) async {
      for (final reply in <http.Response Function(http.Request)>[
        (_) => json({'profile_name': null}),
        (_) => json({'error': 'not_found'}, 404),
        (_) => json({'error': 'avatar_unavailable'}, 503),
      ]) {
        await pump(tester, savedName: 'Mum', reply: reply, profileId: 'p-${reply.hashCode}');
        expect(find.textContaining('PandaPay name'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a person without a profile id draws nothing and asks nothing', (tester) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberAvatarApiProvider.overrideWithValue(
              apiWith(MockClient((r) async {
                requests.add(r);
                return json({'profile_name': 'X'});
              })),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: MemberProfileNameLine(profileId: null, savedName: 'Mum')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('PandaPay name'), findsNothing);
      expect(requests, isEmpty);
    });

    testWidgets('without a provider scope it draws nothing instead of failing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MemberProfileNameLine(profileId: 'p-1', savedName: 'Mum')),
        ),
      );
      expect(find.textContaining('PandaPay name'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  test('the name is requested once per person and cached for the session', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        memberAvatarApiProvider.overrideWithValue(
          apiWith(MockClient((_) async {
            calls++;
            return json({'profile_name': 'Asha Rao'});
          })),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(memberProfileNameProvider('p-1').future), 'Asha Rao');
    expect(await container.read(memberProfileNameProvider('p-1').future), 'Asha Rao');
    expect(calls, 1);
    await container.read(memberProfileNameProvider('p-2').future);
    expect(calls, 2);
  });
}
