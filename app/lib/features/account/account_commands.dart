import '../../app/providers.dart'
    show
        accessTokenProvider,
        accountNameApiProvider,
        authenticatedHttpClientProvider,
        cardFeedbackRepositoryProvider,
        cardRequestsApiProvider,
        consentsApiProvider,
        profileSnapshotWriterProvider,
        userCardsRepositoryProvider;
import '../../data/api_exception.dart';
import '../../data/local_first/command_outbox.dart';
import '../../data/support_api.dart';
import '../consent/consent_commands.dart';
import '../settings/feedback_support_screen.dart' show supportApiBaseUrl;
import 'account_local_first.dart';

/// WP-C11 handlers for [AccountCommand] kinds. Built from a provider `Ref` at
/// flush time so each one uses the current session's clients. `commandHandlersFor`
/// spreads the result with one line.
///
/// Every handler is safe to repeat: consents and tickets carry a client id, a
/// name / opt-in / read mark sets a state.
Map<String, CommandHandler> accountCommandHandlers(dynamic ref) {
  dynamic need(dynamic v) => v ?? (throw StateError('Sign in to send this'));
  return {
    AccountCommand.consentSubmit: (p) =>
        replayConsent(need(ref.read(consentsApiProvider)), p),
    AccountCommand.profileName: (p) async {
      final profile = await need(
        ref.read(accountNameApiProvider),
      ).save(p['name'] as String);
      try {
        await (ref.read(profileSnapshotWriterProvider)
            as Future<void> Function(Map<String, dynamic>))(profile);
      } catch (_) {}
    },
    AccountCommand.contributionsOptIn: (p) => need(
      ref.read(userCardsRepositoryProvider),
    ).setContributionsOptIn(p['optIn'] as bool),
    AccountCommand.supportTicket: (p) => SupportApi(
      apiBaseUrl: supportApiBaseUrl,
      accessToken: need(ref.read(accessTokenProvider) as String?),
      client: ref.read(authenticatedHttpClientProvider),
    ).submitTicket(
      kind: p['kind'] as String,
      message: p['message'] as String,
      diagnostics: (p['diagnostics'] as Map?)?.cast<String, dynamic>(),
      appVersion: p['appVersion'] as String?,
      id: p['id'] as String,
    ),
    AccountCommand.cardRequest: (p) => need(ref.read(cardRequestsApiProvider))
        .submit(
          issuerName: p['issuerName'] as String,
          productName: p['productName'] as String,
          networkGuess: p['networkGuess'] as String?,
        ),
    AccountCommand.dataErrorReport: (p) =>
        ref.read(cardFeedbackRepositoryProvider).reportWrongData(
          cardProductId: p['cardProductId'] as String,
          fieldPath: p['fieldPath'] as String,
          shownValue: p['shownValue'] as String?,
          claimedValue: p['claimedValue'] as String?,
          sourceUrl: p['sourceUrl'] as String?,
        ),
    AccountCommand.notificationRead: (p) => need(
      ref.read(userCardsRepositoryProvider),
    ).markNotificationsRead(id: p['id'] as String),
    AccountCommand.notificationReadAll: (p) =>
        need(ref.read(userCardsRepositoryProvider)).markNotificationsRead(),
  };
}
