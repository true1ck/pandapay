#if !PANDAPAY_DEVICE_IMPORT_PROBE
import AppIntents
import Flutter
import Foundation
import UIKit

@available(iOS 16.0, *)
enum SmsReceiveDateSource: String, AppEnum {
  case estimated, original
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Receive date evidence")
  static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .estimated: "Estimated (Current Date)", .original: "Original Message Date"
  ]
}

@available(iOS 16.0, *)
struct CapturePandaPayMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Capture Incoming SMS in PandaPay"
  static var description = IntentDescription("Save the full message, sender text and receive date for PandaPay's shared SMS processing. Enable SMS Shortcuts in PandaPay first.")
  static var openAppWhenRun = false
  // Every field has a distinct source. An omitted field must stay omitted,
  // rather than inheriting/converting the preceding action's result.
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender (text)", inputConnectionBehavior: .never) var sender: String?
  @Parameter(title: "Receive date", inputConnectionBehavior: .never) var receivedAt: Date?
  @Parameter(title: "Date evidence", default: .estimated, inputConnectionBehavior: .never) var dateSource: SmsReceiveDateSource
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value: String
    do {
      value = try IncomingSmsSpool.shared.capture(body: body, sender: sender, receivedAt: receivedAt, provenance: dateSource.rawValue)
    } catch IncomingSmsError.inactive {
      // A signed-out or deliberately disabled capture is an expected no-op,
      // not a recurring Shortcuts error notification on every incoming SMS.
      return .result(value: "capture_disabled")
    }
    IncomingSmsBridge.notifyReady()
    return .result(value: value)
  }
}

@available(iOS 16.0, *)
struct BeginPandaPaySmsWindowIntent: AppIntent {
  static var title: LocalizedStringResource = "Begin PandaPay SMS Window"
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    _ = try IncomingSmsSpool.shared.boundary(request: request, end: false)
    return .result(value: request)
  }
}

@available(iOS 16.0, *)
struct PandaPaySmsWindowStartIntent: AppIntent {
  static var title: LocalizedStringResource = "PandaPay SMS Window Start"
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  func perform() async throws -> some IntentResult & ReturnsValue<Date> {
    .result(value: try IncomingSmsSpool.shared.boundary(request: request, end: false, observingIntent: true))
  }
}

@available(iOS 16.0, *)
struct PandaPaySmsWindowEndIntent: AppIntent {
  static var title: LocalizedStringResource = "PandaPay SMS Window End"
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  func perform() async throws -> some IntentResult & ReturnsValue<Date> {
    .result(value: try IncomingSmsSpool.shared.boundary(request: request, end: true, observingIntent: true))
  }
}

@available(iOS 16.0, *)
struct CapturePandaPayWindowMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Capture PandaPay Window SMS"
  static var openAppWhenRun = false
  // Request/index are control values; body/sender/date are explicit properties
  // of one Message. Do not auto-connect any of them to a whole search/loop result.
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Repeat index", inputConnectionBehavior: .never) var itemIndex: Int
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender (text)", inputConnectionBehavior: .never) var sender: String?
  @Parameter(title: "Original Message Date", inputConnectionBehavior: .never) var receivedAt: Date?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value = try IncomingSmsSpool.shared.capture(body: body, sender: sender, receivedAt: receivedAt,
        provenance: "original", request: request, itemID: String(itemIndex))
    IncomingSmsBridge.notifyReady()
    return .result(value: value)
  }
}

/// Keep the published text input types used by saved main-app Shortcuts.
/// No collection-derived Repeat Index crosses this boundary; native
/// content-bound receipts handle replay without changing existing bindings.
@available(iOS 16.0, *)
struct CapturePandaPayHistoryMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "Capture PandaPay History SMS"
  static var description = IntentDescription("Import one message with its original receive date. Existing body, sender text and date mappings remain compatible; completion and duplicate checks stay in PandaPay.")
  static var openAppWhenRun = false
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Message body", inputConnectionBehavior: .never) var body: String?
  @Parameter(title: "Sender (text)", inputConnectionBehavior: .never) var sender: String?
  @Parameter(title: "Original Message Date", inputConnectionBehavior: .never) var receivedAt: Date?
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value = try IncomingSmsSpool.shared.capture(body: body, sender: sender, receivedAt: receivedAt,
        provenance: "original", request: request, useMessageReceipt: true)
    IncomingSmsBridge.notifyReady()
    // The input is durable before any UI transition. Only the current
    // app-started launch admits this; the same action stays quiet for a daily
    // copy or a cold invocation. Keep every published parameter type intact.
    if #available(iOS 26.0, *), systemContext.currentMode == .background,
       systemContext.currentMode.canContinueInForeground,
       await IncomingSmsBridge.claimForegroundReturn(request: request) {
      if (try? IncomingSmsSpool.shared.observeHandoff(request: request, stage: .appReturnRequested)) == true {
        do { try await continueInForeground(alwaysConfirm: false) }
        catch {
          // A declined/unavailable presentation cannot roll back saved input
          // or change classification. Normal Finish/return still works.
          _ = try? IncomingSmsSpool.shared.observeHandoff(request: request, stage: .appReturnUnavailable)
        }
      }
      IncomingSmsBridge.notifyReady()
    }
    return .result(value: value)
  }
}

@available(iOS 16.0, *)
struct FinishPandaPaySmsWindowIntent: AppIntent {
  static var title: LocalizedStringResource = "Finish PandaPay SMS Window"
  static var openAppWhenRun = false
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Messages found", inputConnectionBehavior: .never) var found: Int
  @Parameter(title: "Find Messages limit is off", default: false, inputConnectionBehavior: .never) var limitOff: Bool
  @Parameter(title: "Search may be incomplete", default: false, inputConnectionBehavior: .never) var warning: Bool
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value = try IncomingSmsSpool.shared.finish(request: request, found: found, limitOff: limitOff, warning: warning)
    IncomingSmsBridge.notifyReady()
    return .result(value: value)
  }
}

/// Interactive history uses the same foreground completion contract as the
/// working probe. Keep the existing quiet Finish above for daily automations;
/// changing its mode would unexpectedly open PandaPay for existing schedules.
@available(iOS 16.0, *)
struct FinishPandaPayHistoryImportIntent: AppIntent {
  static var title: LocalizedStringResource = "Finish PandaPay History Import"
  static var description = IntentDescription("Finish the issued window and return to PandaPay. Use this at the end of an import started from PandaPay; use Finish PandaPay SMS Window for background automations.")
  static var openAppWhenRun = true
  @Parameter(title: "Import request", inputConnectionBehavior: .never) var request: String
  @Parameter(title: "Messages found", inputConnectionBehavior: .never) var found: Int
  @Parameter(title: "Find Messages limit is off", default: false, inputConnectionBehavior: .never) var limitOff: Bool
  @Parameter(title: "Search may be incomplete", default: false, inputConnectionBehavior: .never) var warning: Bool
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let value = try IncomingSmsSpool.shared.finish(request: request, found: found, limitOff: limitOff, warning: warning)
    IncomingSmsBridge.notifyReady()
    return .result(value: value)
  }
}

@available(iOS 16.0, *)
struct PreparePandaPaySmsCatchupIntent: AppIntent {
  static var title: LocalizedStringResource = "Prepare PandaPay SMS Catch-up"
  static var description = IntentDescription("Get the next issued receive-date window for the same history Shortcut. Does not search Messages or open PandaPay.")
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    do { return .result(value: try IncomingSmsSpool.shared.prepareCatchup() ?? "") }
    catch IncomingSmsError.inactive { return .result(value: "") }
  }
}

/// No raw message data is carried by URLs. Database work stays off the UI thread.
enum IncomingSmsBridge {
  private static var channel: FlutterMethodChannel?
  private static var pendingLaunch: SmsShortcutLaunch?
  private static var returned: [String: String]?
  private static var foregroundReturn: SmsShortcutForegroundReturn?
  private static let worker = DispatchQueue(label: "app.pandapay.sms-handoff", qos: .utility)

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "pandapay/ios_sms_intake", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "isForeground" { result(UIApplication.shared.applicationState == .active); return }
      if call.method == "takeShortcutReturn" { let value = returned; returned = nil; result(value); return }
      if call.method == "openSettings" {
        // Only the public own-app Settings destination is supported. Do not
        // invent private App-prefs URLs for Shortcuts' Advanced preferences.
        guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
        UIApplication.shared.open(url, options: [:]) { result($0) }
        return
      }
      if call.method == "resumeShortcut" {
        guard let attempt = args["attempt"] as? String, let launch = pendingLaunch,
              launch.attempt == attempt, returned == nil,
              UIApplication.shared.applicationState == .active else { result(false); return }
        worker.async {
          let stalled = args["stalled"] as? Bool == true
          let admitted = (try? IncomingSmsSpool.shared.observeHandoff(request: launch.request,
              stage: stalled ? .resumeStalled : .resumeRequested, expectedReceived: args["received"] as? Int)) == true
          DispatchQueue.main.async {
            // A callback, pause/account change or app switch can win while
            // the committed receipt is checked. Never reuse a different run.
            guard admitted, pendingLaunch?.token == launch.token, returned == nil,
                  UIApplication.shared.applicationState == .active else { result(false); return }
            foregroundReturn?.resumedRunner()
            UIApplication.shared.open(launch.resumeURL, options: [:]) { result($0) }
          }
        }
        return
      }
      if call.method == "runShortcut" {
        guard let name = args["name"] as? String, !name.isEmpty, name.utf8.count < 200,
              let request = args["request"] as? String, request.utf8.count < 4096 else {
          result(FlutterError(code: "invalid_request", message: "Check SMS Shortcut setup.", details: nil)); return
        }
        worker.async {
          do {
            _ = try IncomingSmsSpool.shared.boundary(request: request, end: false)
            let launch = try SmsShortcutLaunch(name: name, request: request)
            try IncomingSmsSpool.shared.observeHandoff(request: request, stage: .launchRequested)
            DispatchQueue.main.async {
              pendingLaunch = launch; returned = nil
              foregroundReturn = SmsShortcutForegroundReturn(request: request)
              UIApplication.shared.open(launch.url, options: [:]) { opened in
                if !opened { pendingLaunch = nil; foregroundReturn = nil }
                result(opened)
              }
            }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "stale_request", message: "Continue the current import from PandaPay.", details: nil)) }
          }
        }
        return
      }
      worker.async {
        do {
          let spool = IncomingSmsSpool.shared
          var value: Any?
          switch call.method {
          case "configure":
            guard let namespace = args["namespace"] as? String else { throw IncomingSmsError.invalid }
            value = try spool.configure(namespace: namespace, enabled: args["enabled"] as? Bool, reset: args["reset"] as? Bool ?? false, parserVersion: args["parserVersion"] as? Int ?? 0)
            if args["reset"] as? Bool == true || args["enabled"] as? Bool == false {
              DispatchQueue.main.async { pendingLaunch = nil; foregroundReturn = nil; returned = nil }
              notifyReady()
            }
          case "snapshot": value = try spool.snapshot()
          case "prepareCatchup": value = try spool.prepareCatchup()
          case "pending":
            guard let generation = args["generation"] as? String else { throw IncomingSmsError.invalid }
            value = try spool.pending(generation: generation)
          case "acknowledge":
            guard let generation = args["generation"] as? String, let outcomes = args["outcomes"] as? [[String: Any]] else { throw IncomingSmsError.invalid }
            try spool.acknowledge(generation: generation, outcomes: outcomes)
          case "createJob":
            guard let generation = args["generation"] as? String, let id = args["id"] as? String,
                  let kind = args["kind"] as? String, let zone = args["zone"] as? String,
                  let windows = args["windows"] as? [[String: String]] else { throw IncomingSmsError.invalid }
            // UI dates were selected in the device timezone; persist its IANA
            // identity instead of Dart's potentially ambiguous abbreviation.
            _ = zone
            try spool.createJob(generation: generation, id: id, kind: kind, zone: TimeZone.current.identifier, windows: windows,
                                replacingJobID: args["replacingJobID"] as? String)
            DispatchQueue.main.async { pendingLaunch = nil; foregroundReturn = nil; returned = nil }
          case "issue":
            guard let generation = args["generation"] as? String else { throw IncomingSmsError.invalid }
            value = try spool.issue(generation: generation)
          case "control":
            guard let generation = args["generation"] as? String, let command = args["command"] as? String else { throw IncomingSmsError.invalid }
            try spool.control(generation: generation, command: command)
            DispatchQueue.main.async { pendingLaunch = nil; foregroundReturn = nil; returned = nil }
          default: DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          // Return a classified error without SQLite paths or input content.
          DispatchQueue.main.async { result(FlutterError(code: "sms_intake_unavailable", message: (error as? IncomingSmsError)?.errorDescription ?? "Message intake is unavailable. Retry in PandaPay.", details: nil)) }
        }
      }
    }
  }

  static func notifyReady() {
    DispatchQueue.main.async { channel?.invokeMethod("ready", arguments: nil) }
  }

  @MainActor
  static func claimForegroundReturn(request: String) -> Bool {
    guard pendingLaunch?.request == request, returned == nil else { return false }
    return foregroundReturn?.claim(request: request, appIsActive: UIApplication.shared.applicationState == .active) == true
  }

  static func handleReturnURL(_ url: URL) -> Bool {
    guard SmsShortcutLaunch.isReturn(url) else { return false }
    if let value = pendingLaunch?.result(url) {
      let request = pendingLaunch!.request
      returned = value; pendingLaunch = nil; foregroundReturn = nil
      let stage: SmsHandoffStage = value["status"] == "success" ? .returnedSuccess : value["status"] == "cancel" ? .returnedCancel : .returnedError
      worker.async {
        _ = try? IncomingSmsSpool.shared.observeHandoff(request: request, stage: stage)
        notifyReady()
      }
    }
    return true
  }
}
#endif
