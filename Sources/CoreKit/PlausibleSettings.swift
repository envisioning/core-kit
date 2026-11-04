import Foundation
import Security

/// Settings for the Plausible website-stats integration. Mirrors
/// `ContextSyncSettings`: non-secrets in `UserDefaults`, the API key in the
/// Keychain (service "crm-helper"). `config()` fails closed — any missing or
/// invalid piece disables stats everywhere.
public enum PlausibleSettings {
  public static let siteIDKey = "plausibleSiteID"
  public static let baseURLKey = "plausibleBaseURL"
  public static let statsEnabledKey = "plausibleStatsEnabled"

  public static let defaultSiteID = "envisioning.com"
  public static let defaultBaseURLString = "https://plausible.io"

  private static let apiKeyService = "crm-helper"
  private static let apiKeyAccount = "plausible-api-key"

  /// Plausible `site_id` — the domain the site was registered as (may be the
  /// `www.` form; the Test Connection button in Settings is how that gets
  /// resolved).
  public static var siteID: String {
    get { UserDefaults.standard.string(forKey: siteIDKey) ?? defaultSiteID }
    set { UserDefaults.standard.set(newValue, forKey: siteIDKey) }
  }

  /// API host — plausible.io by default, overridable for self-hosted.
  public static var baseURLString: String {
    get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURLString }
    set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
  }

  /// Master toggle for the stats UI. Defaults to on — the feature stays
  /// invisible until an API key is saved regardless.
  public static var statsEnabled: Bool {
    get { (UserDefaults.standard.object(forKey: statsEnabledKey) as? Bool) ?? true }
    set { UserDefaults.standard.set(newValue, forKey: statsEnabledKey) }
  }

  public static func saveAPIKey(_ key: String) {
    saveSecret(key, service: apiKeyService, account: apiKeyAccount)
  }

  public static func readAPIKey() -> String? {
    readSecret(service: apiKeyService, account: apiKeyAccount)
  }

  /// The effective client configuration, or `nil` when stats are disabled or
  /// any required piece is missing/invalid (fail closed).
  public static func config() -> PlausibleConfig? {
    guard statsEnabled else { return nil }
    guard
      let key = readAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else { return nil }
    let site = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !site.isEmpty else { return nil }
    guard
      let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = base.scheme, scheme == "https" || scheme == "http"
    else { return nil }
    return PlausibleConfig(baseURL: base, siteID: site, apiKey: key)
  }

  private static func saveSecret(_ token: String, service: String, account: String) {
    if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      deleteSecret(service: service, account: account)
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
    SecItemAdd(attrs as CFDictionary, nil)
  }

  private static func readSecret(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: kCFBooleanTrue as Any,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteSecret(service: String, account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
