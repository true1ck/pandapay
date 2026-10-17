import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/spend_reports_repository.dart';

void main() {
  test('custom report sends inclusive date-only bounds to the API', () async {
    late Uri requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response(
        jsonEncode({
          'period': 'custom',
          'periodStart': '2026-08-02T18:30:00.000Z',
          'periodEnd': '2026-08-14T18:30:00.000Z',
          'elapsedFraction': 1,
          'totals': {
            'spend': {'totalInr': 100, 'txnCount': 1, 'rewardsInr': 1},
          },
          'previousTotals': {},
          'byCategory': [],
          'byMerchant': [],
          'byCard': [],
          'byInstrument': [],
          'byCardCategory': [],
          'series': [],
        }),
        200,
      );
    });

    final report =
        await SpendReportsRepository(
          apiBaseUrl: 'https://api.example.test',
          accessToken: 'token',
          client: client,
        ).fetchReport(
          period: SpendPeriod.custom,
          from: DateTime(2026, 8, 3),
          to: DateTime(2026, 8, 14),
          timeZone: 'Asia/Kolkata',
        );

    expect(report.period, SpendPeriod.custom);
    expect(requested.queryParameters, {
      'period': 'custom',
      'from': '2026-08-03',
      'to': '2026-08-14',
      'buckets': '12',
      'tz': 'Asia/Kolkata',
    });
  });

  test('custom reports require both dates', () async {
    final repo = SpendReportsRepository(
      apiBaseUrl: 'https://api.example.test',
      accessToken: 'token',
      client: MockClient((_) async => http.Response('{}', 200)),
    );

    expect(
      () => repo.fetchReportJson(period: SpendPeriod.custom),
      throwsArgumentError,
    );
  });
}
