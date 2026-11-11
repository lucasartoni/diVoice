import DiVoiceEngine
import Foundation
import Security

extension Notification.Name {
  /// An API key was saved or removed.
  static let diVoiceKeysChanged = Notification.Name("app.wibo.divoice.keysChanged")
}

/// The providers' API keys, in this Mac's Keychain. They go only to the provider.
///
/// The items belong to the app's signature: updates signed by the same team read them
/// without any Keychain prompt.
enum KeyStore {
  private static let service = "app.wibo.divoice"

  private static func account(_ provider: ProviderID) -> String {
    "provider-key.\(provider.rawValue)"
  }

  static func key(_ provider: ProviderID) -> String? {
    read(account(provider))
  }

  static func hasKey(_ provider: ProviderID) -> Bool {
    key(provider) != nil
  }

  /// The last characters, to show which key is saved without showing it.
  static func masked(_ provider: ProviderID) -> String? {
    key(provider).map { "••••" + $0.suffix(4) }
  }

  @discardableResult
  static func save(_ key: String, for provider: ProviderID) -> Bool {
    let saved = write(account(provider), key, label: "diVoice: \(provider.displayName) API key")
    NotificationCenter.default.post(name: .diVoiceKeysChanged, object: nil)
    return saved
  }

  static func remove(_ provider: ProviderID) {
    delete(account(provider))
    NotificationCenter.default.post(name: .diVoiceKeysChanged, object: nil)
  }

  // MARK: Organization

  private static let orgAccount = "org-token"

  /// The member token for the organization's server, from joining with an invite.
  static var orgToken: String? { read(orgAccount) }

  @discardableResult
  static func saveOrgToken(_ token: String) -> Bool {
    write(orgAccount, token, label: "diVoice: organization token")
  }

  static func removeOrgToken() {
    delete(orgAccount)
  }

  private static let setupSecretAccount = "org-setup-secret"

  /// The SERVER_SECRET generated for a new organization's server, kept until its first admin
  /// is created, so closing the window halfway through doesn't lose it.
  static var setupSecret: String? { read(setupSecretAccount) }

  @discardableResult
  static func saveSetupSecret(_ secret: String) -> Bool {
    write(setupSecretAccount, secret, label: "diVoice: new organization's secret")
  }

  static func removeSetupSecret() {
    delete(setupSecretAccount)
  }

  // MARK: Keychain

  private static func read(_ account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    else { return nil }
    return value
  }

  private static func write(_ account: String, _ value: String, label: String) -> Bool {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }
    delete(account)
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrLabel as String: label,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: Data(value.utf8),
    ]
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  private static func delete(_ account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
