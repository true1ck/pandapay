/// The last connectivity value seen by `isOnlineProvider`, readable without a
/// `Ref` (WP-C1). `null` means "nothing observed yet" and is treated as online
/// everywhere, exactly like the old `_lastKnownOffline = false` default.
class KnownConnectivity {
  KnownConnectivity._();

  static bool? online;

  static bool get knownOffline => online == false;

  /// For tests.
  static void reset() => online = null;
}
