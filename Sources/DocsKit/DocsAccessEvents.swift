import Foundation

/// One row of a document's access log: a view, a click, a download, a
/// comment, a signature. Read through Starlings' Worker, a row also carries
/// where the visitor was and the contact their address matched; read from
/// Docs directly, those fields are nil. The visitor's IP never leaves Docs.
public struct DocsAccessEvent: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let actor: String?
  /// `guest`, `staff`, `agent` or `system`.
  public let actorKind: String
  /// `view`, `click`, `download`, `annotate`, `sign`, `decline`, `edit`, `share`.
  public let kind: String
  public let createdAt: String
  public let timezone: String?
  public let city: String?
  public let country: String?
  /// The link a `click` followed.
  public let href: String?
  public let actorName: String?
  public let actorOrganization: String?

  public init(
    id: String, actor: String?, actorKind: String, kind: String, createdAt: String, timezone: String? = nil,
    city: String? = nil, country: String? = nil, href: String? = nil, actorName: String? = nil,
    actorOrganization: String? = nil
  ) {
    self.id = id
    self.actor = actor
    self.actorKind = actorKind
    self.kind = kind
    self.createdAt = createdAt
    self.timezone = timezone
    self.city = city
    self.country = country
    self.href = href
    self.actorName = actorName
    self.actorOrganization = actorOrganization
  }

  /// "Kapil Raghuraman (EY)" when a contact matched, else the address.
  public var who: String {
    if let actorName, !actorName.isEmpty {
      return actorOrganization.map { "\(actorName) (\($0))" } ?? actorName
    }
    return actor ?? "Anonymous"
  }

  /// "Opened", or "Clicked example.com" for a link click.
  public var kindLabel: String {
    switch kind {
    case "view": return "Opened"
    case "click":
      guard let href else { return "Clicked a link" }
      guard let host = URL(string: href)?.host else { return "Clicked \(href)" }
      return "Clicked \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
    case "download": return "Downloaded"
    case "annotate": return "Commented"
    case "sign": return "Signed"
    case "decline": return "Declined"
    case "edit": return "Edited"
    case "share": return "Shared"
    default: return kind.capitalized
    }
  }

  /// When it happened. Docs writes SQLite's `datetime('now')` (UTC, no zone);
  /// an ISO time reads too.
  public var date: Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt) { return date }
    let sqlite = DateFormatter()
    sqlite.locale = Locale(identifier: "en_US_POSIX")
    sqlite.timeZone = TimeZone(identifier: "UTC")
    sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return sqlite.date(from: createdAt)
  }
}

public struct DocsAccessEventList: Codable, Sendable {
  public let events: [DocsAccessEvent]
}

/// Guest views of a document, for its meta line: how many people opened it
/// and the newest of them. Nil when no guest has. Rows arrive newest first.
public struct DocsGuestViews: Equatable, Sendable {
  public let people: Int
  public let latest: DocsAccessEvent

  public init?(_ events: [DocsAccessEvent]) {
    let views = events.filter { $0.actorKind == "guest" && $0.kind == "view" }
    guard let latest = views.first else { return nil }
    self.people = Set(views.map { $0.actor?.lowercased() ?? "" }).count
    self.latest = latest
  }
}
