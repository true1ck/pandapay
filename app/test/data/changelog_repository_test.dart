import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/changelog_repository.dart';

/// Task H10: fixture below is a REAL captured response from
/// `curl -s localhost:4000/changelog` against the seeded dev database (one
/// real row, app_version 1.1.0), not a hand-guessed shape.
void main() {
  group('ChangelogEntry.fromJson', () {
    test('parses a real /changelog response entry', () {
      final json = {
        'id': 'd9c8b3e6-b5e7-4a31-826c-e00c78625691',
        'app_version': '1.1.0',
        'title': 'Smarter cap-boundary recommendations',
        'body_markdown':
            "We fixed how the recommendation engine blends rewards when a purchase crosses a card's reward-value cap mid-transaction — you'll see more accurate ₹ estimates near your cap limits.",
        'highlights_data_change': true,
        'published_at': '2026-08-07T04:49:30.996Z',
      };

      final entry = ChangelogEntry.fromJson(json);

      expect(entry.id, 'd9c8b3e6-b5e7-4a31-826c-e00c78625691');
      expect(entry.appVersion, '1.1.0');
      expect(entry.title, 'Smarter cap-boundary recommendations');
      expect(entry.bodyMarkdown, contains('reward-value cap'));
      expect(entry.highlightsDataChange, isTrue);
      expect(entry.publishedAt, DateTime.parse('2026-08-07T04:49:30.996Z'));
    });

    test('defaults highlightsDataChange to false and body to empty when absent', () {
      final entry = ChangelogEntry.fromJson({
        'id': 'x',
        'app_version': '1.0.0',
        'title': 'Initial release',
        'published_at': '2026-01-01T00:00:00.000Z',
      });

      expect(entry.highlightsDataChange, isFalse);
      expect(entry.bodyMarkdown, '');
    });
  });
}
