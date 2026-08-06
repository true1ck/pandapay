import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/auth_api.dart';

/// Task 1: sign-up collects BOTH email and phone, and the OTP is delivered to
/// the email. auth/'s POST /auth/verify-email-otp already accepts an optional
/// `phone_number` and links it onto the same users row (authRoutes.js), so the
/// only gap was the app never sending it.
void main() {
  group('AuthApi.verifyEmailOtp', () {
    test('sends phone_number when one is supplied', () async {
      late Map<String, dynamic> sentBody;
      final client = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      });
      final api = AuthApi(authBaseUrl: 'http://auth.test', client: client);

      await api.verifyEmailOtp(
        'a@b.com',
        '1234',
        'dev-1',
        phoneNumber: '+919876543210',
      );

      expect(sentBody['email'], 'a@b.com');
      expect(sentBody['code'], '1234');
      expect(sentBody['device_id'], 'dev-1');
      expect(sentBody['phone_number'], '+919876543210');
    });

    test('omits phone_number entirely when none is supplied', () async {
      late Map<String, dynamic> sentBody;
      final client = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      });
      final api = AuthApi(authBaseUrl: 'http://auth.test', client: client);

      await api.verifyEmailOtp('a@b.com', '1234', 'dev-1');

      // Sending an explicit null would trip auth/'s validatePhone() — the key
      // must be absent, not present-and-null.
      expect(sentBody.containsKey('phone_number'), isFalse);
    });

    test('omits phone_number when supplied as an empty/whitespace string',
        () async {
      late Map<String, dynamic> sentBody;
      final client = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
          200,
        );
      });
      final api = AuthApi(authBaseUrl: 'http://auth.test', client: client);

      await api.verifyEmailOtp('a@b.com', '1234', 'dev-1', phoneNumber: '   ');

      expect(sentBody.containsKey('phone_number'), isFalse);
    });

    test('propagates the returned tokens', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({'access_token': 'acc', 'refresh_token': 'ref'}),
            200,
          ));
      final api = AuthApi(authBaseUrl: 'http://auth.test', client: client);

      final tokens = await api.verifyEmailOtp('a@b.com', '1234', 'dev-1');

      expect(tokens.accessToken, 'acc');
      expect(tokens.refreshToken, 'ref');
    });
  });
}
