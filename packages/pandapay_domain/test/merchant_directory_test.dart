import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C5 resolver. The JS twin is api/src/merchant_directory.js; both
/// must follow the same four steps.
void main() {
  final directory = MerchantDirectory.fromJson({
    'merchants': [
      {
        'slug': 'swiggy',
        'name': 'Swiggy',
        'parent_slug': null,
        'aliases': ['swiggy', 'bundl technologies'],
        'vpa_prefixes': ['swiggy'],
      },
      {
        'slug': 'instamart',
        'name': 'Swiggy Instamart',
        'parent_slug': 'swiggy',
        'aliases': ['swiggy instamart', 'instamart'],
        'vpa_prefixes': ['instamart'],
      },
      {
        'slug': 'zomato',
        'name': 'Zomato',
        'aliases': ['zomato'],
        'vpa_prefixes': ['zomato'],
        'group': 'zomato',
      },
      {
        'slug': 'amazon',
        'name': 'Amazon',
        'aliases': ['amazon', 'amzn'],
        'vpa_prefixes': ['amazon', 'amazonpay'],
      },
      {
        'slug': 'amazon_alt',
        'name': 'Amazon (duplicate alias)',
        'aliases': ['amzn'],
      },
      {
        'slug': 'retired',
        'name': 'Retired brand',
        'aliases': ['retired brand'],
        'is_active': false,
      },
      {
        'slug': 'loop_a',
        'name': 'Loop A',
        'parent_slug': 'loop_b',
        'aliases': ['loop a'],
      },
      {
        'slug': 'loop_b',
        'name': 'Loop B',
        'parent_slug': 'loop_a',
        'aliases': ['loop b'],
      },
      {'slug': 'd0', 'name': 'D0', 'parent_slug': 'd1'},
      {'slug': 'd1', 'name': 'D1', 'parent_slug': 'd2'},
      {'slug': 'd2', 'name': 'D2', 'parent_slug': 'd3'},
      {'slug': 'd3', 'name': 'D3', 'parent_slug': 'd4'},
      {'slug': 'd4', 'name': 'D4', 'parent_slug': 'd5'},
      {'slug': 'd5', 'name': 'D5', 'parent_slug': 'd6'},
      {'slug': 'd6', 'name': 'D6', 'parent_slug': null},
      {'name': 'no slug — skipped'},
    ],
    'platforms': [
      {
        'slug': 'phonepe_app',
        'name': 'PhonePe app',
        'kind': 'payment_app',
        'aliases': ['phonepe'],
      },
      {
        'slug': 'hdfc_smartbuy',
        'name': 'HDFC SmartBuy',
        'kind': 'bank_portal',
        'issuer_slug': 'hdfc',
        'aliases': ['smartbuy', 'hdfc smartbuy'],
      },
    ],
  });

  group('normalize (C5 step 1)', () {
    test('lowercases and collapses non-alphanumeric runs to one space', () {
      expect(
        normalizeMerchantText('  BUNDL--TECHNOLOGIES  Pvt. Ltd '),
        'bundl technologies pvt ltd',
      );
      expect(normalizeMerchantText('Café*Coffee_Day'), 'caf coffee day');
      expect(normalizeMerchantText('***'), '');
    });
  });

  group('alias match (C5 step 3)', () {
    test('legal-entity alias resolves to the brand', () {
      final m = directory.resolve(merchantName: 'BUNDL TECHNOLOGIES PVT LTD')!;
      expect(m.slug, 'swiggy');
      expect(m.source, MerchantMatchSource.alias);
      expect(m.matched, 'bundl technologies');
    });

    test('aliases must match on word boundaries', () {
      expect(directory.resolve(merchantName: 'Swiggywala Store'), isNull);
      expect(directory.resolve(merchantName: 'Notswiggy'), isNull);
      expect(directory.resolve(merchantName: 'pay*SWIGGY*blr')!.slug, 'swiggy');
    });

    test('the longest matching alias wins', () {
      expect(
        directory.resolve(merchantName: 'SWIGGY INSTAMART BANGALORE')!.slug,
        'instamart',
      );
    });

    test('equal-length aliases tie-break to the slug that sorts first', () {
      expect(directory.resolve(merchantName: 'AMZN Mktp')!.slug, 'amazon');
    });

    test('inactive merchants never resolve', () {
      expect(directory.resolve(merchantName: 'Retired Brand Store'), isNull);
    });

    test('unknown or empty text resolves to nothing', () {
      expect(directory.resolve(merchantName: 'Corner shop'), isNull);
      expect(directory.resolve(merchantName: ''), isNull);
      expect(directory.resolve(), isNull);
    });
  });

  group('VPA match (C5 step 2)', () {
    test('a VPA prefix match wins over the merchant text', () {
      final m = directory.resolve(
        merchantName: 'Zomato',
        vpa: 'instamart.order@ybl',
      )!;
      expect(m.slug, 'instamart');
      expect(m.source, MerchantMatchSource.vpa);
      expect(m.lineage, ['instamart', 'swiggy']);
    });

    test('the handle is normalized and only the part before @ counts', () {
      expect(directory.resolve(vpa: 'Swiggy-Foods@icici')!.slug, 'swiggy');
      expect(directory.resolve(vpa: 'someone@swiggy'), isNull);
    });

    test('the longest VPA prefix wins', () {
      final m = directory.resolve(vpa: 'amazonpay@apl')!;
      expect(m.slug, 'amazon');
      expect(m.matched, 'amazonpay');
    });

    test('a VPA with no match falls back to the merchant text', () {
      final m = directory.resolve(merchantName: 'Zomato Ltd', vpa: 'paytm@x')!;
      expect(m.slug, 'zomato');
      expect(m.source, MerchantMatchSource.alias);
    });
  });

  group('ancestors (C5 step 4)', () {
    test('a sub-brand lists its parent', () {
      expect(directory.lineage('instamart'), ['instamart', 'swiggy']);
      expect(directory.lineage('swiggy'), ['swiggy']);
    });

    test('a cycle stops without repeating', () {
      expect(directory.lineage('loop_a'), ['loop_a', 'loop_b']);
    });

    test('at most five ancestors', () {
      expect(directory.lineage('d0'), ['d0', 'd1', 'd2', 'd3', 'd4', 'd5']);
    });

    test('an unknown slug is its own lineage', () {
      expect(directory.lineage('nobody'), ['nobody']);
    });
  });

  group('platforms', () {
    test('resolvePlatform uses the same alias rules', () {
      expect(
        directory.resolvePlatform('HDFC SmartBuy flights'),
        'hdfc_smartbuy',
      );
      expect(directory.resolvePlatform('PhonePe'), 'phonepe_app');
      expect(directory.resolvePlatform('PhonePeX'), isNull);
      expect(directory.resolvePlatform(null), isNull);
    });
  });

  group('parsing', () {
    test('an entry without a slug is skipped with a warning', () {
      expect(directory.parseWarnings, hasLength(1));
      expect(directory.merchant('zomato')!.group, 'zomato');
    });

    test('toJson round-trips', () {
      final again = MerchantDirectory.fromJson(
        jsonDecode(jsonEncode(directory.toJson())) as Map<String, dynamic>,
      );
      expect(again.merchants.length, directory.merchants.length);
      expect(again.platforms.length, directory.platforms.length);
      expect(again.merchant('retired')!.isActive, isFalse);
      expect(
        again.resolve(merchantName: 'swiggy instamart')!.slug,
        'instamart',
      );
    });

    test('the shared directory file parses cleanly and has unique slugs', () {
      final file = MerchantDirectory.fromJson(
        jsonDecode(
              File(
                '../../db/fixtures/merchant_directory.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      expect(file.parseWarnings, isEmpty);
      expect(file.merchants, isNotEmpty);
      expect(
        file.merchants.map((m) => m.slug).toSet().length,
        file.merchants.length,
      );
      expect(
        file.resolve(merchantName: 'INSTAMART BLR')!.lineage,
        containsAllInOrder(['instamart', 'swiggy']),
      );
    });
  });
}
