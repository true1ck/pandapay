import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/data/shared_invitations.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';

void main() {
  final token = List.filled(43, 'a').join();

  test('only well-formed split join links yield a token', () {
    expect(
      sharedInviteTokenFromUri(
        Uri.parse('https://pandapay.pandapath.live/split/join/$token'),
      ),
      token,
    );
    expect(
      sharedInviteTokenFromUri(Uri.parse('pandapay://split/join/$token')),
      token,
    );
    for (final bad in [
      'https://evil.example/split/join/$token',
      'http://pandapay.pandapath.live/split/join/$token',
      'https://pandapay.pandapath.live/i/$token', // product-access codes are separate
      'https://pandapay.pandapath.live/split/join/short',
      'https://pandapay.pandapath.live/split/join/$token/extra',
      'https://pandapay.pandapath.live/split/join/${token.replaceRange(0, 1, '!')}',
    ]) {
      expect(sharedInviteTokenFromUri(Uri.parse(bad)), isNull, reason: bad);
    }
    expect(sharedInviteTokenFromUri(null), isNull);
  });

  test('both link shapes map to the one in-app Join route', () {
    final expected = '/split/join/$token';
    expect(
      splitJoinLocationForUri(Uri.parse('pandapay://split/join/$token')),
      expected,
    );
    expect(
      splitJoinLocationForUri(
        Uri.parse('https://pandapay.pandapath.live/split/join/$token'),
      ),
      expected,
    );
    // Referral codes, assistant links and look-alike hosts never match.
    for (final other in [
      'pandapay://i/PANDA-ABC123',
      'pandapay://assistant/wallet',
      'https://evil.example/split/join/$token',
      'pandapay://split/join/short',
    ]) {
      expect(splitJoinLocationForUri(Uri.parse(other)), isNull, reason: other);
    }
  });

  test('invite message carries the link and no money', () {
    final text = sharedInviteMessage(
      groupName: 'Goa trip',
      personName: 'Rahul',
      url: sharedInviteUrl(token),
    );
    expect(text, contains('https://pandapay.pandapath.live/split/join/$token'));
    expect(text, isNot(contains('₹')));
  });

  test('preview rejects malformed server payloads', () {
    final ok = SharedInvitePreview.fromJson({
      'contextName': 'Goa trip',
      'memberName': 'Rahul',
      'status': 'open',
      'phoneBound': false,
    });
    expect(ok.contextName, 'Goa trip');
    expect(
      () => SharedInvitePreview.fromJson({
        'contextName': 'Goa trip',
        'memberName': 'Rahul',
        'status': 'open',
        'phoneBound': 'yes',
      }),
      throwsA(isA<SharedTransportException>()),
    );
  });

  test('friend invite does not call the person a group', () {
    final text = sharedInviteMessage(
      groupName: 'Rahul',
      personName: 'Rahul',
      url: 'https://pandapay.pandapath.live/split/join/x',
      direct: true,
    );
    expect(text, isNot(contains('added you to')));
    expect(text, contains('https://pandapay.pandapath.live/split/join/x'));
  });
}
