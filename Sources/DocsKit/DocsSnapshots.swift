import Foundation

/// Where `DocsClient` keeps the last good body of every list read, so a
/// screen paints what it last knew before Docs answers (meet/docs/CACHING.md).
/// The host owns the tiers, the owner scoping and the lifetime — Meet hands
/// in its `SnapshotStore`; a client with no store reads live only.
///
/// Every key is `docs/<name>`, so one invalidation of `DocsSnapshotKey.prefix`
/// after a write takes every Docs list with it.
public protocol DocsSnapshotStore: Sendable {
  /// The last saved body for `key`, or nil when nothing usable exists.
  func load(key: String) -> Data?
  /// The body that just came back for `key`.
  func save(_ data: Data, key: String)
  /// Every key under `prefix` (`docs`, so `docs/...`) is stale: a document
  /// was written.
  func invalidate(prefix: String)
}

/// The keys the client snapshots under. The same names the web keeps
/// (`DOCS_SNAPSHOT` in meet/web/src/docs.ts).
public enum DocsSnapshotKey {
  /// The prefix every key sits under, without its slash — what a host's
  /// prefix invalidation takes.
  public static let prefix = "docs"
  public static let summary = "docs/summary"
  /// The workspace's categories, in rail order.
  public static let categories = "docs/categories"
  public static let written = "docs/written"
  static let documents = "docs/documents"
}

/// One list read of `/api/docs`, as a value: the request it makes and the
/// key it is kept under. `DocsClient.documents(_:)` reads it live;
/// `DocsClient.cachedDocuments(_:)` answers from the store without a request.
public enum DocsListRead: Hashable, Sendable {
  /// Newest documents anywhere; the Docs block's "Recent".
  case recent(limit: Int = 30)
  /// Everything the host wrote (`source=native`), newest first — what a
  /// rail's By project / By lead groups are built from.
  case written(limit: Int = 200)
  /// Everything about one subject, newest first.
  case about(DocsSubject, limit: Int = 100)
  /// Documents directly in one folder, newest first.
  case inFolder(String, limit: Int = 200)
  /// Documents anywhere under a folder, newest first.
  case underPrefix(String, limit: Int = 200)
  /// One category, any source. Any id the workspace owns.
  case category(DocsCategory, limit: Int = 200)
  /// One category on one half of the rail: `source=` narrows to the half's
  /// systems, so Core's briefs and a person's briefs are two lists.
  case categoryOnHalf(DocsCategory, DocsRailHalf, limit: Int = 200)
  /// Link saves (meet#345), newest first. Marked by `source_kind`, not a
  /// category.
  case links(limit: Int = 200)
  /// Documents nobody filed (meet#376): native, not a link save, no
  /// category, no subject, directly in `/` or `/work`.
  case unfiled(limit: Int = 200)

  var query: [(String, String)] {
    switch self {
    case .recent(let limit):
      [("limit", String(limit))]
    case .written(let limit):
      [("source", "native"), ("limit", String(limit))]
    case .about(let subject, let limit):
      [("subject", subject.ref), ("limit", String(limit))]
    case .inFolder(let path, let limit):
      [("folder", path), ("limit", String(limit))]
    case .underPrefix(let path, let limit):
      [("prefix", path), ("limit", String(limit))]
    case .category(let category, let limit):
      [("category", category.rawValue), ("limit", String(limit))]
    case .categoryOnHalf(let category, let half, let limit):
      [("category", category.rawValue), ("source", half.sources.joined(separator: ",")), ("limit", String(limit))]
    case .links(let limit):
      [("source", "native"), ("source_kind", DocsLinks.sourceKind), ("limit", String(limit))]
    case .unfiled(let limit):
      [("unfiled", "1"), ("limit", String(limit))]
    }
  }

  /// `docs/documents?<query>` — one key per exact list, like the web's
  /// `documentsSnapshotKey`. `written` keeps its own name so the rail and
  /// the web share it.
  public var snapshotKey: String {
    if case .written(let limit) = self, limit == 200 { return DocsSnapshotKey.written }
    let pairs = query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    return "\(DocsSnapshotKey.documents)?\(pairs)"
  }
}
