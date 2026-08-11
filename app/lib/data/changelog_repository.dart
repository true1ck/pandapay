import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// H10 (What's New): one row from `changelog_entries`. `GET /changelog` is
/// unauthenticated (release notes aren't PII) and returns at most 20 rows,
/// newest first — see api/src/index.js's `GET /changelog` route.
class ChangelogEntry {
  final String id;
  final String appVersion;
  final String title;
  final String bodyMarkdown;
  final bool highlightsDataChange;
  final DateTime publishedAt;

  const ChangelogEntry({
    required this.id,
    required this.appVersion,
    required this.title,
    required this.bodyMarkdown,
    required this.highlightsDataChange,
    required this.publishedAt,
  });

  factory ChangelogEntry.fromJson(Map<String, dynamic> json) {
    return ChangelogEntry(
      id: json['id'] as String,
      appVersion: json['app_version'] as String,
      title: json['title'] as String,
      bodyMarkdown: json['body_markdown'] as String? ?? '',
      highlightsDataChange: json['highlights_data_change'] as bool? ?? false,
      publishedAt: DateTime.parse(json['published_at'] as String),
    );
  }
}

/// Fetches the changelog feed. No auth header — matches the backend route,
/// which deliberately has no `requireAuth` gate.
class ChangelogRepository {
  final String apiBaseUrl;
  final http.Client _client;

  ChangelogRepository({required this.apiBaseUrl, http.Client? client}) : _client = client ?? http.Client();

  Future<List<ChangelogEntry>> fetch() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/changelog'));
    if (response.statusCode != 200) {
      throw ApiException('GET /changelog failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['entries'] as List).cast<Map<String, dynamic>>().map(ChangelogEntry.fromJson).toList();
  }
}
