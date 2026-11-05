import 'shared_invitations.dart';
import 'shared_transport.dart';

/// Turns a typed or contact-picker phone value into the form the server
/// accepts, or null when it cannot be a mobile number. The server re-validates;
/// this only avoids pointless lookups and removes common contact formatting
/// (leading 0, `91` without a plus, separators).
String? sharedCleanPhone(String raw) {
  var text = raw.trim();
  if (text.isEmpty || text.length > 40) return null;
  final plus = text.startsWith('+');
  var digits = text.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;
  if (!plus) {
    if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    } else if (digits.length == 12 && digits.startsWith('91')) {
      return '+$digits';
    }
    if (RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits)) return digits;
    return null;
  }
  return RegExp(r'^[1-9][0-9]{7,14}$').hasMatch(digits) ? '+$digits' : null;
}

/// Answer to "is this number on PandaPay?" for one number the user picked.
/// An unregistered number and a person who turned discovery off look the same.
final class SharedPhoneLookup {
  final bool found, self;
  final String? displayName, existingContextId;
  const SharedPhoneLookup({
    required this.found,
    required this.self,
    this.displayName,
    this.existingContextId,
  });
  static const none = SharedPhoneLookup(found: false, self: false);
  factory SharedPhoneLookup.fromJson(Map<String, Object?> value) {
    final found = value['found'], self = value['self'];
    final name = value['displayName'], context = value['existingContextId'];
    if (found is! bool ||
        self is! bool ||
        (name != null && (name is! String || name.length > 100)) ||
        (context != null && (context is! String || context.length != 36))) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedPhoneLookup(
      found: found,
      self: self,
      displayName: name as String?,
      existingContextId: context as String?,
    );
  }
}

/// One invitation waiting for the signed-in person, matched by their verified
/// phone number. Accepting only joins; it never accepts an expense or debt.
final class SharedInboxInvite {
  final String invitationId, contextId, contextKind, contextName;
  final String? inviterName;
  final DateTime? expiresAt;
  const SharedInboxInvite({
    required this.invitationId,
    required this.contextId,
    required this.contextKind,
    required this.contextName,
    this.inviterName,
    this.expiresAt,
  });
  bool get direct => contextKind == 'direct';
  factory SharedInboxInvite.fromJson(Map<String, Object?> value) {
    String text(String key, {int max = 200}) {
      final v = value[key];
      if (v is! String || v.isEmpty || v.length > max) {
        throw const SharedTransportException(code: 'invalid_response');
      }
      return v;
    }

    final inviter = value['inviterName'];
    if (inviter != null && (inviter is! String || inviter.length > 100)) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    final kind = text('contextKind', max: 16);
    if (kind != 'direct' && kind != 'group') {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedInboxInvite(
      invitationId: text('invitationId', max: 36),
      contextId: text('contextId', max: 36),
      contextKind: kind,
      contextName: text('contextName'),
      inviterName: inviter as String?,
      expiresAt: DateTime.tryParse(value['expiresAt'] as String? ?? ''),
    );
  }

  /// "Asha R. wants to split expenses with you" / "Asha R. added you to Goa".
  String get headline {
    final who = (inviterName == null || inviterName!.isEmpty)
        ? 'A PandaPay user'
        : inviterName!;
    return direct
        ? '$who wants to split expenses with you'
        : '$who added you to "$contextName"';
  }
}

/// Someone who joined through the owner's shared link and awaits approval.
final class SharedJoinRequest {
  final String invitationId, contextId, contextName;
  final String? memberName;
  const SharedJoinRequest({
    required this.invitationId,
    required this.contextId,
    required this.contextName,
    this.memberName,
  });
  factory SharedJoinRequest.fromJson(Map<String, Object?> value) {
    final id = value['invitationId'], ctx = value['contextId'];
    final name = value['contextName'], member = value['memberName'];
    if (id is! String ||
        id.length != 36 ||
        ctx is! String ||
        ctx.length != 36 ||
        name is! String ||
        name.isEmpty ||
        name.length > 200 ||
        (member != null && (member is! String || member.length > 200))) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedJoinRequest(
      invitationId: id,
      contextId: ctx,
      contextName: name,
      memberName: member as String?,
    );
  }
  String get headline =>
      '${(memberName == null || memberName!.isEmpty) ? 'Someone' : memberName!} '
      'wants to join "$contextName"';
}

/// Plain-language reason for a failed add/invite step. Never a raw code.
String sharedInviteIssueMessage(Object error) {
  final code = error is SharedTransportException ? error.code : null;
  return switch (code) {
    'invitation_self' => 'That is your own number.',
    'invitation_already_member' => 'That person is already in this split.',
    'invitation_duplicate' =>
      'Someone in this split is already invited with that number.',
    'invitation_declined_recently' =>
      'That person declined recently. Try again in a few days.',
    'invitation_rate_limited' || 'lookup_rate_limited' =>
      'Too many tries for now. Please wait a while and try again.',
    'invitation_phone_mismatch' =>
      'This invite was sent to a different mobile number than the one on your account.',
    'phone_not_verified' =>
      'Verify your mobile number in your profile to use phone invites.',
    'invitation_unavailable' =>
      'This invite has expired or is no longer available.',
    'network_unavailable' =>
      'No connection. It is saved on this phone; try again when online.',
    _ => 'Something went wrong. Please try again.',
  };
}

/// Result of saving a friend with an optional phone-bound invitation.
/// [link] is set when an invite was created; [inviteIssue] explains, in plain
/// words, why a number was given but no invite could be created yet. The friend
/// is saved either way.
final class SharedFriendAdded {
  final String contextId, memberId;
  final SharedInviteLink? link;
  final String? phone, inviteIssue;
  const SharedFriendAdded({
    required this.contextId,
    required this.memberId,
    this.link,
    this.phone,
    this.inviteIssue,
  });
}

/// The newest invitation for one unclaimed person, as the owner sees it.
/// [status]: open, awaiting_owner, joined, rejected, declined or expired.
final class SharedOwnerInvitation {
  final String invitationId, memberId, status;
  final bool phoneBound;
  final DateTime? createdAt;
  const SharedOwnerInvitation({
    required this.invitationId,
    required this.memberId,
    required this.status,
    required this.phoneBound,
    this.createdAt,
  });
  factory SharedOwnerInvitation.fromJson(Map<String, Object?> value) {
    final id = value['invitationId'], member = value['memberId'];
    final status = value['status'], bound = value['phoneBound'];
    const known = {
      'open',
      'awaiting_owner',
      'joined',
      'rejected',
      'declined',
      'expired',
    };
    if (id is! String ||
        id.length != 36 ||
        member is! String ||
        member.length != 36 ||
        status is! String ||
        !known.contains(status) ||
        bound is! bool) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedOwnerInvitation(
      invitationId: id,
      memberId: member,
      status: status,
      phoneBound: bound,
      createdAt: DateTime.tryParse(value['createdAt'] as String? ?? ''),
    );
  }

  /// Newest invitation per member from a newest-first list.
  static Map<String, SharedOwnerInvitation> latestByMember(
    Iterable<SharedOwnerInvitation> items,
  ) {
    final out = <String, SharedOwnerInvitation>{};
    for (final item in items) {
      final prior = out[item.memberId];
      if (prior == null ||
          (item.createdAt != null &&
              prior.createdAt != null &&
              item.createdAt!.isAfter(prior.createdAt!))) {
        out[item.memberId] = item;
      }
    }
    return out;
  }
}
