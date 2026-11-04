import Foundation

// The browser's half of the wire contract: folders, categories, the sidebar
// summary, grants and signature requests. Same rule as DocsModels: match
// `docs/packages/contracts`, don't invent.

/// What a document *is*: the id of a category the workspace owns. Categories
/// are data, not a closed list — a new install has none, and people add,
/// rename, reorder and delete them (`DocsCategoryInfo`). The id is a slug
/// fixed at creation, so a rename changes the label and never the id.
///
/// A value, not an enum: an id this build has never seen decodes like any
/// other, so one new category cannot break a whole document list. The label
/// comes from Docs (`DocsCategoryInfo.label`, `DocsSummary.CategoryCount.label`),
/// never from the id.
public struct DocsCategory: RawRepresentable, Hashable, Codable, Sendable, Identifiable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ id: String) { rawValue = id }
  public init(stringLiteral value: String) { rawValue = value }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var id: String { rawValue }
  public var description: String { rawValue }

  /// The one symbol every category row and chip draws. A category is data,
  /// so no id earns its own.
  public var systemImage: String { "tag" }

  /// The id made readable — `case-study` → `Case study`. Only for a category
  /// the client has no row for yet (a stale list); a row's `label` wins.
  public var fallbackLabel: String {
    let words = rawValue.replacingOccurrences(of: "-", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }
}

/// One category the workspace owns, as `GET /api/categories` lists it:
/// rail order, with the active documents the reader can see.
public struct DocsCategoryInfo: Codable, Hashable, Identifiable, Sendable {
  public let id: DocsCategory
  public let label: String
  public let position: Int
  public let count: Int

  public init(id: DocsCategory, label: String, position: Int, count: Int) {
    self.id = id
    self.label = label
    self.position = position
    self.count = count
  }
}

public struct DocsCategoryList: Codable, Sendable {
  public let categories: [DocsCategoryInfo]
}

extension Array where Element == DocsCategoryInfo {
  /// The label Docs gave `category`, or its readable id when this list
  /// predates it.
  public func label(for category: DocsCategory) -> String {
    first { $0.id == category }?.label ?? category.fallbackLabel
  }
}

/// `POST /api/categories`. `id` defaults on the server to the slug of `label`.
public struct DocsCreateCategory: Encodable, Sendable {
  public var label: String
  public var id: DocsCategory?

  public init(label: String, id: DocsCategory? = nil) {
    self.label = label
    self.id = id
  }
}

/// `PATCH /api/categories/:id`: rename or move. The id never changes.
public struct DocsUpdateCategory: Encodable, Sendable {
  public var label: String?
  public var position: Int?

  public init(label: String? = nil, position: Int? = nil) {
    self.label = label
    self.position = position
  }
}

/// The two halves of every Docs rail (meet `docs/DOCS.md`, "The rail"):
/// WORK is what Meet wrote (`native`), LIBRARY is every mirror — Core's
/// published writing and the Obsidian vault. One rule for the Mac, the
/// phone and the web; the web's `DOCS_RAIL_HALF` mirrors it.
public enum DocsRailHalf: String, Codable, CaseIterable, Sendable {
  case work, library

  /// The source systems the half lists; what `?source=` gets.
  public var sources: [String] {
    switch self {
    case .work: ["native"]
    case .library: ["core", "obsidian"]
    }
  }

  public init(source: String) {
    self = source == "native" ? .work : .library
  }
}

public struct DocsFolder: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let slug: String
  public let title: String
  public let parentId: String?
  public let depth: Int
  public let icon: String?
  public let description: String?
  public let sourceKey: String?
  /// Documents directly in this folder; the tree endpoint counts them.
  public let documentCount: Int?
}

public struct DocsFolderTree: Codable, Sendable {
  public let folders: [DocsFolder]
}

public struct DocsSummary: Codable, Sendable {
  public struct CategoryCount: Codable, Hashable, Identifiable, Sendable {
    public let category: DocsCategory
    public let label: String
    public let count: Int
    public var id: DocsCategory { category }

    public init(category: DocsCategory, label: String, count: Int) {
      self.category = category
      self.label = label
      self.count = count
    }
  }

  /// One (source, category) pair, in category order then source order.
  public struct SourceCount: Codable, Hashable, Identifiable, Sendable {
    public let source: String
    public let category: DocsCategory
    public let label: String
    public let count: Int
    public var id: String { "\(source):\(category.rawValue)" }
  }

  public struct FolderCount: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    public let title: String
    public let count: Int
    public var id: String { path }
  }

  /// Every category in rail order, an empty one too, with its active
  /// documents whatever wrote them.
  public let categories: [CategoryCount]
  /// Per (source, category): what a rail's two halves count.
  public let bySource: [SourceCount]
  public let folders: [FolderCount]
  /// Active link saves. They carry no category, so no row above counts them.
  public let links: Int
  /// Active documents nobody filed (meet#376). 0 from a Docs that does
  /// not count them yet, which hides the row.
  public let unfiled: Int
  public let total: Int

  public init(
    categories: [CategoryCount], bySource: [SourceCount], folders: [FolderCount], links: Int = 0, unfiled: Int = 0,
    total: Int
  ) {
    self.categories = categories
    self.bySource = bySource
    self.folders = folders
    self.links = links
    self.unfiled = unfiled
    self.total = total
  }

  /// A Docs older than `by_source` still answers; `categories(on:)` then
  /// puts every category on the WORK half until it is deployed.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    categories = try container.decode([CategoryCount].self, forKey: .categories)
    bySource = try container.decodeIfPresent([SourceCount].self, forKey: .bySource) ?? []
    folders = try container.decode([FolderCount].self, forKey: .folders)
    links = try container.decodeIfPresent(Int.self, forKey: .links) ?? 0
    unfiled = try container.decodeIfPresent(Int.self, forKey: .unfiled) ?? 0
    total = try container.decode(Int.self, forKey: .total)
  }

  /// One row per category on a half, counts summed across its sources, in
  /// rail order. `includeEmpty` keeps a category with nothing on the half,
  /// so a new category is still somewhere to file into.
  ///
  /// Which half a document sits on comes from its source (`DocsRailHalf`),
  /// never its category. With no `by_source` (an older Docs) every category
  /// is WORK and LIBRARY is empty.
  public func categories(on half: DocsRailHalf, includeEmpty: Bool = false) -> [CategoryCount] {
    if bySource.isEmpty {
      guard half == .work else { return [] }
      return includeEmpty ? categories : categories.filter { $0.count > 0 }
    }
    var totals: [DocsCategory: Int] = [:]
    var labels: [DocsCategory: String] = [:]
    for row in bySource where DocsRailHalf(source: row.source) == half {
      totals[row.category, default: 0] += row.count
      labels[row.category] = row.label
    }
    var rows = categories.compactMap { entry -> CategoryCount? in
      let count = totals[entry.category] ?? 0
      guard count > 0 || includeEmpty else { return nil }
      return CategoryCount(category: entry.category, label: entry.label, count: count)
    }
    // A `by_source` row whose category the list above lacks still shows, last.
    let listed = Set(categories.map(\.category))
    for row in bySource where DocsRailHalf(source: row.source) == half && !listed.contains(row.category) {
      guard !rows.contains(where: { $0.category == row.category }), let count = totals[row.category] else { continue }
      rows.append(CategoryCount(category: row.category, label: labels[row.category] ?? row.label, count: count))
    }
    return rows
  }

  /// The label Docs gave `category`, or its readable id when the summary
  /// predates it.
  public func label(for category: DocsCategory) -> String {
    categories.first { $0.category == category }?.label ?? category.fallbackLabel
  }

  /// Every category, in rail order, as the pickers and the File menu take
  /// them: what a host that holds a summary passes as `docsCategories`.
  public var categoryList: [DocsCategoryInfo] {
    categories.enumerated().map { index, entry in
      DocsCategoryInfo(id: entry.category, label: entry.label, position: index, count: entry.count)
    }
  }
}

public enum DocsGrantRole: String, Codable, Sendable {
  case viewer, commenter, signer
}

public struct DocsGrant: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let documentId: String?
  public let folderId: String?
  public let url: String
  public let email: String?
  public let role: DocsGrantRole
  public let label: String?
  public let requireVerification: Bool
  public let createdBy: String
  public let createdAt: String
  public let expiresAt: String?
  public let revokedAt: String?
  public let lastUsedAt: String?
  public let useCount: Int
}

public struct DocsGrantList: Codable, Sendable {
  public let grants: [DocsGrant]
}

public struct DocsCreateGrant: Encodable, Sendable {
  public var role: DocsGrantRole
  public var email: String?
  public var label: String?
  public var requireVerification: Bool?
  public var expiresInDays: Int?

  public init(role: DocsGrantRole = .viewer, email: String? = nil, label: String? = nil, requireVerification: Bool? = nil, expiresInDays: Int? = nil) {
    self.role = role
    self.email = email
    self.label = label
    self.requireVerification = requireVerification
    self.expiresInDays = expiresInDays
  }
}

public struct DocsSignatureParty: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let email: String
  public let name: String?
  public let role: String
  public let sequence: Int
  public let status: String
  public let signedAt: String?
  public let url: String?
}

public struct DocsSignatureRequest: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let documentId: String
  public let documentTitle: String
  public let documentVersion: Int
  public let requestedBy: String
  public let subject: String?
  public let status: String
  public let createdAt: String
  public let expiresAt: String?
  public let completedAt: String?
  public let parties: [DocsSignatureParty]
}

public struct DocsCreateSignatureRequest: Encodable, Sendable {
  public struct Party: Encodable, Sendable {
    public var email: String
    public var name: String?
    public init(email: String, name: String? = nil) {
      self.email = email
      self.name = name
    }
  }

  public var subject: String?
  public var message: String?
  public var parties: [Party]
  public var expiresInDays: Int?

  public init(subject: String? = nil, message: String? = nil, parties: [Party], expiresInDays: Int? = nil) {
    self.subject = subject
    self.message = message
    self.parties = parties
    self.expiresInDays = expiresInDays
  }
}

public struct DocsMoveDocument: Encodable, Sendable {
  public var folderPath: String?
  public var slug: String?
  public var title: String?

  public init(folderPath: String? = nil, slug: String? = nil, title: String? = nil) {
    self.folderPath = folderPath
    self.slug = slug
    self.title = title
  }
}
