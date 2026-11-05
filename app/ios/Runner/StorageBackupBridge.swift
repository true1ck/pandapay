import Flutter
import Foundation

/// Marks the account-data folder (Application Support/PandaPay) as excluded
/// from iCloud and computer backups. Registered on the main engine and on the
/// headless background engine, because both open the database.
enum StorageBackupBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "pandapay/storage", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "backup_exclusion_failed", message: nil, details: nil))
      }
    }
  }
}
