import Flutter
import UIKit

/// iOS half of the `app.pandapay/assistant` channel that Android's MainActivity
/// serves. A tap on a home-screen widget opens `pandapay://assistant/...`; this
/// hands the link to the same Dart code Android uses (`_openAssistantUri`), so a
/// widget tap lands on the same screen on both platforms and waits for sign-in
/// restore before navigating.
///
/// Only the two links the widgets use are accepted. The custom scheme can be
/// opened by any app or web page, so the other assistant actions (such as
/// pre-filling an expense) stay out of reach here.
enum AssistantLinkBridge {
  private static let channelName = "app.pandapay/assistant"
  private static let allowedPaths: Set<String> = ["spending", "best-card"]
  private static var channel: FlutterMethodChannel?
  private static var pending: String?
  private static var dartIsReady = false

  /// True for any `pandapay://assistant/...` link, accepted or not, so the app
  /// never passes one to the router as a page address.
  static func isAssistantURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "pandapay" && url.host?.lowercased() == "assistant"
  }

  static func isAllowed(_ url: URL) -> Bool {
    guard isAssistantURL(url) else { return false }
    let first = url.pathComponents.dropFirst().first ?? ""
    return allowedPaths.contains(first)
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "getInitialAssistantUri" {
        // Dart asks once after its first frame. A link that launched the app is
        // waiting here; later links are pushed straight through the channel.
        let value = pending
        pending = nil
        dartIsReady = true
        result(value)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Takes a link from the scene. Returns true when the link was an assistant
  /// link and has been dealt with (delivered, queued or dropped).
  @discardableResult
  static func handle(_ url: URL) -> Bool {
    guard isAssistantURL(url) else { return false }
    guard isAllowed(url) else { return true }
    if dartIsReady, let channel = channel {
      channel.invokeMethod("assistantUri", arguments: url.absoluteString)
    } else {
      pending = url.absoluteString
    }
    return true
  }
}
