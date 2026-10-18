# PandaPay compatibility patch

This is `telephony` 0.2.0, retained under its original license because the
upstream package is discontinued and PandaPay's SMS import still depends on
its Flutter API.

The Android build metadata is updated for the app's current toolchain:

- namespace: `com.shounakmulay.telephony`
- compile SDK: 37
- min SDK: 23
- Java/Kotlin target: 17

Keeping the patch in the repository is deliberate. A root Gradle override is
order-dependent: the plugin's Groovy build script can assign SDK 31 after the
root callback, while AGP 9 rejects changing it after project evaluation. The
local path dependency makes clean CI and developer builds use the same input.

## Permission callback ownership

`SmsMethodCallHandler.onRequestPermissionsResult` now handles only an active
telephony request with a matching request code. Flutter also delivers other
plugins' permission results to this listener. Previously, granting camera,
location or notifications could replay the last SMS query and submit its
MethodChannel reply twice, crashing the app. Empty/cancelled results are denied,
and a handled denial is marked consumed.

Pending permission requests also retain their original method call, arguments
and reply instead of depending on the handler's last request. The callback is
consumed before replaying that call, and every native reply is guarded against
duplicate completion. Overlapping telephony permission requests return a
recoverable error. Nullable service/signal errors return immediately rather
than subsequently submitting success for the same call.
