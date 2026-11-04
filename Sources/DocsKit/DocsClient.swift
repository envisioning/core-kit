import Foundation

/// A 204: nothing came back, and nothing was expected.
public struct DocsEmpty: Decodable, Sendable { public init() {} }

public enum DocsClientError: LocalizedError, Sendable, Equatable {
  case missingToken
  case invalidResponse
  /// The body moved under the client. Re-read, merge, write again.
  case hashMismatch
  /// A mirrored body — Core owns the text.
  case readOnly(String)
  case unauthorized
  case api(status: Int, code: String?, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingToken: "Connect Docs in Settings."
    case .invalidResponse: "Docs returned an invalid response."
    case .hashMismatch: "This document changed since you opened it."
    case .readOnly(let message): message
    case .unauthorized: "Docs no longer accepts this device's token. Reconnect in Settings."
    case .api(_, _, let message): message
    }
  }
}

/// The device's line to docs.envisioning.com. Same shape as `CoreAgentClient`:
/// an actor, a base URL, and a closure that yields the current bearer — the
/// token itself lives in the app's credential store, never here.
///
/// Every write carries what the client read (`if_content_hash`), and a
/// `hash_mismatch` surfaces as its own error so the editor can show both
/// bodies instead of clobbering one.
public actor DocsClient {
  /// The served origin. Never the Gandi redirect: a redirected POST arrives as
  /// a GET with no body.
  public static let productionURL = URL(string: "https://docs.envisioning.workers.dev")!

  /// The one link a document is shared by: the production reader at its path.
  public static func publicLink(path: String) -> String {
    "\(productionURL.absoluteString)/doc\(path)"
  }

  private let baseURL: URL
  private let tokenProvider: @Sendable () -> String?
  private let session: URLSession
  /// The last good body of every list read, when the host keeps one
  /// (`DocsSnapshots.swift`). Nil reads live only.
  private let snapshots: (any DocsSnapshotStore)?

  public init(
    baseURL: URL = DocsClient.productionURL,
    session: URLSession = .shared,
    snapshots: (any DocsSnapshotStore)? = nil,
    tokenProvider: @escaping @Sendable () -> String?
  ) {
    self.baseURL = baseURL
    self.session = session
    self.snapshots = snapshots
    self.tokenProvider = tokenProvider
  }

  // MARK: Reads

  /// One list of `/api/docs`, live. The body becomes the snapshot for
  /// `read.snapshotKey` on the way back.
  public func documents(_ read: DocsListRead) async throws -> [DocsDocumentSummary] {
    let list: DocsDocumentList = try await request("GET", "/api/docs", query: read.query, snapshotKey: read.snapshotKey)
    return list.documents
  }

  /// Every row of `read`, not just its first page: Docs caps one list at
  /// 200 rows, so a rail that counts or a browser that lists walks `offset`
  /// until the list's `total` is in hand. The read's `limit` is the page
  /// size. The whole list becomes the snapshot for `read.snapshotKey`, so
  /// `cachedDocuments(_:)` paints all of it next time. Stops at `cap` rows.
  public func allDocuments(_ read: DocsListRead, cap: Int = 5_000) async throws -> [DocsDocumentSummary] {
    var documents: [DocsDocumentSummary] = []
    var total = Int.max
    while documents.count < min(total, cap) {
      let page: DocsDocumentList = try await request(
        "GET", "/api/docs", query: read.query + [("offset", String(documents.count))])
      total = page.total
      if page.documents.isEmpty { break }
      documents.append(contentsOf: page.documents)
    }
    if let snapshots, let data = try? DocsCoding.encoder.encode(DocsDocumentList(documents: documents, total: total)) {
      snapshots.save(data, key: read.snapshotKey)
    }
    return documents
  }

  /// The last list that came back for `read`, without a request: what a
  /// screen paints before `documents(_:)` answers. Nil with no store, or
  /// nothing kept yet.
  public nonisolated func cachedDocuments(_ read: DocsListRead) -> [DocsDocumentSummary]? {
    cached(DocsDocumentList.self, key: read.snapshotKey)?.documents
  }

  /// The last sidebar that came back, without a request.
  public nonisolated func cachedSummary() -> DocsSummary? {
    cached(DocsSummary.self, key: DocsSnapshotKey.summary)
  }

  /// The last category list that came back, without a request.
  public nonisolated func cachedCategories() -> [DocsCategoryInfo]? {
    cached(DocsCategoryList.self, key: DocsSnapshotKey.categories)?.categories
  }

  /// Everything about one subject, newest first.
  public func documents(about subject: DocsSubject, limit: Int = 100) async throws -> [DocsDocumentSummary] {
    try await documents(.about(subject, limit: limit))
  }

  /// Newest documents anywhere; the Docs block's "Recent".
  public func recentDocuments(limit: Int = 30) async throws -> [DocsDocumentSummary] {
    try await documents(.recent(limit: limit))
  }

  /// Everything Meet wrote (`source=native`), newest first — what a rail's
  /// By project / By lead groups are built from: the subjects come off the
  /// documents themselves, so a group exists only when something is filed
  /// about it (meet/docs/DOCS.md, "The rail").
  public func writtenDocuments(limit: Int = 200) async throws -> [DocsDocumentSummary] {
    try await documents(.written(limit: limit))
  }

  public func document(id: String) async throws -> DocsDocumentDetail {
    try await request("GET", "/api/docs/\(id)")
  }

  // MARK: The browser

  /// Every folder, flat, ordered by path. The sidebar nests them by depth.
  public func tree() async throws -> [DocsFolder] {
    let tree: DocsFolderTree = try await request("GET", "/api/tree")
    return tree.folders
  }

  /// One request for a sidebar: categories and shelves with counts.
  public func summary() async throws -> DocsSummary {
    try await request("GET", "/api/docs/summary", snapshotKey: DocsSnapshotKey.summary)
  }

  /// Documents directly in one folder, newest first.
  public func documents(inFolder path: String, limit: Int = 200) async throws -> [DocsDocumentSummary] {
    try await documents(.inFolder(path, limit: limit))
  }

  /// Documents anywhere under a folder, newest first.
  public func documents(underPrefix path: String, limit: Int = 200) async throws -> [DocsDocumentSummary] {
    try await documents(.underPrefix(path, limit: limit))
  }

  public func documents(category: DocsCategory, limit: Int = 200) async throws -> [DocsDocumentSummary] {
    try await documents(.category(category, limit: limit))
  }

  /// One category on one half of the rail: `source=` narrows to the half's
  /// systems, so Core's briefs and a person's briefs are two lists.
  public func documents(category: DocsCategory, on half: DocsRailHalf, limit: Int = 200) async throws -> [DocsDocumentSummary] {
    try await documents(.categoryOnHalf(category, half, limit: limit))
  }

  // MARK: Categories

  /// Every category the workspace owns, in rail order, with counts. A new
  /// install has none. Labels come from here, never from the id.
  public func categories() async throws -> [DocsCategoryInfo] {
    let list: DocsCategoryList = try await request("GET", "/api/categories", snapshotKey: DocsSnapshotKey.categories)
    return list.categories
  }

  /// A new category, last in rail order unless `position` says otherwise.
  /// Needs `folders:write`.
  public func createCategory(_ input: DocsCreateCategory) async throws -> DocsCategoryInfo {
    try await request("POST", "/api/categories", body: input, invalidates: true)
  }

  /// Rename and/or move one category. The id never changes.
  public func updateCategory(id: DocsCategory, _ input: DocsUpdateCategory) async throws -> DocsCategoryInfo {
    try await request("PATCH", "/api/categories/\(id.rawValue)", body: input, invalidates: true)
  }

  /// The rail order, every id in turn. An id left out keeps its place after
  /// them. Answers the whole list in its new order.
  public func orderCategories(_ ids: [DocsCategory]) async throws -> [DocsCategoryInfo] {
    let list: DocsCategoryList = try await request(
      "PUT", "/api/categories/order", body: ["ids": ids.map(\.rawValue)], invalidates: true)
    return list.categories
  }

  /// Gone for good. Its documents stay, uncategorized.
  public func deleteCategory(id: DocsCategory) async throws {
    let _: DocsEmpty = try await request("DELETE", "/api/categories/\(id.rawValue)", invalidates: true)
  }

  /// Move to another folder, and/or rename the slug or title. The subject
  /// links are untouched: where a document sits is not what it is about.
  public func move(id: String, _ input: DocsMoveDocument) async throws -> DocsDocumentDetail {
    try await request("POST", "/api/docs/\(id)/move", body: input, invalidates: true)
  }

  // MARK: Sharing

  public func grants(for id: String) async throws -> [DocsGrant] {
    let list: DocsGrantList = try await request("GET", "/api/docs/\(id)/grants")
    return list.grants
  }

  /// Who opened the document and which links they clicked, newest first.
  public func accessEvents(for id: String) async throws -> [DocsAccessEvent] {
    let list: DocsAccessEventList = try await request("GET", "/api/docs/\(id)/access-events")
    return list.events
  }

  public func createGrant(for id: String, _ input: DocsCreateGrant) async throws -> DocsGrant {
    try await request("POST", "/api/docs/\(id)/grants", body: input)
  }

  public func revokeGrant(id: String) async throws {
    let _: DocsEmpty = try await request("DELETE", "/api/grants/\(id)")
  }

  // MARK: Annotations (comments, meet#175)

  /// Every comment on a document, flat; `DocsThread.threads` groups them.
  public func annotations(for id: String) async throws -> [DocsAnnotation] {
    try await request("GET", "/api/docs/\(id)/annotations")
  }

  public func createAnnotation(for id: String, _ input: DocsCreateAnnotation) async throws -> DocsAnnotation {
    try await request("POST", "/api/docs/\(id)/annotations", body: input)
  }

  public func updateAnnotation(id: String, _ input: DocsUpdateAnnotation) async throws -> DocsAnnotation {
    try await request("PATCH", "/api/annotations/\(id)", body: input)
  }

  public func deleteAnnotation(id: String) async throws {
    let _: DocsEmpty = try await request("DELETE", "/api/annotations/\(id)")
  }

  public func createSignatureRequest(for id: String, _ input: DocsCreateSignatureRequest) async throws -> DocsSignatureRequest {
    try await request("POST", "/api/docs/\(id)/signature-requests", body: input)
  }

  public func signatureRequest(id: String) async throws -> DocsSignatureRequest {
    try await request("GET", "/api/signature-requests/\(id)")
  }

  public func search(_ text: String, limit: Int = 30) async throws -> [DocsSearchHit] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return try await request("GET", "/api/search", query: [("q", trimmed), ("limit", String(limit))])
  }

  // MARK: Writes

  public func create(_ input: DocsCreateDocument) async throws -> DocsDocumentDetail {
    try await request("POST", "/api/docs", body: input, invalidates: true)
  }

  /// A link save's cover image: the copy Docs keeps, as bytes.
  public func linkImage(id: String) async throws -> Data {
    try await raw("/api/docs/\(id)/link-image")
  }

  // MARK: Images (meet#345 slice 2)

  public func images(for id: String) async throws -> [DocsImage] {
    let list: DocsImageList = try await request("GET", "/api/docs/\(id)/images")
    return list.images
  }

  /// Attach an image. Hand it through `DocsImagePrep.prepare` first: Docs
  /// takes PNG, JPEG, WebP or GIF up to `DocsImagePrep.maxBytes`, and checks
  /// the bytes, not the type named here.
  public func uploadImage(documentID: String, data: Data, contentType: String, caption: String? = nil) async throws -> DocsImage {
    guard let token = tokenProvider(), !token.isEmpty else { throw DocsClientError.missingToken }
    var components = URLComponents(url: baseURL.appending(path: "/api/docs/\(documentID)/images"), resolvingAgainstBaseURL: false)!
    if let caption, !caption.isEmpty { components.queryItems = [URLQueryItem(name: "caption", value: caption)] }
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (body, response) = try await session.upload(for: request, from: data)
    guard let http = response as? HTTPURLResponse else { throw DocsClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let parsed = try? DocsCoding.decoder.decode(ErrorBody.self, from: body)
      if http.statusCode == 401 { throw DocsClientError.unauthorized }
      throw DocsClientError.api(status: http.statusCode, code: parsed?.code, message: parsed?.error ?? "Docs answered \(http.statusCode).")
    }
    snapshots?.invalidate(prefix: DocsSnapshotKey.prefix)
    guard let image = try? DocsCoding.decoder.decode(DocsImage.self, from: body) else { throw DocsClientError.invalidResponse }
    return image
  }

  /// One attached image's bytes.
  public func imageData(documentID: String, imageID: String) async throws -> Data {
    try await raw("/api/docs/\(documentID)/images/\(imageID)")
  }

  /// Off the document's list. Docs keeps the file.
  public func deleteImage(documentID: String, imageID: String) async throws {
    let _: DocsEmpty = try await request("DELETE", "/api/docs/\(documentID)/images/\(imageID)", invalidates: true)
  }

  public func update(id: String, _ input: DocsUpdateDocument) async throws -> DocsDocumentDetail {
    try await request("PATCH", "/api/docs/\(id)", body: input, invalidates: true)
  }

  /// Replace-all. Small lists; the client says what should be true.
  public func setSubjects(id: String, _ subjects: [DocsSubject]) async throws -> DocsDocumentDetail {
    try await request("PUT", "/api/docs/\(id)/subjects", body: ["subjects": subjects], invalidates: true)
  }

  /// Visibility only, no hash: it is not a body edit, and it must not be
  /// refused because someone else is typing.
  public func setVisibility(id: String, _ visibility: String) async throws -> DocsDocumentDetail {
    try await request("PATCH", "/api/docs/\(id)", body: DocsUpdateDocument(visibility: visibility), invalidates: true)
  }

  /// Soft: `status = archived`. Nothing a person can see is ever hard-deleted.
  public func archive(id: String) async throws -> DocsDocumentDetail {
    try await request("PATCH", "/api/docs/\(id)", body: DocsUpdateDocument(status: "archived"), invalidates: true)
  }

  // MARK: Plumbing

  private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
  }

  private struct ErrorBody: Decodable {
    let error: String?
    let code: String?
  }

  /// A GET whose body is bytes, not JSON.
  private func raw(_ path: String) async throws -> Data {
    guard let token = tokenProvider(), !token.isEmpty else { throw DocsClientError.missingToken }
    var request = URLRequest(url: baseURL.appending(path: path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw DocsClientError.invalidResponse }
    if http.statusCode == 401 { throw DocsClientError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      throw DocsClientError.api(status: http.statusCode, code: nil, message: "Docs answered \(http.statusCode).")
    }
    return data
  }

  private nonisolated func cached<T: Decodable>(_ type: T.Type, key: String) -> T? {
    guard let data = snapshots?.load(key: key) else { return nil }
    return try? DocsCoding.decoder.decode(T.self, from: data)
  }

  /// `snapshotKey`: a list read whose body the store keeps. `invalidates`: a
  /// write after which every kept list is stale — dropped here, in the
  /// client, so no screen has to remember which lists a rename touches.
  private func request<Response: Decodable>(
    _ method: String,
    _ path: String,
    query: [(String, String)] = [],
    body: (any Encodable)? = nil,
    snapshotKey: String? = nil,
    invalidates: Bool = false
  ) async throws -> Response {
    guard let token = tokenProvider(), !token.isEmpty else { throw DocsClientError.missingToken }

    var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try DocsCoding.encoder.encode(AnyEncodable(body))
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw DocsClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let parsed = try? DocsCoding.decoder.decode(ErrorBody.self, from: data)
      switch (http.statusCode, parsed?.code) {
      case (401, _): throw DocsClientError.unauthorized
      case (409, "hash_mismatch"): throw DocsClientError.hashMismatch
      case (409, "read_only"): throw DocsClientError.readOnly(parsed?.error ?? "This document is read-only.")
      default:
        throw DocsClientError.api(
          status: http.statusCode, code: parsed?.code,
          message: parsed?.error ?? "Docs answered \(http.statusCode).")
      }
    }
    if data.isEmpty, let empty = DocsEmpty() as? Response {
      // A 204 from a write still makes every kept list stale.
      if invalidates { snapshots?.invalidate(prefix: DocsSnapshotKey.prefix) }
      return empty
    }
    do {
      let decoded = try DocsCoding.decoder.decode(Response.self, from: data)
      // Saved after the decode: a body this build cannot read is no head start.
      if let snapshotKey { snapshots?.save(data, key: snapshotKey) }
      if invalidates { snapshots?.invalidate(prefix: DocsSnapshotKey.prefix) }
      return decoded
    } catch {
      throw DocsClientError.invalidResponse
    }
  }
}
