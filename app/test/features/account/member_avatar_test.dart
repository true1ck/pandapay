import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/account_name_api.dart';
import 'package:pandapay/data/avatar_api.dart';
import 'package:pandapay/data/member_avatar_api.dart';
import 'package:pandapay/data/phone_api.dart';
import 'package:pandapay/features/account/avatar_providers.dart';
import 'package:pandapay/features/account/edit_profile_screen.dart';
import 'package:pandapay/features/account/member_avatar.dart';
import 'package:pandapay/features/account/user_avatar.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Uint8List png() {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return Uint8List.fromList(img.encodePng(image));
}

MemberAvatarApi memberApi(MockClient client) =>
    MemberAvatarApi(apiBaseUrl: 'https://api.test', accessToken: 'tok', client: client);

void main() {
  group('AvatarInfo / AvatarApi sharing', () {
    test('parses share_photo and defaults to off', () {
      expect(
        AvatarInfo.fromJson({'preset': 'sun', 'has_photo': true, 'share_photo': true, 'version': 2}).sharePhoto,
        isTrue,
      );
      expect(AvatarInfo.fromJson({'preset': null, 'has_photo': false, 'version': 1}).sharePhoto, isFalse);
    });

    test('setPhotoSharing PUTs the flag and returns the info', () async {
      late http.Request seen;
      final api = AvatarApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'tok',
        client: MockClient((r) async {
          seen = r;
          return json({'preset': null, 'has_photo': true, 'share_photo': true, 'version': 3});
        }),
      );
      final info = await api.setPhotoSharing(true);
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/users/me/avatar/sharing');
      expect(jsonDecode(seen.body), {'share_photo': true});
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(info.sharePhoto, isTrue);
    });
  });

  group('MemberAvatarApi', () {
    test('200 returns info, 404 returns null, 503 throws', () async {
      final ok = memberApi(
        MockClient((r) async {
          expect(r.url.path, '/avatars/p1');
          expect(r.headers['Authorization'], 'Bearer tok');
          return json({'preset': 'panda', 'has_photo': false, 'version': 4});
        }),
      );
      final info = await ok.info('p1');
      expect((info!.preset, info.hasPhoto, info.version), ('panda', false, 4));

      expect(await memberApi(MockClient((_) async => json({'error': 'not_found'}, 404))).info('p1'), isNull);
      await expectLater(
        memberApi(MockClient((_) async => json({'error': 'avatar_unavailable'}, 503))).info('p1'),
        throwsA(isA<Exception>()),
      );
    });

    test('photo returns bytes, or null on 404', () async {
      final ok = memberApi(
        MockClient((r) async {
          expect(r.url.path, '/avatars/p1/photo');
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      expect(await ok.photo('p1'), [1, 2, 3]);
      expect(await memberApi(MockClient((_) async => json({'error': 'not_found'}, 404))).photo('p1'), isNull);
    });

    test('never runs more than four requests at once and finishes them all', () async {
      var inFlight = 0, peak = 0;
      final api = memberApi(
        MockClient((r) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return json({'preset': 'sun', 'has_photo': false, 'version': 1});
        }),
      );
      final results = await Future.wait([for (var i = 0; i < 20; i++) api.info('p$i')]);
      expect(results.whereType<AvatarInfo>().length, 20);
      expect(peak, lessThanOrEqualTo(4));
    });
  });

  group('memberAvatarProvider', () {
    test('one info and one photo request per profile, however often it is read', () async {
      final seen = <String>[];
      final api = memberApi(
        MockClient((r) async {
          seen.add(r.url.path);
          if (r.url.path.endsWith('/photo')) return http.Response.bytes([9, 9], 200);
          return json({'preset': 'sun', 'has_photo': r.url.path == '/avatars/a', 'version': 1});
        }),
      );
      final container = ProviderContainer(overrides: [memberAvatarApiProvider.overrideWithValue(api)]);
      addTearDown(container.dispose);
      final a1 = await container.read(memberAvatarProvider('a').future);
      final a2 = await container.read(memberAvatarProvider('a').future);
      final b = await container.read(memberAvatarProvider('b').future);
      expect(a1!.photo, [9, 9]);
      expect(identical(a1, a2), isTrue);
      expect(b!.photo, isNull);
      expect(seen, ['/avatars/a', '/avatars/a/photo', '/avatars/b']);
    });

    test('failure and 404 resolve to null, and a failed photo keeps the preset', () async {
      final failing = ProviderContainer(
        overrides: [memberAvatarApiProvider.overrideWithValue(memberApi(MockClient((_) async => json({}, 503))))],
      );
      addTearDown(failing.dispose);
      expect(await failing.read(memberAvatarProvider('x').future), isNull);

      final missing = ProviderContainer(
        overrides: [memberAvatarApiProvider.overrideWithValue(memberApi(MockClient((_) async => json({}, 404))))],
      );
      addTearDown(missing.dispose);
      expect(await missing.read(memberAvatarProvider('x').future), isNull);

      final photoFails = ProviderContainer(
        overrides: [
          memberAvatarApiProvider.overrideWithValue(
            memberApi(
              MockClient((r) async {
                if (r.url.path.endsWith('/photo')) return json({}, 503);
                return json({'preset': 'wave', 'has_photo': true, 'version': 1});
              }),
            ),
          ),
        ],
      );
      addTearDown(photoFails.dispose);
      final state = await photoFails.read(memberAvatarProvider('x').future);
      expect((state!.preset, state.photo), ('wave', null));
    });

    test('signed out resolves to null without a request', () async {
      final container = ProviderContainer(overrides: [memberAvatarApiProvider.overrideWithValue(null)]);
      addTearDown(container.dispose);
      expect(await container.read(memberAvatarProvider('x').future), isNull);
    });
  });

  group('MemberAvatar', () {
    Future<void> pump(WidgetTester tester, Widget avatar, List<Override> overrides) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(home: Scaffold(body: Center(child: avatar))),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the preset the server returns', (tester) async {
      await pump(tester, const MemberAvatar(profileId: 'p1', name: 'Ravi'), [
        memberAvatarProvider('p1').overrideWith((ref) async => const AvatarState(preset: 'bamboo')),
      ]);
      expect(find.byIcon(Icons.eco_rounded), findsOneWidget);
      expect(find.text('R'), findsNothing);
    });

    testWidgets('shows the photo when one is shared', (tester) async {
      await pump(tester, const MemberAvatar(profileId: 'p1', name: 'Ravi'), [
        memberAvatarProvider('p1').overrideWith((ref) async => AvatarState(preset: 'bamboo', photo: png())),
      ]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.eco_rounded), findsNothing);
    });

    testWidgets('shows the initial when there is nothing, at the same size', (tester) async {
      await pump(tester, const MemberAvatar(profileId: 'p1', name: 'ravi', size: 40), [
        memberAvatarProvider('p1').overrideWith((ref) async => null),
      ]);
      expect(find.text('R'), findsOneWidget);
      expect(tester.getSize(find.byType(UserAvatar)), const Size(40, 40));
    });

    testWidgets('no profileId (invited) shows the initial and never asks the server', (tester) async {
      var asked = 0;
      await pump(tester, const MemberAvatar(profileId: null, name: 'Meera'), [
        memberAvatarApiProvider.overrideWithValue(
          memberApi(
            MockClient((_) async {
              asked++;
              return json({});
            }),
          ),
        ),
      ]);
      expect(find.text('M'), findsOneWidget);
      expect(asked, 0);
    });

    testWidgets('self reuses the signed-in avatar, not the member API', (tester) async {
      await pump(tester, const MemberAvatar(profileId: 'me', name: 'You', self: true), [
        avatarProvider.overrideWith((ref) async => const AvatarState(preset: 'sun')),
      ]);
      expect(find.byIcon(Icons.wb_sunny_rounded), findsOneWidget);
    });

    testWidgets('works without any provider scope', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MemberAvatar(profileId: 'p1', name: 'Ravi'))),
      );
      expect(find.text('R'), findsOneWidget);
    });
  });

  group('Edit profile sharing toggle', () {
    Future<List<http.Request>> mount(
      WidgetTester tester, {
      required AvatarState? state,
      http.Response Function(http.Request)? reply,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <http.Request>[];
      final api = AvatarApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'tok',
        client: MockClient((request) async {
          requests.add(request);
          return reply != null
              ? reply(request)
              : json({'preset': null, 'has_photo': true, 'share_photo': true, 'version': 2});
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileProvider.overrideWith(
              (ref) async => {'id': 'p1', 'display_name': 'Asha', 'email': 'a@example.com'},
            ),
            phoneStatusProvider.overrideWith(
              (ref) async => const PhoneStatus(
                claimed: true,
                verified: false,
                required: true,
                needsPhone: false,
                phoneHint: '+91 3210',
              ),
            ),
            accountNameApiProvider.overrideWithValue(
              AccountNameApi(apiBaseUrl: 'https://api.test', authBaseUrl: 'https://auth.test', accessToken: 'tok'),
            ),
            avatarApiProvider.overrideWithValue(api),
            avatarProvider.overrideWith((ref) async => state),
          ],
          child: const MaterialApp(home: EditProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return requests;
    }

    testWidgets('hidden when there is no photo', (tester) async {
      await mount(tester, state: const AvatarState(preset: 'sun'));
      expect(find.byKey(const Key('edit-share-photo')), findsNothing);
    });

    testWidgets('shown off by default with a photo, and toggling calls the API', (tester) async {
      final requests = await mount(tester, state: AvatarState(photo: png()));
      final toggle = find.byKey(const Key('edit-share-photo'));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.text('Show my photo to people in Split'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(requests.map((r) => '${r.method} ${r.url.path}'), ['PUT /users/me/avatar/sharing']);
      expect(jsonDecode(requests.single.body), {'share_photo': true});
    });

    testWidgets('reflects the saved value', (tester) async {
      await mount(tester, state: AvatarState(photo: png(), sharePhoto: true));
      expect(tester.widget<Switch>(find.byKey(const Key('edit-share-photo'))).value, isTrue);
    });

    testWidgets('a failure reverts the switch and shows a message', (tester) async {
      await mount(
        tester,
        state: AvatarState(photo: png()),
        reply: (_) => json({'error': 'x', 'message': 'Could not save that.'}, 500),
      );
      await tester.tap(find.byKey(const Key('edit-share-photo')));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byKey(const Key('edit-share-photo'))).value, isFalse);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });
}
