import CryptoKit
import Foundation
import Security

/// Where the spool key lives. The Keychain implementation is the shipping one;
/// tests substitute a memory store so they do not depend on a keychain.
protocol SpoolKeyStore {
  /// The stored key, or nil when none exists. Throws when the store cannot be
  /// read right now (for example before the first unlock after a reboot).
  func read() throws -> Data?
  /// Stores a key only if none exists. Returns false when one already did.
  func add(_ key: Data) throws -> Bool
  func delete()
}

struct KeychainSpoolKeyStore: SpoolKeyStore {
  private let service = "app.pandapay.spool"
  private let account = "body-key.v1"

  private var identity: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  func read() throws -> Data? {
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw IncomingSmsError.keyUnavailable }
    return data
  }

  func add(_ key: Data) throws -> Bool {
    var attributes = identity
    attributes[kSecValueData as String] = key
    // Usable after the first unlock (Shortcut captures run while the phone is
    // locked), never synced and never restored onto another device.
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    attributes[kSecAttrSynchronizable as String] = false
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw IncomingSmsError.keyUnavailable }
    return true
  }

  func delete() {
    SecItemDelete(identity as CFDictionary)
  }
}

/// Encrypts SMS text at rest in the native spool (AES-256-GCM, CryptoKit).
/// The key never leaves the Keychain item. Format: `v1:` + base64(nonce,
/// ciphertext, tag). The dedupe fingerprints keep hashing the plaintext
/// before it is sealed.
enum SpoolCipher {
  static var keyStore: SpoolKeyStore = KeychainSpoolKeyStore()
  private static let prefix = "v1:"
  private static let context = Data("pandapay.spool.text.v1".utf8)

  static func isSealed(_ stored: String) -> Bool { stored.hasPrefix(prefix) }

  static func seal(_ text: String) throws -> String {
    let box = try AES.GCM.seal(Data(text.utf8), using: try key(create: true), authenticating: context)
    guard let combined = box.combined else { throw IncomingSmsError.cipher }
    return prefix + combined.base64EncodedString()
  }

  static func open(_ stored: String) throws -> String {
    guard isSealed(stored), let data = Data(base64Encoded: String(stored.dropFirst(prefix.count))) else {
      throw IncomingSmsError.cipher
    }
    let sealedBox: AES.GCM.SealedBox
    let plain: Data
    do {
      sealedBox = try AES.GCM.SealedBox(combined: data)
      plain = try AES.GCM.open(sealedBox, using: try key(create: false), authenticating: context)
    } catch let error as IncomingSmsError {
      throw error
    } catch {
      throw IncomingSmsError.cipher
    }
    guard let text = String(data: plain, encoding: .utf8) else { throw IncomingSmsError.cipher }
    return text
  }

  /// Reads a stored column. Text that was never sealed (a spool written by a
  /// build that predates encryption) is returned unchanged so it is still
  /// processed rather than stranded.
  static func openStored(_ stored: String) throws -> String {
    isSealed(stored) ? try open(stored) : stored
  }

  /// Called after the spool is emptied (sign-out, account change, disable).
  /// Anything still sealed with this key becomes unreadable.
  static func destroyKey() {
    keyStore.delete()
  }

  private static func key(create: Bool) throws -> SymmetricKey {
    if let data = try keyStore.read() {
      guard data.count == 32 else { throw IncomingSmsError.keyUnavailable }
      return SymmetricKey(data: data)
    }
    // A missing key cannot decrypt anything: reading must not invent one.
    guard create else { throw IncomingSmsError.cipher }
    let fresh = SymmetricKey(size: .bits256)
    let raw = fresh.withUnsafeBytes { Data($0) }
    if try keyStore.add(raw) { return fresh }
    // Another process created it first; use theirs.
    guard let existing = try keyStore.read(), existing.count == 32 else { throw IncomingSmsError.keyUnavailable }
    return SymmetricKey(data: existing)
  }
}
