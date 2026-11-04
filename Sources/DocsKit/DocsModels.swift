import Foundation

// Wire contract for docs.envisioning.com, hand-ported from
// `docs/packages/contracts`. The server is the source of truth; match it,
// don't invent fields. Snake case on the wire, camel case here — one decoder
// (`DocsCoding`) does the mapping so no type carries its own CodingKeys.

/// What a document is *about* — a CRM subject — as opposed to where it lives.
/// Kinds are the registry's entity kinds, singular, matching Meet's
/// `CrmSubject.kind`.
public struct DocsSubject: Codable, Hashable, Sendable {
  public var system: String
  public var kind: String
  public var subjectId: String

  public init(system: String = "core", kind: String, subjectId: String) {
    self.system = system
    self.kind = kind
    self.subjectId = subjectId
  }

  /// The one-string form the API takes in query strings: `core:organization:<id>`.
  public var ref: String { "\(system):\(kind):\(subjectId)" }
}

/// What a saved page said about itself (meet#345). Present on a document
/// whose `sourceKind` is `link`; the body of that document is the person's
/// notes. `hasImage` means `DocsClient.linkImage(id:)` answers — a copy Docs
/// keeps, never the site's URL, so opening a save calls nobody.
///
/// Docs never reads a page. Saving and reading again go through Meet's
/// Worker, which owns the one page reader (decision 13 on meet#345); a host
/// hands `DocumentEditor` that as `linkRefetch`.
public struct DocsLinkSave: Codable, Hashable, Sendable {
  public let url: String
  public let canonicalUrl: String
  public let siteName: String?
  public let description: String?
  public let hasImage: Bool
  /// Screenshots the person attached. Nil from a Docs older than slice 2.
  public let imageCount: Int?
  /// The first of them: the card's cover when the page gave no image.
  public let firstImageId: String?
  /// `ok`, `failed` (the site did not answer; the URL is kept), or `skipped`
  /// (not a web page, e.g. a PDF link).
  public let fetchStatus: String
  public let fetchError: String?
  public let fetchedAt: String?

  public init(
    url: String, canonicalUrl: String, siteName: String? = nil, description: String? = nil, hasImage: Bool = false,
    imageCount: Int? = nil, firstImageId: String? = nil,
    fetchStatus: String = "ok", fetchError: String? = nil, fetchedAt: String? = nil
  ) {
    self.url = url
    self.canonicalUrl = canonicalUrl
    self.siteName = siteName
    self.description = description
    self.hasImage = hasImage
    self.imageCount = imageCount
    self.firstImageId = firstImageId
    self.fetchStatus = fetchStatus
    self.fetchError = fetchError
    self.fetchedAt = fetchedAt
  }

  /// The site name, or the host when the page named none.
  public var site: String {
    if let siteName, !siteName.isEmpty { return siteName }
    let host = URL(string: canonicalUrl)?.host() ?? URL(string: url)?.host() ?? url
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// Where Open goes: the page the person saved.
  public var openURL: URL? { URL(string: url) }
}

/// The `source_kind` that marks a link save. Not a category: Docs cannot add
/// one to its table, so a save's category is nil (envisioning/docs AGENTS.md,
/// "Never rebuild `documents`").
public enum DocsLinks {
  public static let sourceKind = "link"
  /// Where a save lands when nobody names a folder. Matches `LINK_FOLDER`.
  public static let folder = "/work/links"

  /// The URL in something pasted or dropped, when it is one http(s) link
  /// and nothing else. A paragraph that happens to hold a link is text.
  public static func url(fromPasted text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 2048, !trimmed.contains(where: \.isWhitespace),
      let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host() != nil
    else { return nil }
    return url
  }
}

public struct DocsDocumentSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let slug: String
  public let title: String
  public let kind: String
  public let visibility: String
  public let status: String
  public let sourceSystem: String
  public let sourceKind: String?
  public let sourceUrl: String?
  public let editable: Bool
  public let version: Int
  public let byteSize: Int
  public let contentHash: String
  public let tags: [String]
  /// Any category id the workspace owns; see `DocsCategory`.
  public let category: DocsCategory?
  /// Staff-only for good, whatever its category. False from a Docs older
  /// than the field.
  @DocsDefaultFalse public private(set) var transcript: Bool
  public let subjects: [DocsSubject]
  public let createdAt: String
  public let updatedAt: String
  public let updatedBy: String?
  public let excerpt: String?
  /// Only on a link save.
  public let link: DocsLinkSave?
  /// When the words are from: `frontmatter.date`, else `createdAt`
  /// (meet#385). Nil from a Docs older than the field; `written` covers it.
  public let writtenAt: String?

  /// The written date, whatever Docs answered.
  public var written: String { writtenAt ?? createdAt }

  public init(
    id: String, path: String, slug: String, title: String, kind: String, visibility: String, status: String,
    sourceSystem: String, sourceKind: String?, sourceUrl: String?, editable: Bool, version: Int, byteSize: Int,
    contentHash: String, tags: [String], category: DocsCategory?, transcript: Bool = false, subjects: [DocsSubject],
    createdAt: String, updatedAt: String, updatedBy: String?, excerpt: String?, link: DocsLinkSave? = nil,
    writtenAt: String? = nil
  ) {
    self.id = id
    self.path = path
    self.slug = slug
    self.title = title
    self.kind = kind
    self.visibility = visibility
    self.status = status
    self.sourceSystem = sourceSystem
    self.sourceKind = sourceKind
    self.sourceUrl = sourceUrl
    self.editable = editable
    self.version = version
    self.byteSize = byteSize
    self.contentHash = contentHash
    self.tags = tags
    self.category = category
    _transcript = DocsDefaultFalse(wrappedValue: transcript)
    self.subjects = subjects
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.updatedBy = updatedBy
    self.excerpt = excerpt
    self.link = link
    self.writtenAt = writtenAt
  }

  public var isLinkSave: Bool { sourceKind == DocsLinks.sourceKind }
}

/// An image a person attached to a document — a screenshot on a link save
/// (meet#345). The bytes come from `DocsClient.imageData`.
public struct DocsImage: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let contentType: String
  public let byteSize: Int
  public let caption: String?
  public let createdBy: String
  public let createdAt: String
}

public struct DocsImageList: Codable, Sendable {
  public let images: [DocsImage]
}

public struct DocsDocumentLink: Codable, Hashable, Sendable {
  public let target: String
  public let toId: String?
  public let toPath: String?
}

public struct DocsBacklink: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let title: String
}

public struct DocsDocumentDetail: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let slug: String
  public let title: String
  public let kind: String
  public let visibility: String
  public let status: String
  public let sourceSystem: String
  public let sourceKind: String?
  public let sourceUrl: String?
  public let editable: Bool
  public let version: Int
  public let byteSize: Int
  public let contentHash: String
  public let tags: [String]
  public let category: DocsCategory?
  /// See `DocsDocumentSummary.transcript`.
  @DocsDefaultFalse public private(set) var transcript: Bool
  public let subjects: [DocsSubject]
  public let createdAt: String
  public let updatedAt: String
  public let updatedBy: String?
  public let bodyMd: String?
  public let links: [DocsDocumentLink]
  public let backlinks: [DocsBacklink]
  public let openAnnotations: Int
  /// Only on a link save.
  public let link: DocsLinkSave?
  /// Attached images, oldest first. Nil from a Docs older than slice 2.
  public let images: [DocsImage]?
  /// See `DocsDocumentSummary.writtenAt`.
  public let writtenAt: String?

  public var isLinkSave: Bool { sourceKind == DocsLinks.sourceKind }

  public var summary: DocsDocumentSummary {
    DocsDocumentSummary(
      id: id, path: path, slug: slug, title: title, kind: kind, visibility: visibility,
      status: status, sourceSystem: sourceSystem, sourceKind: sourceKind, sourceUrl: sourceUrl,
      editable: editable, version: version, byteSize: byteSize, contentHash: contentHash,
      tags: tags, category: category, transcript: transcript, subjects: subjects, createdAt: createdAt, updatedAt: updatedAt,
      updatedBy: updatedBy, excerpt: nil, link: link, writtenAt: writtenAt)
  }
}

public struct DocsDocumentList: Codable, Sendable {
  public let documents: [DocsDocumentSummary]
  public let total: Int

  public init(documents: [DocsDocumentSummary], total: Int) {
    self.documents = documents
    self.total = total
  }
}

public struct DocsSearchHit: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let title: String
  public let kind: String
  public let sourceSystem: String
  public let sourceKind: String?
  public let updatedAt: String
  /// FTS5 snippet with `<mark>` around the hits.
  public let snippet: String
}

/// What the Meet Worker hands back from `POST /api/docs/token`.
public struct DocsTokenGrant: Codable, Hashable, Sendable {
  public let token: String
  public let scopes: [String]
  /// ISO 8601. Docs revokes the old token when a new one is minted.
  public let expiresAt: String
  public let email: String

  public init(token: String, scopes: [String], expiresAt: String, email: String) {
    self.token = token
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.email = email
  }
}

/// Inputs. Optionals are omitted from the wire when nil.
public struct DocsCreateDocument: Encodable, Sendable {
  public var title: String
  public var path: String?
  public var folderPath: String?
  public var bodyMd: String
  /// An id the workspace owns, else Docs answers 400. Nil files it under none.
  public var category: DocsCategory?
  /// Mark it a transcript: staff-only, for good.
  public var transcript: Bool?
  public var subjects: [DocsSubject]
  public var tags: [String]
  public var message: String?

  public init(
    title: String,
    path: String? = nil,
    folderPath: String? = nil,
    bodyMd: String = "",
    category: DocsCategory? = nil,
    transcript: Bool? = nil,
    subjects: [DocsSubject] = [],
    tags: [String] = [],
    message: String? = nil
  ) {
    self.title = title
    self.path = path
    self.folderPath = folderPath
    self.bodyMd = bodyMd
    self.category = category
    self.transcript = transcript
    self.subjects = subjects
    self.tags = tags
    self.message = message
  }
}

public struct DocsUpdateDocument: Encodable, Sendable {
  public var title: String?
  public var bodyMd: String?
  public var message: String?
  public var status: String?
  /// `internal` | `link` | `public`. See `DocsVisibility`.
  public var visibility: String?
  /// `.some(nil)` clears the category; `.none` leaves it. Encoded by hand
  /// below so the wire sees `null` for the first and nothing for the second.
  public var category: DocsCategory??
  /// The hash the client read. Docs answers `hash_mismatch` when it moved.
  public var ifContentHash: String?

  public init(
    title: String? = nil,
    bodyMd: String? = nil,
    message: String? = nil,
    status: String? = nil,
    visibility: String? = nil,
    category: DocsCategory?? = nil,
    ifContentHash: String? = nil
  ) {
    self.title = title
    self.bodyMd = bodyMd
    self.message = message
    self.status = status
    self.visibility = visibility
    self.category = category
    self.ifContentHash = ifContentHash
  }

  enum CodingKeys: String, CodingKey {
    case title, bodyMd, message, status, visibility, category, ifContentHash
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(bodyMd, forKey: .bodyMd)
    try c.encodeIfPresent(message, forKey: .message)
    try c.encodeIfPresent(status, forKey: .status)
    try c.encodeIfPresent(visibility, forKey: .visibility)
    if let category { try c.encode(category, forKey: .category) }
    try c.encodeIfPresent(ifContentHash, forKey: .ifContentHash)
  }
}

/// A wire Bool an older Docs leaves out: absent decodes as false, so a new
/// field never breaks a list the old server sends.
@propertyWrapper
public struct DocsDefaultFalse: Codable, Hashable, Sendable {
  public var wrappedValue: Bool

  public init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }

  public init(from decoder: Decoder) throws {
    wrappedValue = try decoder.singleValueContainer().decode(Bool.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  public func decode(_ type: DocsDefaultFalse.Type, forKey key: Key) throws -> DocsDefaultFalse {
    try decodeIfPresent(type, forKey: key) ?? DocsDefaultFalse(wrappedValue: false)
  }
}

public enum DocsCoding {
  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }
}

/// The three values Docs accepts for `visibility`. `internal` is staff only;
/// `link` opens the www share page (email-gated) and grant links; `public`
/// is the world, and no client sets it yet.
public enum DocsVisibility {
  public static let internalOnly = "internal"
  public static let link = "link"
  public static let `public` = "public"

  /// True when the document answers on the www share page.
  public static func isShared(_ visibility: String) -> Bool {
    visibility == link || visibility == `public`
  }
}

/// Where a document can be opened from outside Docs. One place for each URL
/// shape, so a host change is one edit.
public enum DocsShareLink {
  /// `www.envisioning.com/private/docs/<id>`: the email-gated reader on the
  /// public site. Answers only while the document's visibility is `link` or
  /// `public`; www resolves the id through Docs, so it is the Docs id, not a
  /// grant token.
  public static func www(documentID: String) -> URL {
    URL(string: "https://www.envisioning.com/private/docs/\(documentID)")!
  }
}

// MARK: - Annotations (comments)

/// Where a comment points: a passage by its words. Docs re-anchors on
/// `quote` after an edit and reports `orphaned` when it is gone. A PDF
/// anchor decodes to `type == "pdf"` with no quote; Meet never writes one.
public struct DocsAnchor: Codable, Hashable, Sendable {
  public var type: String
  public var quote: String?
  public var prefix: String?
  public var suffix: String?

  public init(quote: String, prefix: String? = nil, suffix: String? = nil) {
    type = "text"
    self.quote = quote
    self.prefix = prefix
    self.suffix = suffix
  }
}

/// One comment: a thread's root (`parentId == nil`) or a reply in it.
public struct DocsAnnotation: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let documentId: String
  public let documentVersion: Int
  public let threadId: String
  public let parentId: String?
  public let author: String
  public let authorName: String?
  /// `staff`, `guest` or `agent`.
  public let authorKind: String
  public let bodyMd: String
  public let anchor: DocsAnchor?
  /// `open` or `resolved`.
  public let status: String
  public let resolvedBy: String?
  public let resolvedAt: String?
  public let createdAt: String
  public let updatedAt: String
  /// True when the anchor quote no longer appears in the current body.
  public let orphaned: Bool?

  /// The address's local part, or the name Docs recorded.
  public var who: String {
    if let authorName, !authorName.isEmpty { return authorName }
    return author.split(separator: "@").first.map(String.init) ?? author
  }
}

public struct DocsCreateAnnotation: Encodable, Sendable {
  public var bodyMd: String
  public var anchor: DocsAnchor?
  public var parentId: String?

  public init(bodyMd: String, anchor: DocsAnchor? = nil, parentId: String? = nil) {
    self.bodyMd = bodyMd
    self.anchor = anchor
    self.parentId = parentId
  }
}

public struct DocsUpdateAnnotation: Encodable, Sendable {
  public var bodyMd: String?
  public var status: String?

  public init(bodyMd: String? = nil, status: String? = nil) {
    self.bodyMd = bodyMd
    self.status = status
  }
}

/// One thread: the root and its replies in the order written.
public struct DocsThread: Hashable, Identifiable, Sendable {
  public let root: DocsAnnotation
  public let replies: [DocsAnnotation]
  public var id: String { root.threadId }
  public var isOpen: Bool { root.status == "open" }

  /// Threads from a flat list, newest root first.
  public static func threads(_ annotations: [DocsAnnotation]) -> [DocsThread] {
    var byThread: [String: [DocsAnnotation]] = [:]
    for annotation in annotations { byThread[annotation.threadId, default: []].append(annotation) }
    return byThread.values.compactMap { list -> DocsThread? in
      let sorted = list.sorted { $0.createdAt < $1.createdAt }
      guard let root = sorted.first(where: { $0.parentId == nil }) ?? sorted.first else { return nil }
      return DocsThread(root: root, replies: sorted.filter { $0.id != root.id })
    }
    .sorted { $0.root.createdAt > $1.root.createdAt }
  }
}
