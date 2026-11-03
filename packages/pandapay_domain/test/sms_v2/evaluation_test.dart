import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test(
    'candidate hash matches Node contentSha256 and ignores serving fields',
    () {
      final bundle =
          (jsonDecode(
                    File(
                      '../../contracts/sms/v2/fixtures/valid/bundle/full.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, dynamic>();
      const nodeHash =
          'cfebdcfaaa4fbc57e6014e91a4e676d9b57d0244a5f69ca0828d26318aa09b6f';
      expect(evaluationContentHash(bundle), nodeHash);
      expect(
        evaluationContentHash({
          ...bundle,
          'signature': null,
          'bundleVersion': 999,
          'createdAt': '2020-01-01T00:00:00Z',
          'expiresAt': '2030-01-01T00:00:00Z',
        }),
        nodeHash,
      );
      expect(
        evaluationContentHash({...bundle, 'taxonomyVersion': 2}),
        isNot(nodeHash),
      );
    },
  );
}
