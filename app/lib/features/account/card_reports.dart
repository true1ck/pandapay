import '../../app/providers.dart'
    show accessTokenProvider, cardFeedbackRepositoryProvider, cardRequestsApiProvider;
import 'account_local_first.dart';

/// WP-C11: card requests and "wrong data" reports are queued (with a unique
/// target each, so none replaces another) when the server cannot be reached.
/// Signed-out reports stay live-only: nothing would flush them. No server
/// dedupe id exists for these routes, so a reply lost after the server stored
/// one can produce a duplicate report on replay (harmless for triage).
Future<AccountWrite> requestNewCardLocalFirst(
  dynamic ref, {
  required String issuerName,
  required String productName,
  String? networkGuess,
}) {
  final id = newClientId();
  Future<void> live() => ref
      .read(cardFeedbackRepositoryProvider)
      .requestNewCard(
        issuerName: issuerName,
        productName: productName,
        networkGuess: networkGuess,
      ) as Future<void>;
  return _go(
    ref,
    AccountCommand.cardRequest,
    'card_request:$id',
    {
      'issuerName': issuerName,
      'productName': productName,
      'networkGuess': networkGuess,
    },
    live,
  );
}

/// Same, for the onboarding "request an unsupported card" form.
Future<AccountWrite> requestUnsupportedCardLocalFirst(
  dynamic ref, {
  required String issuerName,
  required String productName,
  String? networkGuess,
}) {
  final id = newClientId();
  return _go(
    ref,
    AccountCommand.cardRequest,
    'card_request:$id',
    {
      'issuerName': issuerName,
      'productName': productName,
      'networkGuess': networkGuess,
    },
    () => ref.read(cardRequestsApiProvider).submit(
      issuerName: issuerName,
      productName: productName,
      networkGuess: networkGuess,
    ) as Future<void>,
  );
}

Future<AccountWrite> reportWrongDataLocalFirst(
  dynamic ref, {
  required String cardProductId,
  required String fieldPath,
  String? shownValue,
  String? claimedValue,
  String? sourceUrl,
}) {
  final id = newClientId();
  return _go(
    ref,
    AccountCommand.dataErrorReport,
    'data_error:$id',
    {
      'cardProductId': cardProductId,
      'fieldPath': fieldPath,
      'shownValue': shownValue,
      'claimedValue': claimedValue,
      'sourceUrl': sourceUrl,
    },
    () => ref.read(cardFeedbackRepositoryProvider).reportWrongData(
      cardProductId: cardProductId,
      fieldPath: fieldPath,
      shownValue: shownValue,
      claimedValue: claimedValue,
      sourceUrl: sourceUrl,
    ) as Future<void>,
  );
}

Future<AccountWrite> _go(
  dynamic ref,
  String kind,
  String target,
  Map<String, Object?> payload,
  Future<void> Function() live,
) async {
  if (ref.read(accessTokenProvider) == null) {
    await live();
    return AccountWrite.sent;
  }
  return sendOrQueue(ref, kind: kind, target: target, payload: payload, live: live);
}
