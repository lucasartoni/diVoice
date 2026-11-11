import DiVoiceEngine
import Foundation
import Security

enum Keys {
  /// The same Keychain item the app writes (KeyStore).
  static let keychainService = "app.wibo.divoice"

  /// The key saved in diVoice (macOS asks whether divoice-bench may read it), so the bench
  /// measures what the app uses; otherwise `MISTRAL_API_KEY` / `OPENAI_API_KEY`.
  /// The key is never printed.
  static func key(_ provider: ProviderID) -> String? {
    if let saved = keychain(provider) { return saved }
    let variable = "\(provider.rawValue.uppercased())_API_KEY"
    let value = ProcessInfo.processInfo.environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  private static func keychain(_ provider: ProviderID) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "provider-key.\(provider.rawValue)",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
