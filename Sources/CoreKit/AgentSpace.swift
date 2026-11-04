import Foundation

/// A data space published by the Core backend. The same registry-driven client
/// and UI serve every space; only the API path prefix and a few labels differ.
///
/// - `crm`: the sales/accounts CRM (the original, default surface).
/// - `cms`: website content management (technologies, research, work, …).
///
/// The backend selects the registry per space by path: CRM lives at
/// `/api/agent/*`, CMS at `/api/agent/cms/*`. Record CRUD paths come from the
/// registry itself, so only the fixed `meta`/`dashboard`/`search` endpoints and
/// display copy are space-derived here.
public enum AgentSpace: String, CaseIterable, Codable, Sendable, Identifiable {
  case crm
  case cms

  public var id: String { rawValue }

  /// Path prefix for this space's agent endpoints. CRM keeps the original
  /// `/api/agent` root; other spaces nest under it (`/api/agent/cms`).
  public var apiPrefix: String {
    switch self {
    case .crm: "/api/agent"
    case .cms: "/api/agent/cms"
    }
  }

  /// Human-readable name for this space, shown everywhere it surfaces — the
  /// picker, the home navigation title, and loading/search copy (e.g. "Loading
  /// Contacts…", "Search all Website"). "Core" names the app, never a space.
  public var title: String {
    switch self {
    case .crm: "Contacts"
    case .cms: "Website"
    }
  }

  /// SF Symbol representing this space in the picker and the toolbar switcher.
  public var symbol: String {
    switch self {
    case .crm: "person.2"
    case .cms: "globe"
    }
  }

  /// The other space. The switch is binary, so this is the toggle target.
  public var toggled: AgentSpace {
    switch self {
    case .crm: .cms
    case .cms: .crm
    }
  }

  /// Whether this space publishes the CRM-only aggregate dashboard endpoint.
  public var hasDashboard: Bool { self == .crm }

  /// Whether this space publishes the multi-entity `/search` endpoint.
  public var hasGlobalSearch: Bool { true }
}

/// Persisted selection of the active space, shared across the app via the same
/// `UserDefaults` key `@AppStorage` uses.
public enum AgentSpaceSettings {
  public static let defaultsKey = "selectedAgentSpace"

  public static var selected: AgentSpace {
    get {
      let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
      return AgentSpace(rawValue: raw) ?? .crm
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }
}
