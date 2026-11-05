import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
#if !PANDAPAY_DEVICE_IMPORT_PROBE
    // A URL callback/Flutter resume may be observed before UIKit reports an
    // active scene. Recheck committed continuation once activation finishes.
    IncomingSmsBridge.notifyReady()
    // Bring back the import's Lock Screen progress if it was swiped away.
    SmsImportLiveActivityHost.ensure()
#endif
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
#if !PANDAPAY_DEVICE_IMPORT_PROBE
    // Leaving the app mid-import: make sure the progress is on the Lock Screen.
    SmsImportLiveActivityHost.ensure()
#endif
  }

  override func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
#if !PANDAPAY_DEVICE_IMPORT_PROBE
    let remaining = contexts.filter { !IncomingSmsBridge.handleReturnURL($0.url) }
    if !remaining.isEmpty { super.scene(scene, openURLContexts: Set(remaining)) }
#else
    super.scene(scene, openURLContexts: contexts)
#endif
  }
}
