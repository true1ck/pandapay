import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/account_name_api.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/avatar_api.dart';
import 'package:pandapay/data/phone_api.dart';
import 'package:pandapay/features/account/avatar_photo_processor.dart';
import 'package:pandapay/features/account/avatar_presets.dart';
import 'package:pandapay/features/account/avatar_providers.dart';
import 'package:pandapay/features/account/edit_profile_screen.dart';
import 'package:pandapay/features/account/user_avatar.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Uint8List png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return Uint8List.fromList(img.encodePng(image));
}

class _FakePicker implements AvatarPhotoPicker {
  final Uint8List? bytes;
  final picked = <AvatarPhotoSource>[];
  _FakePicker(this.bytes);
  @override
  Future<Uint8List?> pick(AvatarPhotoSource source) async {
    picked.add(source);
    return bytes;
  }
}

void main() {
  group('photo preparation', () {
    test('a big landscape photo becomes a small square JPEG', () async {
      final out = await prepareAvatarPhoto(png(2000, 1000));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, avatarPhotoSide);
      expect(decoded.height, avatarPhotoSide);
      expect(out.length, lessThan(100 * 1024), reason: 'the server rejects anything above 200 KB');
      expect(out.sublist(0, 3), [0xff, 0xd8, 0xff]);
    });

    test('a small photo is cropped square but not enlarged', () async {
      final out = await prepareAvatarPhoto(png(200, 100));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 100);
      expect(decoded.height, 100);
    });

    test('something that is not an image is refused with a plain message', () async {
      await expectLater(
        prepareAvatarPhoto(Uint8List.fromList(List.filled(300, 65))),
        throwsA(isA<AvatarPhotoException>()),
      );
    });

    test('a tiny image is refused', () async {
      await expectLater(prepareAvatarPhoto(png(10, 10)), throwsA(isA<AvatarPhotoException>()));
    });
  });

  group('presets', () {
    test('every id is on the server list and ids are unique', () {
      const serverList = [
        'panda', 'bamboo', 'sun', 'wave', 'berry', 'forest', 'dusk', 'night',
        'cool', 'coin', 'explorer', 'snack', 'verified', 'party',
        'phone', 'sleepy', 'hero', 'shopper', 'secure', 'music',
      ];
      final all = [...avatarPresets, ...legacyAvatarPresets].map((p) => p.id).toList();
      expect(all.toSet().length, all.length);
      expect(serverList.toSet(), all.toSet(), reason: 'the app and auth/src/services/userAvatar.js must agree');
      expect(avatarPresetFor('panda'), isNotNull);
      expect(avatarPresetFor('nope'), isNull);
      expect(avatarPresetFor(null), isNull);
    });

    test('every panda illustration the picker offers is a real bundled file', () {
      expect(avatarPresets.length, 12);
      for (final p in avatarPresets) {
        expect(p.asset, 'assets/avatars/${p.id}.webp');
        expect(File('${p.asset}').existsSync(), isTrue, reason: '${p.asset} is missing');
      }
      for (final p in legacyAvatarPresets.where((p) => p.asset != null)) {
        expect(File(p.asset!).existsSync(), isTrue, reason: '${p.asset} is missing');
      }
    });

    test('the picker offers the pandas, not the old symbols', () {
      expect(avatarPresets.every((p) => p.asset != null), isTrue);
      expect(avatarPresets.map((p) => p.id), isNot(contains('bamboo')));
      expect(avatarPresetFor('bamboo'), isNotNull, reason: 'someone who already picked it still sees it');
    });
  });

  group('UserAvatar', () {
    Future<void> pump(WidgetTester tester, UserAvatar avatar) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: avatar))));

    testWidgets('no preset and no photo shows the initial letter', (tester) async {
      await pump(tester, const UserAvatar(name: 'asha'));
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('a panda avatar shows its illustration, not the letter', (tester) async {
      await pump(tester, const UserAvatar(name: 'asha', preset: 'coin'));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).imageProvider, isA<AssetImage>());
      expect(find.text('A'), findsNothing);
    });

    testWidgets('the old paw avatar now shows a panda', (tester) async {
      await pump(tester, const UserAvatar(name: 'asha', preset: 'panda'));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.pets_rounded), findsNothing);
    });

    testWidgets('an older symbol avatar still shows its icon, not the letter', (tester) async {
      await pump(tester, const UserAvatar(name: 'asha', preset: 'bamboo'));
      expect(find.byIcon(Icons.eco_rounded), findsOneWidget);
      expect(find.text('A'), findsNothing);
    });

    testWidgets('a photo wins over a preset', (tester) async {
      await pump(tester, UserAvatar(name: 'asha', preset: 'bamboo', photo: png(64, 64)));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.eco_rounded), findsNothing);
    });

    testWidgets('a corrupt photo falls back to the letter instead of breaking', (tester) async {
      await pump(tester, UserAvatar(name: 'asha', photo: Uint8List.fromList([1, 2, 3, 4])));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('an empty name still draws something', (tester) async {
      await pump(tester, const UserAvatar(name: '  '));
      expect(find.text('?'), findsOneWidget);
    });
  });

  group('AvatarApi', () {
    AvatarApi api(MockClient client) =>
        AvatarApi(authBaseUrl: 'https://auth.test', accessToken: 'tok', client: client);

    test('sends the preset and the photo with the right headers, and reads them back', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        if (request.url.path.endsWith('/photo') && request.method == 'GET') {
          return http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/jpeg'});
        }
        return json({'preset': 'panda', 'has_photo': true, 'version': 7});
      });
      final a = api(client);
      final info = await a.setPreset('panda');
      expect((info.preset, info.hasPhoto, info.version), ('panda', true, 7));
      expect(jsonDecode(seen.last.body), {'preset': 'panda'});
      await a.uploadPhoto(Uint8List.fromList([0xff, 0xd8, 0xff, 9]));
      expect(seen.last.headers['content-type'], startsWith('image/jpeg'));
      expect(seen.last.headers['Authorization'], 'Bearer tok');
      expect(await a.fetchPhoto(), [1, 2, 3]);
    });

    test('no photo is null, not an error', () async {
      final a = api(MockClient((_) async => json({'error': 'no_photo'}, 404)));
      expect(await a.fetchPhoto(), isNull);
    });

    test('a refusal carries the server wording', () async {
      final a = api(MockClient((_) async => json({'error': 'photo_too_large', 'message': 'Too big.'}, 413)));
      await expectLater(
        a.uploadPhoto(Uint8List(10)),
        throwsA(isA<ApiException>().having((e) => e.userMessage, 'userMessage', 'Too big.')),
      );
    });
  });

  group('Edit profile avatar', () {
    Future<List<http.Request>> mount(
      WidgetTester tester, {
      required AvatarState? state,
      required AvatarPhotoPicker picker,
      http.Response Function(http.Request)? reply,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <http.Request>[];
      final avatarApi = AvatarApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'tok',
        client: MockClient((request) async {
          requests.add(request);
          return reply != null ? reply(request) : json({'preset': null, 'has_photo': false, 'version': 1});
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileProvider.overrideWith((ref) async => {'id': 'p1', 'display_name': 'Asha', 'email': 'a@example.com'}),
            phoneStatusProvider.overrideWith(
              (ref) async => const PhoneStatus(claimed: true, verified: false, required: true, needsPhone: false, phoneHint: '+91 •••• 3210'),
            ),
            accountNameApiProvider.overrideWithValue(
              AccountNameApi(apiBaseUrl: 'https://api.test', authBaseUrl: 'https://auth.test', accessToken: 'tok'),
            ),
            avatarApiProvider.overrideWithValue(avatarApi),
            avatarProvider.overrideWith((ref) async => state),
            avatarPhotoPickerProvider.overrideWithValue(picker),
          ],
          child: const MaterialApp(home: EditProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return requests;
    }

    testWidgets('the avatar shows the saved preset, and tapping opens the menu', (tester) async {
      await mount(tester, state: const AvatarState(preset: 'sun'), picker: _FakePicker(null));
      expect(find.byIcon(Icons.wb_sunny_rounded), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      expect(find.text('Choose your avatar'), findsOneWidget);
      for (final preset in avatarPresets) {
        expect(find.byKey(Key('avatar-preset-${preset.id}')), findsOneWidget);
      }
      expect(find.byKey(const Key('avatar-gallery')), findsOneWidget);
      expect(find.byKey(const Key('avatar-camera')), findsOneWidget);
      expect(find.byKey(const Key('avatar-remove-photo')), findsNothing, reason: 'no photo to remove');
      expect(find.byKey(const Key('avatar-use-initial')), findsOneWidget);
    });

    testWidgets('picking a preset saves just that id', (tester) async {
      final requests = await mount(tester, state: null, picker: _FakePicker(null));
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      // The last avatar is off the right edge of the carousel until it is scrolled to.
      final last = find.byKey(Key('avatar-preset-${avatarPresets.last.id}'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(requests.map((r) => '${r.method} ${r.url.path}'), ['PUT /users/me/avatar/preset']);
      expect(jsonDecode(requests.single.body), {'preset': avatarPresets.last.id});
      expect(find.text('Avatar updated'), findsOneWidget);
    });

    testWidgets('choosing a photo prepares a square JPEG and uploads it', (tester) async {
      final picker = _FakePicker(png(900, 600));
      final requests = await mount(tester, state: null, picker: picker);
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-gallery')));
      await tester.pump(const Duration(milliseconds: 400));
      // The resize runs on a real isolate; give it time outside the fake clock.
      // (No pumpAndSettle while it runs: the busy spinner never settles.)
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(picker.picked, [AvatarPhotoSource.gallery]);
      final upload = requests.singleWhere((r) => r.url.path == '/users/me/avatar/photo');
      expect(upload.method, 'PUT');
      expect(upload.headers['content-type'], startsWith('image/jpeg'));
      final decoded = img.decodeJpg(upload.bodyBytes)!;
      expect((decoded.width, decoded.height), (avatarPhotoSide, avatarPhotoSide));
    });

    testWidgets('backing out of the picker changes nothing', (tester) async {
      final requests = await mount(tester, state: null, picker: _FakePicker(null));
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-camera')));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('Avatar updated'), findsNothing);
    });

    testWidgets('with a photo: Remove my photo is offered and deletes it', (tester) async {
      final requests = await mount(
        tester,
        state: AvatarState(preset: null, photo: png(64, 64)),
        picker: _FakePicker(null),
      );
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-remove-photo')));
      await tester.pumpAndSettle();
      expect(requests.map((r) => '${r.method} ${r.url.path}'), ['DELETE /users/me/avatar/photo']);
    });

    testWidgets('picking a preset while a photo exists removes the photo first', (tester) async {
      final requests = await mount(
        tester,
        state: AvatarState(preset: null, photo: png(64, 64)),
        picker: _FakePicker(null),
      );
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-preset-cool')));
      await tester.pumpAndSettle();
      expect(requests.map((r) => '${r.method} ${r.url.path}'), [
        'DELETE /users/me/avatar/photo',
        'PUT /users/me/avatar/preset',
      ]);
    });

    testWidgets('a server refusal shows its message and keeps the screen usable', (tester) async {
      await mount(
        tester,
        state: null,
        picker: _FakePicker(null),
        reply: (_) => json({'error': 'preset_invalid', 'message': 'Choose one of the avatars on the list.'}, 400),
      );
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-preset-cool')));
      await tester.pumpAndSettle();
      expect(find.text('Choose one of the avatars on the list.'), findsOneWidget);
      expect(find.byKey(const Key('edit-name-field')), findsOneWidget);
    });

    testWidgets('a file that is not an image is explained, nothing is uploaded', (tester) async {
      final requests = await mount(
        tester,
        state: null,
        picker: _FakePicker(Uint8List.fromList(List.filled(300, 65))),
      );
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('avatar-gallery')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.textContaining('isn’t a photo we can use'), findsOneWidget);
    });
  });
}
