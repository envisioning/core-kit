import Foundation

/// Single source of truth for the CRM backend base URL, shared by both apps.
///
/// Production is the default. A persisted override (used by the macOS app's
/// developer-facing Base URL field for staging) lives under one well-known
/// `UserDefaults` key. Every client and web-link builder resolves through
/// `ServerConfig.baseURL` so the two apps can never drift onto different hosts.
public enum ServerConfig {
  public static let productionURL = URL(string: "https://core.envisioning.com")!

  /// The public marketing/www site that hosts read-only share pages. Notes
  /// ("Docs") get a public viewer at `/private/docs/<id>` there — a different
  /// host from the authenticated CRM (`baseURL`), so it is resolved separately.
  public static let publicSiteURL = URL(string: "https://www.envisioning.com")!

  /// CRM entity id → www share-page path. Only entities with a read-only public
  /// viewer appear here; the record id *is* the capability token for that page
  /// (see the core `/api/public/<…>/[id]` routes). Mirrors the web
  /// `/private/<path>/<id>` routes — one source of truth for the mapping. If the
  /// registry ever publishes a per-entity public path, resolve through that and
  /// delete this map.
  private static let publicSharePaths: [String: String] = [
    "notes": "private/docs",
    "offers": "private/offer",
  ]

  /// Public share link for a CRM record, or `nil` when the entity has no public
  /// viewer or the record has no id — callers hide the affordance and fail closed.
  public static func publicShareURL(entityID: String, recordID: String) -> URL? {
    guard !recordID.isEmpty, let path = publicSharePaths[entityID] else { return nil }
    return publicSiteURL.appending(path: path).appending(path: recordID)
  }

  private static let overrideKey = "baseURLString"

  /// Persisted base-URL override (e.g. a staging host), or `nil` for production.
  public static var baseURLOverride: String? {
    get {
      let stored = UserDefaults.standard.string(forKey: overrideKey)
      return stored?.isEmpty == false ? stored : nil
    }
    set {
      let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let trimmed, !trimmed.isEmpty {
        UserDefaults.standard.set(trimmed, forKey: overrideKey)
      } else {
        UserDefaults.standard.removeObject(forKey: overrideKey)
      }
    }
  }

  /// The effective base URL: the persisted override if it parses, else production.
  public static var baseURL: URL {
    if let baseURLOverride, let url = URL(string: baseURLOverride) {
      return url
    }
    return productionURL
  }

  public static var baseURLString: String { baseURL.absoluteString }

  /// Host for display (e.g. "core.envisioning.com").
  public static var host: String { baseURL.host() ?? productionURL.host()! }

  public static var isProduction: Bool { baseURL == productionURL }
}
