import Foundation
import Security

public final class TokenManager {
  private let service = "crm-helper"
  private let account = "pat"
  // The signed-in email is account identity, not a secret, so it lives in
  // UserDefaults rather than the keychain — but its lifecycle is tied to the
  // token (cleared on `deleteToken`) so the two never drift.
  private let emailKey = "signedInAccountEmail"

  public init() {}

  public func saveToken(_ token: String) {
    if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      deleteToken()
      return
    }
    let data = Data(token.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    var attrs = query
    attrs[kSecValueData as String] = data
    let status = SecItemAdd(attrs as CFDictionary, nil)
    #if DEBUG
      print("[TokenManager] PAT save status=\(status) characters=\(token.count)")
    #endif
  }

  public func deleteToken() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    saveAccountEmail(nil)
  }

  /// The email of the signed-in account, when known (set by the Google
  /// sign-in exchange). A manually pasted token leaves this `nil`.
  public func saveAccountEmail(_ email: String?) {
    let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      UserDefaults.standard.set(trimmed, forKey: emailKey)
    } else {
      UserDefaults.standard.removeObject(forKey: emailKey)
    }
  }

  public func readAccountEmail() -> String? {
    UserDefaults.standard.string(forKey: emailKey)
  }

  public func readToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: kCFBooleanTrue as Any,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }
}
