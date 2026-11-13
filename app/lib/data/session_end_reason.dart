import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why the signed-in session ended (WP-C3, L-01, decision D10).
///
/// Two very different things make the account namespace flip to `signed-out`:
///
///  * [userSignedOut]: the person chose Sign out. The whole database file and
///    its keys are wiped right after, so clearing account data first is
///    harmless and stays exactly as it was.
///  * [sessionRejected]: the auth server refused the refresh token (revoked,
///    or idle for 90 days). The credentials are unusable and are cleared, but
///    the phone may hold work the server has never seen (queued edits, bill
///    assignments, manual balances, SMS observations). That data must survive
///    so the same person can sign in again and carry on.
///
/// Anything that observes the `signed-out` transition and is about to delete
/// or reset account data asks [SessionEndReasonHolder.mayWipeAccountData].
/// When nothing says the person signed out, the answer is no: keeping data is
/// the safe default, and a real sign-out always marks itself first.
enum SessionEndReason { userSignedOut, sessionRejected }

class SessionEndReasonHolder {
  SessionEndReason? _reason;

  SessionEndReason? get reason => _reason;

  /// The auth server rejected the refresh token. Never replaces an explicit
  /// sign-out that is already under way (the sign-out's own server call can
  /// itself be answered with a 401).
  void markSessionRejected() {
    if (_reason != SessionEndReason.userSignedOut) {
      _reason = SessionEndReason.sessionRejected;
    }
  }

  /// The person chose Sign out. Always wins over [markSessionRejected].
  void markUserSignedOut() => _reason = SessionEndReason.userSignedOut;

  /// True only for an explicit sign-out. Unknown reasons keep the data.
  bool get mayWipeAccountData => _reason == SessionEndReason.userSignedOut;

  /// Forgets the reason. Called when a session starts again.
  void clear() => _reason = null;
}

/// One holder per app process. It is plain state on purpose (not a
/// `StateProvider`): writing it must never rebuild anything.
final sessionEndReasonProvider = Provider<SessionEndReasonHolder>(
  (ref) => SessionEndReasonHolder(),
);
