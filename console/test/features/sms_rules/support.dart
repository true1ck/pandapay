import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/features/sms_rules/golden_runner.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart';

Map<String, dynamic> rule() => {
  'id': 'CONSOLE-SPEND',
  'version': 1,
  'family': 'card_spend',
  'senders': ['TESTBK'],
  'priority': 500,
  'match': {
    'pattern': r'^Rs\. (?<amt>[0-9]+) spent at (?<merchant>[A-Z ]+)\.$',
    'flags': 'i',
  },
  'emit': [
    {
      'factType': 'movement',
      'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
      'amounts': [
        {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
      ],
      'counterparty': {'nameFrom': 'merchant', 'kind': 'merchant'},
    },
  ],
  'confidence': 0.99,
  'status': 'draft',
  'createdBy': 'admin:test',
  'updatedAt': '2026-11-01T00:00:00Z',
  'examples': [
    {
      'sender': 'TESTBK',
      'body': 'Rs. 125 spent at SHOP.',
      'expectFactTypes': ['movement'],
    },
    {
      'sender': 'TESTBK',
      'body': 'Payment failed.',
      'expectFactTypes': <String>[],
    },
  ],
};
const catalog = [
  {
    'brand': 'TESTBK',
    'issuerSlug': 'test',
    'issuerKind': 'bank',
    'aliases': <String>[],
  },
];
BrowserGoldenRunner tinyRunner() => BrowserGoldenRunner(
  contextBundle: {'senders': catalog},
  cases: GoldenBundle([
    GoldenCase.fromJson({
      'id': 'tiny',
      'templateHash': 'a' * 64,
      'weight': 1,
      'source': 'synthetic',
      'messages': [
        {
          'sender': 'TESTBK',
          'body': 'Rs. 125 spent at SHOP.',
          'observedAt': '2026-11-01T12:00:00Z',
        },
      ],
      'expect': {
        'facts': [
          {
            'factType': 'movement',
            'amounts': [
              {'role': 'posted', 'minor': 12500, 'unit': 'INR'},
            ],
          },
        ],
      },
    }),
  ], []),
  gates: {'captureRecall': const Gate(min: 1)},
);
const caseId = '00000000-0000-4000-8000-000000000001';

class FakeAdmin extends AdminApi {
  FakeAdmin()
    : super(apiBaseUrl: 'https://console.invalid', accessToken: 'fixture');
  final requests = <(String, String, Map<String, dynamic>?)>[];
  @override
  Future<Map<String, dynamic>> smsV2Request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    requests.add((method, path, body));
    if (path == '/admin/sms/v2/rules') {
      return {
        'rules': [
          {
            'ruleId': 'CONSOLE-SPEND',
            'latestVersion': 1,
            'status': 'active',
            'family': 'card_spend',
            'senders': ['TESTBK'],
            'metrics7d': {'hits': 5, 'toReview': 0, 'corrected': 0},
          },
        ],
      };
    }
    if (path == '/admin/sms/v2/templates') return {'templates': <Object?>[]};
    if (path == '/admin/sms/v2/metrics') return {'ai': <Object?>[]};
    if (path == '/admin/sms/v2/bundles') return {'bundles': <Object?>[]};
    if (path == '/admin/sms/v2/corrections?groupBy=template') {
      return {
        'groups': [
          {
            'key': 'template-a',
            'cases': [
              {
                'case_id': caseId,
                'status': 'open',
                'stage': 'extraction',
                'correction_kind': 'wrong_amount',
                'redacted_template': '<AMT> spent at <PARTY>.',
                'is_tester': true,
                'trace': {
                  'ruleId': 'CONSOLE-SPEND',
                  'ruleVersion': 1,
                  'stage': 'extraction',
                },
              },
            ],
          },
        ],
      };
    }
    if (path.endsWith('/decision')) {
      return body?['decision'] == 'data_fix' ? {'ruleDraft': rule()} : {};
    }
    if (path.endsWith('/example')) {
      return {'caseId': caseId, 'readyForCodeFix': true};
    }
    if (path.endsWith('/export')) {
      return {
        'id': caseId,
        'source': 'synthetic',
        'messages': <Object?>[],
        'expect': {'facts': <Object?>[]},
      };
    }
    if (path.contains('/candidate?')) {
      final bundle = editorBundle({...rule(), 'status': 'active'});
      return {'bundle': bundle, 'contentSha256': evaluationContentHash(bundle)};
    }
    if (path.endsWith('/draft')) {
      return {'ruleId': 'CONSOLE-SPEND', 'version': 2, 'status': 'draft'};
    }
    if (path.endsWith('/publish')) return {'published': true};
    if (path == '/admin/sms/v2/rules/CONSOLE-SPEND') {
      return {
        'ruleId': 'CONSOLE-SPEND',
        'versions': [
          {
            'version': 1,
            'status': 'active',
            'body': rule(),
            'cohorts': <Object?>[],
            'metrics7d': {'hits': 5},
          },
        ],
      };
    }
    throw StateError('Unexpected request $method $path');
  }
}
