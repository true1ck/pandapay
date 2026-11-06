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

Map<String, dynamic> fixtureLearningSummary() => {
  'days': 30,
  'minUsers': 3,
  'layouts': {'new': 4, 'held': 1, 'queued': 2, 'working': 0, 'ready': 3, 'failed': 1, 'covered': 2, 'drafted': 1, 'rejected': 0, 'blocked': 0},
  'ai': {'calls': 17, 'costUsd': 0.42, 'approvedRules': 2, 'costPerApprovedRule': 0.21, 'notMoneyDrafts': 1},
  'corrections': [
    {'kind': 'wrong_amount', 'cases': 5, 'users': 3},
    {'kind': 'not_financial', 'cases': 2, 'users': 2},
  ],
  'signals': [
    {'kind': 'category_choice', 'users': 6, 'attestedShare': 0.83, 'belowThreshold': 2},
    {'kind': 'uncategorised', 'users': 4, 'attestedShare': 1, 'belowThreshold': 1},
  ],
  'coverage': {'hits': 900, 'toReview': 100, 'corrected': 4, 'readByRulesShare': 0.9},
  'trend': [
    {'day': '2026-11-04', 'aiCalls': 6, 'newLayouts': 3},
    {'day': '2026-11-05', 'aiCalls': 4, 'newLayouts': 2},
    {'day': '2026-11-06', 'aiCalls': 2, 'newLayouts': 1},
  ],
  'optIn': {'sharingNow': 12, 'synced30d': 30, 'shareOfSynced': 0.4, 'perDay': <Object?>[]},
  'candidates': {'categories': 1, 'merchantNames': 1, 'uncategorised': 1, 'total': 3},
};

Map<String, dynamic> fixtureCategoryCandidate({String status = 'new', double agreement = 0.86}) => {
  'merchantKey': 'SWIGGY',
  'category': 'dining',
  'users': 12,
  'keyUsers': 14,
  'testerUsers': 2,
  'times': 30,
  'agreement': agreement,
  'split': {'dining': 12, 'groceries': 2},
  'senders': ['HDFCBK', 'ICICIB'],
  'lastAt': '2026-11-06T09:00:00Z',
  'status': status,
  'decision': null,
};

/// One row per registry key, as GET /admin/sms/v2/settings returns them.
List<Map<String, dynamic>> fixtureSettings({Map<String, Object?> values = const {}}) {
  Map<String, dynamic> row(String key, String type, Object? def, {num? min, num? max, List<String>? allowed}) => {
    'key': key,
    'type': type,
    'value': values.containsKey(key) ? values[key] : def,
    'default': def,
    'min': min,
    'max': max,
    'ceiling': max,
    'allowed': allowed,
    'stored': values.containsKey(key),
    'updatedAt': values.containsKey(key) ? '2026-11-06T09:00:00.000000Z' : null,
    'updatedBy': null,
    'reason': values.containsKey(key) ? 'Fixture change' : null,
  };
  return [
    row('templates_per_user_per_day', 'int', 50, min: 1, max: 500),
    row('corrections_per_user_per_day', 'int', 200, min: 1, max: 2000),
    row('signals_per_user_per_day', 'int', 500, min: 1, max: 5000),
    row('signals_min_distinct_users', 'int', 1, min: 1, max: 20),
    row('signals_retention_days', 'int', 180, min: 30, max: 730),
    row('intake_enabled', 'bool', true),
    row('ai_enabled', 'bool', true),
    row('ai_merchant_suggestions_enabled', 'bool', false),
    row('ai_model', 'model', null, allowed: ['model-a', 'model-b']),
    row('ai_rpm', 'int', 30, min: 1, max: 60),
    row('ai_tpm', 'int', 100000, min: 1000, max: 200000),
    row('ai_temperature', 'number', 0.1, min: 0, max: 1),
    row('ai_max_output_tokens', 'int', 4096, min: 512, max: 8192),
    row('ai_monthly_budget_usd', 'number', 10, min: 0, max: 1000),
    row('auto_pause_min_hits', 'int', 50, min: 10, max: 10000),
    row('auto_pause_min_rate', 'number', 0.01, min: 0.001, max: 0.5),
  ];
}

class FakeAdmin extends AdminApi {
  FakeAdmin()
    : super(apiBaseUrl: 'https://console.invalid', accessToken: 'fixture');
  int latestVersion = 1;
  String latestStatus = 'active';
  List<Object?> templates = <Object?>[];
  Map<String, dynamic> metrics = {'ai': <Object?>[]};
  List<Map<String, dynamic>> settings = fixtureSettings();
  List<Object?> userLimits = <Object?>[];
  Map<String, dynamic> learningSummary = fixtureLearningSummary();
  List<Object?> reporters = <Object?>[];
  List<Object?> auditEntries = <Object?>[];
  List<Object?> learningCategories = <Object?>[];
  List<Object?> learningNames = <Object?>[];
  List<Object?> learningOther = <Object?>[];

  /// When set, the next settings save answers with this HTTP status.
  int? failSettingSaveWith;
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
    if (path.startsWith('/admin/sms/v2/learning/summary')) return learningSummary;
    if (path.startsWith('/admin/sms/v2/learning/categories')) {
      return {'minUsers': 3, 'days': 90, 'taxonomyVersion': 1, 'candidates': learningCategories};
    }
    if (path.startsWith('/admin/sms/v2/learning/merchant-names')) {
      return {'minUsers': 3, 'days': 90, 'taxonomyVersion': 1, 'candidates': learningNames};
    }
    if (path.startsWith('/admin/sms/v2/learning/uncategorised')) {
      return {'minUsers': 3, 'days': 90, 'taxonomyVersion': 1, 'candidates': learningOther};
    }
    if (path == '/admin/sms/v2/learning/decisions') return {'recorded': true};
    if (path.startsWith('/admin/sms/v2/learning/reporters')) return {'days': 7, 'reporters': reporters};
    if (path.startsWith('/admin/sms/v2/audit')) return {'entries': auditEntries};
    if (path.startsWith('/admin/sms/v2/merchant-suggestions/')) return {'removed': true};
    if (path == '/admin/sms/v2/settings') return {'settings': settings};
    if (path.startsWith('/admin/sms/v2/settings/')) {
      if (failSettingSaveWith != null) {
        throw AdminApiException('failed', statusCode: failSettingSaveWith);
      }
      return {'setting': <String, dynamic>{}};
    }
    if (path == '/admin/sms/v2/user-limits') return {'limits': userLimits};
    if (path.startsWith('/admin/sms/v2/user-limits/')) return {'deleted': true};
    if (path == '/admin/sms/v2/templates') return {'templates': templates};
    if (path.startsWith('/admin/sms/v2/templates/') && path.endsWith('/reject')) {
      return {'status': 'failed', 'decision': 'rejected'};
    }
    if (path.startsWith('/admin/sms/v2/templates/') && path.endsWith('/requeue')) {
      return {'status': 'queued'};
    }
    if (path.startsWith('/admin/sms/v2/templates/') && path.endsWith('/block')) {
      return {'status': 'blocked'};
    }
    if (path == '/admin/sms/v2/metrics') return metrics;
    if (path == '/admin/sms/v2/bundles') return {'bundles': <Object?>[]};
    if (path == '/admin/sms/v2/category-rules') {
      return {'drafts': <Object?>[], 'rules': <Object?>[]};
    }
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
      final bundle = {
        ...editorBundle({
          ...rule(),
          'version': latestVersion,
          'status': 'active',
        }),
        'senders': catalog,
      };
      return {'bundle': bundle, 'contentSha256': evaluationContentHash(bundle)};
    }
    if (path.endsWith('/draft')) {
      latestVersion = 2;
      latestStatus = 'draft';
      return {'ruleId': 'CONSOLE-SPEND', 'version': 2, 'status': 'draft'};
    }
    if (path.endsWith('/publish')) {
      latestStatus = 'active';
      return {'published': true};
    }
    if (path.contains('/pause?')) {
      latestStatus = 'paused';
      return {'paused': true};
    }
    if (path == '/admin/sms/v2/rules/CONSOLE-SPEND') {
      return {
        'ruleId': 'CONSOLE-SPEND',
        'versions': [
          for (var version = 1; version <= latestVersion; version++)
            {
              'version': version,
              'status': version == latestVersion ? latestStatus : 'active',
              'body': {
                ...rule(),
                'version': version,
                'status': version == latestVersion ? latestStatus : 'active',
              },
              'cohorts': [
                if (version == latestVersion && latestStatus != 'draft')
                  {
                    'cohort': 'testers',
                    'pausedAt': latestStatus == 'paused'
                        ? '2026-11-04T00:00:00Z'
                        : null,
                  },
              ],
              'metrics7d': {'hits': 5},
            },
        ],
      };
    }
    throw StateError('Unexpected request $method $path');
  }
}
