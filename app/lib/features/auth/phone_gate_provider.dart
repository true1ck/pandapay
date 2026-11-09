import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Whether the account must add a phone number before it can use anything else.
/// Off unless the server runs with the phone lock on.
class PhoneGateState {
  final bool needsPhone;

  /// The ten digits typed at sign-up, when the server refused them, so the Add
  /// phone screen can show what was typed instead of an empty box.
  final String? prefill;

  /// Why the typed number was refused, in the server's plain wording.
  final String? message;

  const PhoneGateState({this.needsPhone = false, this.prefill, this.message});
}

/// Owns the phone gate for the signed-in account.
///
/// The gate starts closed and costs nothing at startup. It opens ([needs]) in two
/// ways: sign-in asks the server and finds the account needs a phone, or any later
/// API call is answered 403 `phone_required` (the shared authenticated client calls
/// [needs]). A server without the phone lock never says either, so the gate stays
/// closed. [satisfied] closes it again once a phone is saved.
class PhoneGateController extends StateNotifier<PhoneGateState> {
  PhoneGateController(this._ref) : super(const PhoneGateState()) {
    _ref.listen<String?>(accessTokenProvider, (previous, next) {
      if (next == null) state = const PhoneGateState();
    });
  }

  final Ref _ref;

  /// Opens the gate, so the Add phone screen shows. Sign-up passes the number the
  /// server refused and why. A later `phone_required` reply passes nothing and
  /// keeps what is already known.
  void needs({String? prefill, String? message}) {
    state = PhoneGateState(
      needsPhone: true,
      prefill: prefill ?? state.prefill,
      message: message ?? state.message,
    );
  }

  /// A phone is now on the account.
  void satisfied() => state = const PhoneGateState();
}

final phoneGateProvider =
    StateNotifierProvider<PhoneGateController, PhoneGateState>(
      (ref) => PhoneGateController(ref),
    );
