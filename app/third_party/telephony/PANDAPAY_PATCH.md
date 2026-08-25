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
