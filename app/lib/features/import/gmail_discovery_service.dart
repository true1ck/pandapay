import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/card_discovery_engine.dart';
import '../../data/user_cards_repository.dart' show CardDiscoveryResult, DiscoveredCard;

/// Provider for [GmailDiscoveryService].
final gmailDiscoveryServiceProvider = Provider<GmailDiscoveryService>((ref) {
  return GmailDiscoveryService();
});

/// On-device Gmail bank email scanner.
///
/// Performs targeted Gmail searches exclusively for known Indian bank
/// statement and transaction alerts, parses them locally via
/// [LocalCardDiscoveryEngine], and never transmits or persists any raw email
/// bodies or credentials to PandaPay servers.
class GmailDiscoveryService {
  final http.Client _client;

  GmailDiscoveryService({http.Client? client}) : _client = client ?? http.Client();

  /// Standard search query targeted strictly at bank statements and card alerts.
  static const String bankAlertsQuery =
      'from:(hdfcbank.net OR icicibank.com OR sbi.co.in OR axisbank.com OR amex.com OR onecard.co.in OR rblbank.com OR kotak.com OR indusind.com OR standardchartered.co.in OR citibank.co.in OR idfcfirstbank.com OR aubank.in OR hsbc.co.in) (statement OR "credit card" OR "card ending" OR "transaction alert" OR "spent on card")';

  /// Scans Gmail messages for credit card suggestions from [catalogue].
  ///
  /// When [accessToken] is provided, queries the Gmail REST API for the latest
  /// matching messages. When [rawSnippets] is provided (e.g. in tests or local
  /// mock), processes them directly.
  Future<CardDiscoveryResult> scanGmailForCards({
    required List<CardProduct> catalogue,
    String? accessToken,
    List<String>? rawSnippets,
    int maxResults = 30,
  }) async {
    final snippets = <String>[];

    if (rawSnippets != null && rawSnippets.isNotEmpty) {
      snippets.addAll(rawSnippets);
    } else if (accessToken != null && accessToken.isNotEmpty) {
      try {
        final listUri = Uri.parse(
          'https://gmail.googleapis.com/gmail/v1/users/me/messages',
        ).replace(queryParameters: {
          'q': bankAlertsQuery,
          'maxResults': '$maxResults',
        });

        final listRes = await _client.get(
          listUri,
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (listRes.statusCode == 200) {
          final listData = jsonDecode(listRes.body) as Map<String, dynamic>;
          final messages = (listData['messages'] as List?) ?? const [];

          for (final msg in messages.take(maxResults)) {
            final msgId = msg['id'] as String?;
            if (msgId == null) continue;

            final getUri = Uri.parse(
              'https://gmail.googleapis.com/gmail/v1/users/me/messages/$msgId',
            ).replace(queryParameters: {'format': 'metadata'});

            final getRes = await _client.get(
              getUri,
              headers: {'Authorization': 'Bearer $accessToken'},
            );

            if (getRes.statusCode == 200) {
              final msgData = jsonDecode(getRes.body) as Map<String, dynamic>;
              final snippet = msgData['snippet'] as String?;
              if (snippet != null && snippet.isNotEmpty) {
                snippets.add(snippet);
              }
            }
          }
        }
      } catch (_) {
        // Degrades gracefully — if network/API fails, returns empty result
      }
    }

    if (snippets.isEmpty) {
      return const CardDiscoveryResult(
        suggestions: [],
        emailsScanned: 0,
        smsScanned: 0,
      );
    }

    final localResult = LocalCardDiscoveryEngine.discoverAcrossMessages(
      smsBodies: snippets,
      catalogue: catalogue,
    );

    // Label the sources accurately as email
    final emailSuggestions = localResult.suggestions.map((s) {
      return DiscoveredCard(
        cardProductId: s.cardProductId,
        name: s.name,
        score: s.score,
        evidence: s.evidence,
        last4: s.last4,
        messageCount: s.messageCount,
        sources: const ['email'],
      );
    }).toList();

    return CardDiscoveryResult(
      suggestions: emailSuggestions,
      emailsScanned: snippets.length,
      smsScanned: 0,
    );
  }
}
