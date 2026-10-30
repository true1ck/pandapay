import Foundation

/// A callback only signals that Shortcuts returned. Native window receipts,
/// never this URL, determine whether another window may be issued.
struct SmsShortcutLaunch {
  let token = UUID().uuidString
  let attempt: String
  let name: String
  let request: String

  init(name: String, request: String) throws {
    guard let data = request.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let attempt = value["attempt"] as? String, !attempt.isEmpty else { throw IncomingSmsError.invalid }
    self.name = name; self.request = request; self.attempt = attempt
  }

  var url: URL {
    func callback(_ status: String) -> String {
      var parts = URLComponents()
      parts.scheme = "pandapay"; parts.host = "sms-import"; parts.path = "/\(status)"
      parts.queryItems = [URLQueryItem(name: "token", value: token)]
      return parts.url!.absoluteString
    }
    var parts = URLComponents()
    parts.scheme = "shortcuts"; parts.host = "x-callback-url"; parts.path = "/run-shortcut"
    parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
                       URLQueryItem(name: "text", value: request), URLQueryItem(name: "x-success", value: callback("success")),
                       URLQueryItem(name: "x-cancel", value: callback("cancel")), URLQueryItem(name: "x-error", value: callback("error"))]
    return parts.url!
  }

  // Apple's public launch-last-state URL. It does not start a second workflow,
  // replace the request/nonce or carry message data.
  var resumeURL: URL { URL(string: "shortcuts://")! }

  static func isReturn(_ url: URL) -> Bool { url.scheme == "pandapay" && url.host == "sms-import" }

  func result(_ url: URL) -> [String: String]? {
    guard Self.isReturn(url), ["/success", "/cancel", "/error"].contains(url.path),
          let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.queryItems?.filter({ $0.name == "token" }).count == 1,
          parts.queryItems?.first(where: { $0.name == "token" })?.value == token else { return nil }
    // Deliberately ignore Shortcuts' result/errorMessage: it can contain input.
    return ["status": String(url.path.dropFirst()), "attempt": attempt]
  }
}

/// One foreground return for each interactive launch/runner-resume burst.
/// Daily/manual/cold executions have no budget and stay quiet. This policy
/// carries no SMS content and never represents a successful import receipt.
struct SmsShortcutForegroundReturn {
  let request: String
  private var available = true

  init(request: String) { self.request = request }

  mutating func claim(request: String, appIsActive: Bool) -> Bool {
    guard self.request == request, available, !appIsActive else { return false }
    available = false
    return true
  }

  mutating func resumedRunner() { available = true }
}
