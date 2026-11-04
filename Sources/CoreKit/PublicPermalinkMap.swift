import Foundation

/// A public-website page scope derived from a CMS record — the bridge between
/// a CRM/CMS record and the www.envisioning.com page Plausible tracks for it.
public enum PublicPagePath: Sendable, Hashable {
  /// The full path is known (e.g. `/research/aegis/autonomous-vehicle`).
  case exact(String)
  /// One or more unknown segments: `*` matches exactly one path segment,
  /// `**` matches any suffix (e.g. `/research/*/autonomous-vehicle`).
  case wildcard(String)
  /// The root page plus every descendant (e.g. a research hub and all of its
  /// technology pages).
  case subtree(String)

  /// Whether a concrete page path (as returned by Plausible's `event:page`
  /// dimension) falls inside this scope. Pure string matching — used to
  /// distribute one breakdown query's rows to list rows client-side.
  public func matches(_ path: String) -> Bool {
    switch self {
    case .exact(let target):
      return Self.normalize(path) == Self.normalize(target)
    case .subtree(let root):
      let candidate = Self.normalize(path)
      let base = Self.normalize(root)
      if base == "/" { return true }
      return candidate == base || candidate.hasPrefix(base + "/")
    case .wildcard(let pattern):
      return Self.segmentsMatch(
        path: Self.segments(path), pattern: Self.segments(pattern))
    }
  }

  private static func normalize(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.isEmpty ? "/" : trimmed
  }

  private static func segments(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }

  private static func segmentsMatch(path: [String], pattern: [String]) -> Bool {
    func match(_ patternIndex: Int, _ pathIndex: Int) -> Bool {
      if patternIndex == pattern.count { return pathIndex == path.count }
      if pattern[patternIndex] == "**" {
        for skip in pathIndex...path.count where match(patternIndex + 1, skip) {
          return true
        }
        return false
      }
      guard pathIndex < path.count else { return false }
      guard pattern[patternIndex] == "*" || pattern[patternIndex] == path[pathIndex] else {
        return false
      }
      return match(patternIndex + 1, pathIndex + 1)
    }
    return match(0, 0)
  }
}

/// Resolves CMS records and list screens to public-website page scopes.
/// Seam for a future server-registry-published `publicPath` source — swap the
/// implementation, keep the call sites.
public protocol PublicPermalinkResolving: Sendable {
  /// The public page for a single record, or `nil` when the entity has no
  /// public page or the record lacks a slug (callers hide stats — fail closed).
  func pagePath(entityID: String, record: CRMRecord, hubSlug: String?) -> PublicPagePath?

  /// The scope covering every row of a list screen, used for the one
  /// breakdown query per screen. `nil` when the entity has no public pages.
  func sectionScope(entityID: String, hubSlug: String?) -> PublicPagePath?
}

/// INTERIM client-side map of CMS entity → www.envisioning.com path shape,
/// reverse-engineered from the public sitemaps. Only entities whose records
/// are *pages* appear here: much of the CMS (logos, testimonials, faqs,
/// partners, weblinks, deliverables) is page fragments with no URL of their
/// own, so there is no traffic to attribute and they resolve to nil.
///
/// This mapping duplicates routing knowledge the web repo already owns, and
/// it silently goes stale if a route changes — the registry should publish a
/// `publicPath` per entity instead, at which point this type is replaced by
/// a registry-driven `PublicPermalinkResolving` and deleted.
///
/// Unmapped and unverified so far: `newsletter` (`/newsletter/<nnn>-<slug>`
/// needs a partial-segment wildcard), `services`, `reports`, `tags`,
/// `technology_signals`. `events` and `signals_briefs` live on
/// signals.envisioning.com — a different Plausible site, not just a
/// different path.
public struct PublicPermalinkMap: PublicPermalinkResolving {
  public init() {}

  public func pagePath(
    entityID: String, record: CRMRecord, hubSlug: String?
  ) -> PublicPagePath? {
    guard let slug = Self.slug(of: record) else { return nil }
    switch entityID {
    case "research":
      return .subtree("/research/\(slug)")
    case "technologies":
      if let hubSlug, !hubSlug.isEmpty {
        return .exact("/research/\(hubSlug)/\(slug)")
      }
      return .wildcard("/research/*/\(slug)")
    case "work":
      return .exact("/services/impact/\(slug)")
    case "methodology":
      return .exact("/methodology/\(slug)")
    default:
      return nil
    }
  }

  public func sectionScope(entityID: String, hubSlug: String?) -> PublicPagePath? {
    switch entityID {
    case "research":
      return .subtree("/research")
    case "technologies":
      if let hubSlug, !hubSlug.isEmpty {
        return .wildcard("/research/\(hubSlug)/*")
      }
      return .wildcard("/research/*/*")
    case "work":
      return .wildcard("/services/impact/*")
    case "methodology":
      return .wildcard("/methodology/*")
    default:
      return nil
    }
  }

  private static func slug(of record: CRMRecord) -> String? {
    guard
      let slug = record["slug"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !slug.isEmpty
    else { return nil }
    return slug
  }
}
