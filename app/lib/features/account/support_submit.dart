import '../../app/providers.dart' show authenticatedHttpClientProvider;
import '../../data/support_api.dart';
import '../settings/feedback_support_screen.dart' show supportApiBaseUrl;
import 'account_local_first.dart';

/// WP-C11: sends a support ticket now, or queues it with a client id when the
/// server cannot be reached ([AccountWrite.queued]; callers keep the draft out
/// of the way and say [savedOfflineMessage]). A signed-out ticket (no token)
/// cannot be queued (nothing would flush it), so it stays live-only.
Future<AccountWrite> submitTicketLocalFirst(
  dynamic ref, {
  required String? accessToken,
  required String kind,
  required String message,
  Map<String, dynamic>? diagnostics,
  String? appVersion,
}) async {
  final id = newClientId();
  final api = SupportApi(
    apiBaseUrl: supportApiBaseUrl,
    accessToken: accessToken,
    client: ref.read(authenticatedHttpClientProvider),
  );
  Future<void> live() => api.submitTicket(
    kind: kind,
    message: message,
    diagnostics: diagnostics,
    appVersion: appVersion,
    id: id,
  );
  if (accessToken == null) {
    await live();
    return AccountWrite.sent;
  }
  return sendOrQueue(
    ref,
    kind: AccountCommand.supportTicket,
    target: 'support:$id',
    payload: {
      'id': id,
      'kind': kind,
      'message': message,
      'diagnostics': diagnostics,
      'appVersion': appVersion,
    },
    live: live,
  );
}
