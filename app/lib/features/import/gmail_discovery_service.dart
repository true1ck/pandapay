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

/// Raised when the Gmail REST API rejects a request for a reason the user (or
/// the app owner) needs to act on — an expired token, the Gmail API not being
/// enabled for the OAuth client, or the `gmail.readonly` scope not being
/// granted. Distinct from "scan completed, found nothing".
class GmailScanException implements Exception {
  final String userMessage;
  final String debugMessage;

  GmailScanException(this.debugMessage, {required this.userMessage});

  @override
  String toString() => debugMessage;
}

/// On-device Gmail bank email scanner.
///
/// Performs targeted Gmail searches exclusively for known Indian bank
/// statement and transaction alerts, downloads the matching message bodies,
/// parses them locally via [LocalCardDiscoveryEngine], and never transmits or
/// persists any raw email bodies or OAuth tokens to PandaPay servers. The
/// access token is used only for direct device-to-Google API calls.
class GmailDiscoveryService {
  final http.Client _client;

  GmailDiscoveryService({http.Client? client}) : _client = client ?? http.Client();

  /// Bank sender domains we search. Kept in one place so the query and any
  /// future allow-listing stay in sync.
  static const List<String> _bankDomains = [
    'hdfcbank.net',
    'hdfcbank.com',
    'icicibank.com',
    'sbi.co.in',
    'sbicard.com',
    'axisbank.com',
    'amex.com',
    'americanexpress.com',
    'onecard.co.in',
    'rblbank.com',
    'kotak.com',
    'indusind.com',
    'standardchartered.co.in',
    'sc.com',
    'citibank.co.in',
    'idfcfirstbank.com',
    'aubank.in',
    'hsbc.co.in',
    'yesbank.in',
    'federalbank.co.in',
    'bobcards.com',
  ];

  /// Search query targeted strictly at bank statements and card alerts within
  /// the last ~15 months, so a single billing cycle is always covered.
  static String get bankAlertsQuery {
    final from = _bankDomains.map((d) => 'from:$d').join(' OR ');
    return '($from) '
        '(statement OR "credit card" OR "card ending" OR "card no" OR '
        '"transaction alert" OR "spent on" OR "has been debited" OR '
        '"available limit" OR "total amount due" OR "minimum amount due") '
        'newer_than:15m';
  }

  /// Scans Gmail messages for credit card suggestions from [catalogue].
  ///
  /// When [accessToken] is provided, queries the Gmail REST API for the latest
  /// matching messages and downloads their full bodies. When [rawSnippets] is
  /// provided (tests / local mock), processes those strings directly.
  ///
  /// Throws [GmailScanException] when the API rejects a request for an
  /// actionable reason (auth / scope / API-not-enabled). Transient network
  /// errors degrade to an empty result.
  Future<CardDiscoveryResult> scanGmailForCards({
    required List<CardProduct> catalogue,
    String? accessToken,
    List<String>? rawSnippets,
    int maxResults = 50,
  }) async {
    final documents = <String>[];

    if (rawSnippets != null && rawSnippets.isNotEmpty) {
      documents.addAll(rawSnippets);
    } else if (accessToken != null && accessToken.isNotEmpty) {
      documents.addAll(await _fetchBankEmailTexts(accessToken, maxResults));
    }

    if (documents.isEmpty) {
      return const CardDiscoveryResult(
        suggestions: [],
        emailsScanned: 0,
        smsScanned: 0,
      );
    }

    final localResult = LocalCardDiscoveryEngine.discoverAcrossMessages(
      smsBodies: documents,
      catalogue: catalogue,
      // Email is its own discovery channel — it must widen SMS coverage, not
      // inherit SMS's strict promo/last-4/confident-only gating.
      isSms: false,
    );

    // Re-label the sources as email (the engine tags everything 'sms').
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
      emailsScanned: documents.length,
      smsScanned: 0,
    );
  }

  /// Lists matching message IDs, then downloads each full message and returns
  /// one plain-text document per email (subject + decoded body).
  Future<List<String>> _fetchBankEmailTexts(String accessToken, int maxResults) async {
    final headers = {'Authorization': 'Bearer $accessToken'};

    final listUri = Uri.parse(
      'https://gmail.googleapis.com/gmail/v1/users/me/messages',
    ).replace(queryParameters: {
      'q': bankAlertsQuery,
      'maxResults': '$maxResults',
    });

    final http.Response listRes;
    try {
      listRes = await _client.get(listUri, headers: headers);
    } catch (_) {
      return const []; // Offline / transient — treat as "nothing found".
    }

    _throwIfActionable(listRes.statusCode, listRes.body);
    if (listRes.statusCode != 200) return const [];

    final listData = jsonDecode(listRes.body) as Map<String, dynamic>;
    final messages = (listData['messages'] as List?) ?? const [];

    final texts = <String>[];
    for (final msg in messages.take(maxResults)) {
      final msgId = (msg as Map)['id'] as String?;
      if (msgId == null) continue;

      final getUri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages/$msgId',
      ).replace(queryParameters: {'format': 'full'});

      http.Response getRes;
      try {
        getRes = await _client.get(getUri, headers: headers);
      } catch (_) {
        continue;
      }
      _throwIfActionable(getRes.statusCode, getRes.body);
      if (getRes.statusCode != 200) continue;

      final msgData = jsonDecode(getRes.body) as Map<String, dynamic>;
      final text = _extractPlainText(msgData);
      if (text.trim().isNotEmpty) texts.add(text);
    }
    return texts;
  }

  /// Turns a Gmail `format=full` message into a single plain-text blob:
  /// `Subject` header + every decoded `text/plain` part (falling back to a
  /// tag-stripped `text/html` part), then the API `snippet` as a backstop.
  static String _extractPlainText(Map<String, dynamic> msgData) {
    final buffer = StringBuffer();

    final payload = msgData['payload'] as Map<String, dynamic>?;
    if (payload != null) {
      final subjectHeader = (payload['headers'] as List?)
          ?.cast<Map<String, dynamic>>()
          .firstWhere(
            (h) => (h['name'] as String?)?.toLowerCase() == 'subject',
            orElse: () => const {},
          );
      final subject = subjectHeader?['value'] as String?;
      if (subject != null && subject.isNotEmpty) buffer.writeln(subject);

      _collectParts(payload, buffer);
    }

    if (buffer.isEmpty) {
      final snippet = msgData['snippet'] as String?;
      if (snippet != null) {
        buffer.write(_unescapeHtmlEntities(snippet));
      }
    }

    // Statement bodies can be long; the discovery engine only needs the
    // header + first screenful where the "card ending 1234" line lives.
    final out = buffer.toString();
    return out.length > 8000 ? out.substring(0, 8000) : out;
  }

  static void _collectParts(Map<String, dynamic> part, StringBuffer buffer) {
    final mimeType = (part['mimeType'] as String?) ?? '';
    final body = part['body'] as Map<String, dynamic>?;
    final data = body?['data'] as String?;

    if (data != null && data.isNotEmpty) {
      final decoded = _decodeBase64Url(data);
      if (mimeType.startsWith('text/plain')) {
        buffer.writeln(decoded);
      } else if (mimeType.startsWith('text/html')) {
        buffer.writeln(_stripHtml(decoded));
      }
    }

    final parts = part['parts'] as List?;
    if (parts != null) {
      for (final child in parts) {
        _collectParts(child as Map<String, dynamic>, buffer);
      }
    }
  }

  static String _decodeBase64Url(String data) {
    try {
      final normalized = data.replaceAll('-', '+').replaceAll('_', '/');
      final padded = normalized.padRight((normalized.length + 3) & ~3, '=');
      return utf8.decode(base64.decode(padded), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String _stripHtml(String html) {
    final noStyle = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ');
    final noTags = noStyle.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _unescapeHtmlEntities(noTags).replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  }

  static String _unescapeHtmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');

  /// Maps the auth/config failure codes to messages the user can act on.
  /// 200 and 404 (empty search) fall through silently.
  void _throwIfActionable(int status, String body) {
    if (status == 401) {
      throw GmailScanException(
        'Gmail API 401: $body',
        userMessage: 'Your Google sign-in expired. Tap "Connect Gmail" again.',
      );
    }
    if (status == 403) {
      final lower = body.toLowerCase();
      if (lower.contains('has not been used') || lower.contains('disabled')) {
        throw GmailScanException(
          'Gmail API 403 (API disabled): $body',
          userMessage:
              'Gmail access for this app is not fully set up yet. Please try again later.',
        );
      }
      throw GmailScanException(
        'Gmail API 403: $body',
        userMessage:
            'PandaPay was not granted permission to read your Gmail. Tap "Connect Gmail" and allow read-only access.',
      );
    }
  }
}
