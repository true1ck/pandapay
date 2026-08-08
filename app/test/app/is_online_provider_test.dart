import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';

void main() {
  test('connectivityResultToIsOnline maps ConnectivityResult.none to false, anything else to true', () {
    expect(connectivityResultToIsOnline([ConnectivityResult.none]), false);
    expect(connectivityResultToIsOnline([ConnectivityResult.wifi]), true);
    expect(connectivityResultToIsOnline([ConnectivityResult.mobile]), true);
    expect(connectivityResultToIsOnline([]), false);
    expect(connectivityResultToIsOnline([ConnectivityResult.none, ConnectivityResult.wifi]), true);
  });
}
