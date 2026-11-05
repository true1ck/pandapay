#if !PANDAPAY_DEVICE_IMPORT_PROBE
import BackgroundTasks
import Flutter
import UIKit

/// Background runtime belongs to iOS; SMS authority remains in the durable
/// spool. Warm tasks use the serial foreground drainer. Cold tasks use the
/// same Dart capture/receipt pipeline in a headless engine, without auth/HTTP.
enum SmsImportBackgroundHost {
  static let processingID = "app.pandapay.pandapay.sms-processing"
  static let continuedID = "app.pandapay.pandapay.sms-import"
  private static var channel: FlutterMethodChannel?
  private static var engine: FlutterEngine?
  private static var backgroundChannel: FlutterMethodChannel?
  private static var task: BGTask?
  private static var running = false
  private static var expired = false
  private static var submitted = false
  private static var continuedSubmitted = false
  static var hasContinuedRuntime: Bool { continuedSubmitted }
  /// True only once iOS has actually started the continued-processing task
  /// (and so shows its own progress). A submitted request that iOS never
  /// starts must not hide the Lock Screen progress.
  static var continuedTaskRunning: Bool {
    if #available(iOS 26.0, *) { return task is BGContinuedProcessingTask }
    return false
  }
  private static var shortTask: UIBackgroundTaskIdentifier = .invalid
  private static var check: DispatchWorkItem?
  private static let worker = DispatchQueue(label: "app.pandapay.sms-background", qos: .utility)

  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: .main) { start($0) }
    if #available(iOS 26.0, *) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: .main) { start($0) }
    }
  }

  static func attach(_ value: FlutterMethodChannel) { channel = value }

  /// Only the app's explicit Start/Resume action requests continued runtime.
  /// System denial leaves durable work scheduled for a later processing task.
  static func beginUserImport() {
    guard UIApplication.shared.applicationState == .active else { return }
    if #available(iOS 26.0, *), !continuedSubmitted {
      let request = BGContinuedProcessingTaskRequest(identifier: continuedID,
        title: "Importing SMS history", subtitle: "Receiving and processing messages")
      request.strategy = .fail
      do { try BGTaskScheduler.shared.submit(request); continuedSubmitted = true }
      catch { /* Background processing remains the fallback. */ }
    }
    workArrived()
  }

  static func workArrived() {
    DispatchQueue.main.async {
      guard check == nil else { return }
      let item = DispatchWorkItem {
        check = nil
        if task != nil || shortTask != .invalid { updateProgress(); drain(); return }
        scheduleFallback()
        // Older iOS versions can finish an admitted batch immediately with
        // finite UIKit runtime while the scheduled task covers cold recovery.
        if channel != nil && UIApplication.shared.applicationState == .background {
          expired = false
          shortTask = UIApplication.shared.beginBackgroundTask(withName: "Process saved SMS") {
            expired = true
            channel?.invokeMethod("expireBackground", arguments: nil)
            if !running { complete(false) }
          }
          if shortTask != .invalid { drain() }
        }
      }
      check = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
  }

  private static func scheduleFallback() {
    guard !submitted else { return }
    worker.async {
      let pending = (try? IncomingSmsSpool.shared.snapshot()["pending"] as? Int) ?? 0
      guard pending > 0 else { return }
      DispatchQueue.main.async {
        guard !submitted else { return }
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request); submitted = true }
        catch { /* Resume/next capture retries scheduling. Never lose input. */ }
      }
    }
  }

  private static func start(_ value: BGTask) {
    if value.identifier == processingID { submitted = false }
    if let current = task {
      // Two tasks can overlap (a scheduled processing task and the import's
      // continued task). The import's task takes over; nothing has failed.
      if #available(iOS 26.0, *), value is BGContinuedProcessingTask, !(current is BGContinuedProcessingTask), !running {
        current.setTaskCompleted(success: true)
        task = nil
      } else {
        value.setTaskCompleted(success: true)
        return
      }
    }
    task = value; expired = false
    if #available(iOS 26.0, *), let continued = value as? BGContinuedProcessingTask {
      continued.progress.totalUnitCount = 1000
      continued.progress.completedUnitCount = 0
    }
    value.expirationHandler = {
      DispatchQueue.main.async {
        guard task === value else { return }
        expired = true
        // The Shortcut does the reading and keeps going without this task.
        // Saved messages stay queued and are processed on the next launch or
        // background run, so the import is not paused and nothing is lost.
        if #available(iOS 26.0, *), let continued = value as? BGContinuedProcessingTask {
          continued.updateTitle("Importing SMS history", subtitle: "Continuing in Shortcuts")
        }
        channel?.invokeMethod("expireBackground", arguments: nil)
        backgroundChannel?.invokeMethod("stop", arguments: nil)
        // A committed batch is never abandoned by destroying its engine.
        if !running { complete(true) }
      }
    }
    drain()
  }

  private static func drain() {
    guard task != nil || shortTask != .invalid, !running, !expired else { return }
    running = true
    if let channel {
      channel.invokeMethod("processBackground", arguments: nil) { response in
        if let result = response as? [String: Any], result["unavailable"] as? Bool != true { drained(result["success"] as? Bool == true) }
        else { startHeadless() }
      }
    } else { startHeadless() }
  }

  private static func startHeadless() {
    guard !expired else { running = false; complete(false); return }
    if let backgroundChannel {
      backgroundChannel.invokeMethod("drain", arguments: nil) { response in
        drained((response as? [String: Any])?["success"] as? Bool == true)
      }
      return
    }
    let created = FlutterEngine(name: "pandapay-sms-background", project: nil, allowHeadlessExecution: true)
    engine = created
    // Start the engine first: registering handlers on an engine that is not
    // running aborts the app ("Start the background SMS engine before
    // registering handlers").
    guard created.run(withEntrypoint: "iosSmsBackgroundMain") else {
      running = false
      complete(false)
      return
    }
#if targetEnvironment(simulator)
    SimulatorPluginRegistrant.register(with: created)
#else
    GeneratedPluginRegistrant.register(with: created)
#endif
    StorageBackupBridge.register(messenger: created.binaryMessenger)
    let bridge = FlutterMethodChannel(name: "pandapay/ios_sms_background", binaryMessenger: created.binaryMessenger)
    backgroundChannel = bridge
    bridge.setMethodCallHandler { call, result in
      if call.method == "ready" {
        result(nil)
        if expired { running = false; complete(false); return }
        bridge.invokeMethod("drain", arguments: nil) { response in
          drained((response as? [String: Any])?["success"] as? Bool == true)
        }
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      worker.async {
        do {
          let spool = IncomingSmsSpool.shared
          let value: Any?
          switch call.method {
          case "snapshot":
            var snapshot = try spool.snapshot()
            snapshot["clientVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            value = snapshot
          case "pending": value = try spool.pending(generation: args["generation"] as? String ?? "")
          case "acknowledge":
            try spool.acknowledge(generation: args["generation"] as? String ?? "",
              outcomes: args["outcomes"] as? [[String: Any]] ?? [])
            SmsImportLiveActivityHost.refresh()
            value = nil
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "sms_background", message: "Saved messages remain queued.", details: nil)) }
        }
      }
    }
  }

  private static func drained(_ success: Bool) {
    running = false
    worker.async {
      let snapshot = try? IncomingSmsSpool.shared.snapshot()
      let progress = try? IncomingSmsSpool.shared.importProgress()
      DispatchQueue.main.async {
        guard task != nil || shortTask != .invalid else { return }
        SmsImportLiveActivityHost.refresh()
        if expired { complete(true); return }
        if !success { complete(false); return }
        if #available(iOS 26.0, *), task is BGContinuedProcessingTask,
           ["paused", "stopped"].contains(progress?["state"] as? String ?? "") {
          complete(true); return
        }
        let pending = snapshot?["pending"] as? Int ?? 0
        if pending > 0 { workArrived(); return }
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask,
           progress?["state"] as? String == "importing" {
          if let progress { report(continued, progress) }
          // The current Shortcut is still producing input. Each capture wakes
          // the same admitted task; no new workflow or request is issued.
          return
        }
        complete(true)
      }
    }
  }

  private static func updateProgress() {
    guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
    worker.async {
      guard let progress = try? IncomingSmsSpool.shared.importProgress() else { return }
      DispatchQueue.main.async {
        guard task === continued else { return }
        report(continued, progress)
      }
    }
  }

  /// iOS ends a continued task whose progress stops moving. A month can hold
  /// hundreds of messages, so each message moves the bar a little within its
  /// month (approaching, never reaching, the next month's mark).
  @available(iOS 26.0, *)
  private static func report(_ continued: BGContinuedProcessingTask, _ progress: [String: Any]) {
    let total = max(progress["total"] as? Int ?? 1, 1), done = progress["done"] as? Int ?? 0
    let current = Double(progress["current_received"] as? Int ?? 0)
    let within = Int64(1000 * current / (current + 300))
    continued.progress.totalUnitCount = Int64(total) * 1000
    continued.progress.completedUnitCount = max(continued.progress.completedUnitCount,
                                                min(Int64(done) * 1000 + within, Int64(total) * 1000))
    let title = progress["state"] as? String == "processing" ? "Processing saved messages" : "Importing SMS history"
    continued.updateTitle(title, subtitle: "\(progress["received"] as? Int ?? 0) saved · \(progress["processed"] as? Int ?? 0) processed")
  }

  private static func complete(_ success: Bool) {
    if #available(iOS 26.0, *), success, let continued = task as? BGContinuedProcessingTask {
      continued.progress.completedUnitCount = continued.progress.totalUnitCount
    }
    task?.setTaskCompleted(success: success)
    if shortTask != .invalid {
      UIApplication.shared.endBackgroundTask(shortTask)
      shortTask = .invalid
    }
    task = nil; continuedSubmitted = false
    backgroundChannel?.setMethodCallHandler(nil)
    backgroundChannel = nil
    engine?.destroyContext(); engine = nil
    if success { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingID); submitted = false }
    else { scheduleFallback() }
  }
}
#endif
