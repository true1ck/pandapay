import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
#if PANDAPAY_DEVICE_IMPORT_PROBE
    DeviceHistoryProbeBridge.register(messenger: engineBridge.applicationRegistrar.messenger())
#elseif !targetEnvironment(simulator)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
#else
    SimulatorPluginRegistrant.register(with: engineBridge.pluginRegistry)
#if DEBUG
    PrototypeBankMessageBridge.register(messenger: engineBridge.applicationRegistrar.messenger())
    if #available(iOS 16.0, *) {
      PrototypeBankMessageShortcuts.updateAppShortcutParameters()
    }
#endif
#endif
  }
}
