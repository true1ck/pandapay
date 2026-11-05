import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/data/shared_pending_phones.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/features/shared_expenses/data/shared_directory.dart';
import 'package:pandapay/features/shared_expenses/data/shared_invitations.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';

void main() {
  test('contact numbers are cleaned to what the server accepts', () {
    expect(sharedCleanPhone('98765 43210'), '9876543210');
    expect(sharedCleanPhone('098765-43210'), '9876543210');
    expect(sharedCleanPhone('+91 98765 43210'), '+919876543210');
    expect(sharedCleanPhone('919876543210'), '+919876543210');
    expect(sharedCleanPhone('+44 7700 900123'), '+447700900123');
    for (final bad in ['', '12345', '0000000000', 'abc', '+12', 'rahul@upi']) {
      expect(sharedCleanPhone(bad), isNull, reason: bad);
    }
  });

  test('lookup and inbox payloads are validated', () {
    final found = SharedPhoneLookup.fromJson({
      'found': true,
      'self': false,
      'displayName': 'Rahul S.',
      'existingContextId': null,
    });
    expect(found.found, isTrue);
    expect(found.displayName, 'Rahul S.');
    expect(
      () => SharedPhoneLookup.fromJson({'found': 'yes', 'self': false}),
      throwsA(isA<SharedTransportException>()),
    );
    final invite = SharedInboxInvite.fromJson({
      'invitationId': '11111111-1111-4111-8111-111111111111',
      'contextId': '22222222-2222-4222-8222-222222222222',
      'contextKind': 'group',
      'contextName': 'Goa',
      'inviterName': 'Asha R.',
      'expiresAt': '2026-11-12T00:00:00Z',
    });
    expect(invite.headline, 'Asha R. added you to "Goa"');
    expect(
      () => SharedInboxInvite.fromJson({'contextKind': 'other'}),
      throwsA(isA<SharedTransportException>()),
    );
  });

  test('failures read as plain sentences', () {
    expect(
      sharedInviteIssueMessage(
        const SharedTransportException(code: 'invitation_self'),
      ),
      'That is your own number.',
    );
    expect(sharedInviteIssueMessage(StateError('x')), contains('try again'));
  });

  test('owner invitation status keeps the newest per person', () {
    SharedOwnerInvitation inv(
      String id,
      String member,
      String status,
      String at,
    ) => SharedOwnerInvitation.fromJson({
      'invitationId': id,
      'memberId': member,
      'status': status,
      'phoneBound': true,
      'createdAt': at,
    });
    const m = '33333333-3333-4333-8333-333333333333';
    final latest = SharedOwnerInvitation.latestByMember([
      inv(
        '11111111-1111-4111-8111-111111111111',
        m,
        'declined',
        '2026-11-05T10:00:00Z',
      ),
      inv(
        '22222222-2222-4222-8222-222222222222',
        m,
        'open',
        '2026-11-05T11:00:00Z',
      ),
    ]);
    expect(latest[m]!.status, 'open');
    expect(
      () => SharedOwnerInvitation.fromJson({
        'invitationId': '11111111-1111-4111-8111-111111111111',
        'memberId': m,
        'status': 'mystery',
        'phoneBound': true,
      }),
      throwsA(isA<SharedTransportException>()),
    );
  });

  test('join requests and unnamed inviters read as plain sentences', () {
    final request = SharedJoinRequest.fromJson({
      'invitationId': '11111111-1111-4111-8111-111111111111',
      'contextId': '22222222-2222-4222-8222-222222222222',
      'contextName': 'Goa',
      'memberName': null,
    });
    expect(request.headline, 'Someone wants to join "Goa"');
    final invite = SharedInboxInvite.fromJson({
      'invitationId': '11111111-1111-4111-8111-111111111111',
      'contextId': '22222222-2222-4222-8222-222222222222',
      'contextKind': 'direct',
      'contextName': 'Rahul',
    });
    expect(invite.headline, 'A PandaPay user wants to split expenses with you');
    for (final code in [
      'invitation_already_member',
      'invitation_duplicate',
      'invitation_declined_recently',
      'lookup_rate_limited',
      'phone_not_verified',
      'invitation_unavailable',
      'invitation_phone_mismatch',
    ]) {
      expect(
        sharedInviteIssueMessage(SharedTransportException(code: code)),
        isNot(contains('_')),
        reason: code,
      );
    }
  });

  test('group link status and previews are validated', () {
    final status = SharedGroupLinkStatus.fromJson({
      'active': true,
      'expired': false,
      'expiresAt': '2026-12-01T00:00:00Z',
    });
    expect(status.active, isTrue);
    expect(status.expiresAt, isNotNull);
    expect(
      () => SharedGroupLinkStatus.fromJson({'active': 'yes'}),
      throwsA(isA<SharedTransportException>()),
    );
    final preview = SharedInvitePreview.fromJson({
      'kind': 'group_link',
      'contextName': 'Goa',
      'memberName': 'You',
      'status': 'open',
      'phoneBound': false,
    });
    expect(preview.isGroupLink, isTrue);
    expect(
      SharedInvitePreview.fromJson({
        'contextName': 'Goa',
        'memberName': 'Rahul',
        'status': 'open',
        'phoneBound': true,
      }).isGroupLink,
      isFalse,
    );
    expect(
      () => SharedInvitePreview.fromJson({
        'kind': 'other',
        'contextName': 'Goa',
        'memberName': 'Rahul',
        'status': 'open',
        'phoneBound': true,
      }),
      throwsA(isA<SharedTransportException>()),
    );
    for (final code in [
      'join_declined_recently',
      'join_requests_full',
      'membership_conflict',
      'context_member_limit',
    ]) {
      expect(
        sharedInviteIssueMessage(SharedTransportException(code: code)),
        isNot(contains('_')),
        reason: code,
      );
    }
  });

  test('a typed number survives until the invite is sent, per account', () async {
    SharedPreferences.setMockInitialValues({});
    final a = SharedPendingPhones('user:a'), b = SharedPendingPhones('user:b');
    await a.remember('m1', '+919876543210');
    expect(await a.phoneFor('m1'), '+919876543210');
    expect(await b.phoneFor('m1'), isNull);
    await a.forget('m1');
    expect(await a.phoneFor('m1'), isNull);
  });
}
