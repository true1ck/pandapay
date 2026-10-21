import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';

void main() {
  test('a message the server refuses must not stop the review replay', () {
    // The replay re-submits every open review item so a newer parser can
    // resolve it. A single rejected message used to end the pass, so every
    // later message stayed unresolved and the per-version gate never
    // cleared — which is how a card's AutoPay bill notice kept its old
    // reading while later messages were fine.
    expect(reviewReplayShouldStop(ApiException('POST /transactions/from-sms failed: 400 bad request')), isFalse);
    expect(reviewReplayShouldStop(ApiException('POST /transactions/from-sms failed: 403 forbidden')), isFalse);
    expect(reviewReplayShouldStop(ApiException('POST /transactions/from-sms failed: 409 conflict')), isFalse);
  });

  test('a transport or server failure stops the pass', () {
    // The API being offline or auth not restored yet must leave the
    // remaining items for the next app start, not skip them.
    expect(reviewReplayShouldStop(ApiException('POST /transactions/from-sms failed: 500 internal error')), isTrue);
    expect(reviewReplayShouldStop(ApiException('POST /transactions/from-sms failed: 503 unavailable')), isTrue);
    expect(reviewReplayShouldStop(const SocketException('connection reset')), isTrue);
  });
}
