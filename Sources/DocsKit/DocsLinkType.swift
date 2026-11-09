import Foundation

// Link saves as outside knowledge: a save is something somebody else wrote
// (an article, a video, a talk, a book, a law). This is a port of
// `linkType` in Starlings' `packages/contracts/src/docs-links.ts`, the one
// rule every client sorts and labels with. Change both together.

/// What a saved link is. `allCases` is the filter's order.
public enum DocsLinkType: String, CaseIterable, Hashable, Sendable {
  case article, video, talk, book, law, other

  /// A shelf's name. Plural on purpose: "Talk" and "Book" are verbs
  /// elsewhere, and one key has one translation.
  public var label: String {
    switch self {
    case .article: String(localized: "Articles")
    case .video: String(localized: "Videos")
    case .talk: String(localized: "Talks")
    case .book: String(localized: "Books")
    case .law: String(localized: "Laws")
    case .other: String(localized: "Other")
    }
  }

  public var systemImage: String {
    switch self {
    case .article: "doc.richtext"
    case .video: "play.rectangle"
    case .talk: "person.wave.2"
    case .book: "book.closed"
    case .law: "building.columns"
    case .other: "link"
    }
  }

  /// A tag that names the type outright. It wins over the address: a talk
  /// on YouTube is tagged `talk`.
  static let tags: [String: DocsLinkType] = [
    "article": .article, "articles": .article, "artigo": .article, "news": .article, "noticia": .article,
    "video": .video, "videos": .video,
    "talk": .talk, "talks": .talk, "palestra": .talk, "lecture": .talk,
    "book": .book, "books": .book, "livro": .book,
    "law": .law, "laws": .law, "lei": .law, "decreto": .law, "decree": .law, "regulation": .law,
    "other": .other,
  ]

  /// Hosts whose pages are one type. A host matches itself and its
  /// subdomains; `path` narrows a host that publishes more than one type.
  static let hosts: [(host: String, path: String?, type: DocsLinkType)] = [
    ("youtube.com", nil, .video),
    ("youtu.be", nil, .video),
    ("vimeo.com", nil, .video),
    ("dailymotion.com", nil, .video),
    ("globoplay.globo.com", nil, .video),
    ("media.ccc.de", nil, .talk),
    ("ted.com", "/talks", .talk),
    ("slideslive.com", nil, .talk),
    ("books.google.com", nil, .book),
    ("goodreads.com", "/book", .book),
    ("openlibrary.org", nil, .book),
    ("planalto.gov.br", "/ccivil_03", .law),
    ("camara.leg.br", "/legin", .law),
    ("normas.leg.br", nil, .law),
    ("lexml.gov.br", nil, .law),
    ("in.gov.br", "/en/web/dou", .law),
    ("eur-lex.europa.eu", nil, .law),
    ("legislation.gov.uk", nil, .law),
    ("wetten.overheid.nl", nil, .law),
  ]

  /// The type of a saved link: a tag that names one, then the address,
  /// then `article` for a page and `other` for a site's home page or an
  /// address that does not parse.
  public static func of(url: String, tags: [String] = []) -> DocsLinkType {
    for tag in tags {
      var key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if key.hasPrefix("#") { key.removeFirst() }
      if let named = Self.tags[key] { return named }
    }
    guard let parsed = URL(string: url), let rawHost = parsed.host(), !rawHost.isEmpty else { return .other }
    var host = rawHost.lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    let path = parsed.path(percentEncoded: true).lowercased()
    for rule in hosts where host == rule.host || host.hasSuffix(".\(rule.host)") {
      if let prefix = rule.path, !path.hasPrefix(prefix) { continue }
      return rule.type
    }
    return path.isEmpty || path == "/" ? .other : .article
  }
}

extension DocsDocumentSummary {
  /// The page a save points at, when it is a web address.
  public var linkPage: URL? { Self.webPage(link?.url ?? sourceUrl) }

  /// What this save is, by the shared rule. Nil when it is not a save.
  public var linkType: DocsLinkType? {
    isLinkSave ? DocsLinkType.of(url: link?.url ?? sourceUrl ?? "", tags: tags) : nil
  }

  static func webPage(_ url: String?) -> URL? {
    guard let url, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return nil }
    return parsed
  }
}

extension DocsDocumentDetail {
  public var linkPage: URL? { DocsDocumentSummary.webPage(link?.url ?? sourceUrl) }

  public var linkType: DocsLinkType? {
    isLinkSave ? DocsLinkType.of(url: link?.url ?? sourceUrl ?? "", tags: tags) : nil
  }
}
