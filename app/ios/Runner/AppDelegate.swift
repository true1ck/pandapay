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
#if !targetEnvironment(simulator)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
#else
    SimulatorPluginRegistrant.register(with: engineBridge.pluginRegistry)
#endif
  }
}
