import 'shared_transport.dart';

/// Split invite links are `https://pandapay.app/split/join/<token>` (or the
/// `pandapay://split/join/<token>` fallback). The token is a 43-character
/// URL-safe secret. It grants only the right to ask to join: the server never
/// accepts debt, approves expenses or posts money from a link view.
final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

const sharedInviteHost = 'pandapay.app';

String sharedInviteUrl(String token) =>
    'https://$sharedInviteHost/split/join/$token';

/// Extracts a split-invite token from a validated URI, or null. Product-access
/// invite codes (`/i/CODE`) are a different feature and never match here.
String? sharedInviteTokenFromUri(Uri? uri) {
  if (uri == null) return null;
  final segments = uri.pathSegments;
  String? candidate;
  if (uri.scheme == 'https' &&
      uri.host.toLowerCase() == sharedInviteHost &&
      segments.length == 3 &&
      segments[0] == 'split' &&
      segments[1] == 'join') {
    candidate = segments[2];
  } else if (uri.scheme == 'pandapay' &&
      uri.host.toLowerCase() == 'split' &&
      segments.length == 2 &&
      segments[0] == 'join') {
    candidate = segments[1];
  }
  return candidate != null && _tokenPattern.hasMatch(candidate)
      ? candidate
      : null;
}

final class SharedInviteLink {
  final String invitationId, token, url;
  const SharedInviteLink({
    required this.invitationId,
    required this.token,
    required this.url,
  });
}

/// Neutral, WhatsApp/SMS-friendly text. It never includes an amount: an invite
/// is not a payment request and the recipient has not accepted anything.
String sharedInviteMessage({
  required String groupName,
  required String personName,
  required String url,
  bool direct = false,
}) => direct
    ? 'Hi $personName, I am using PandaPay to keep track of the expenses we '
          'share. Join me here: $url'
    : 'Hi $personName, I added you to "$groupName" on PandaPay to keep shared '
          'expenses in one place. Join here: $url';

final class SharedInvitePreview {
  final String contextName, memberName, status;
  final bool phoneBound;

  /// `group_link` for a group's shared link, otherwise `invitation`.
  final String kind;
  bool get isGroupLink => kind == 'group_link';
  const SharedInvitePreview({
    this.kind = 'invitation',
    required this.contextName,
    required this.memberName,
    required this.status,
    required this.phoneBound,
  });
  factory SharedInvitePreview.fromJson(Map<String, Object?> value) {
    String text(String key) {
      final v = value[key];
      if (v is! String || v.isEmpty || v.length > 200) {
        throw const SharedTransportException(code: 'invalid_response');
      }
      return v;
    }

    if (value['phoneBound'] is! bool) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    final kind = value['kind'];
    if (kind != null && kind != 'group_link' && kind != 'invitation') {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedInvitePreview(
      kind: kind as String? ?? 'invitation',
      contextName: text('contextName'),
      memberName: text('memberName'),
      status: text('status'),
      phoneBound: value['phoneBound'] as bool,
    );
  }
}
