import Foundation
import Testing

@testable import DocsKit

/// Answers every request from a canned queue and records what went out.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
  nonisolated(unsafe) static var seen: [URLRequest] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.seen.append(request)
    let next = Self.queue.isEmpty ? (status: 500, body: "{}") : Self.queue.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: next.status, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(next.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private let detailJSON = #"""
  {"id":"d1","path":"/work/organization/acme/proposal","slug":"proposal","title":"Acme proposal",
   "kind":"markdown","visibility":"internal","status":"active","source_system":"native",
   "source_kind":null,"source_url":null,"editable":true,"version":2,"byte_size":12,
   "content_hash":"abc","tags":[],"subjects":[{"system":"core","kind":"organization","subject_id":"org-acme"}],
   "created_at":"2026-09-11T09:00:00.000Z","updated_at":"2026-09-11T09:30:00.000Z","updated_by":"rosa@example.com",
   "body_md":"Scope.","frontmatter":{},"links":[],"backlinks":[],"open_annotations":0}
  """#

@Suite(.serialized)
struct DocsClientTests {
  private func client(token: String? = "evd_test") -> DocsClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    StubProtocol.queue = []
    StubProtocol.seen = []
    return DocsClient(
      baseURL: URL(string: "https://docs.test")!,
      session: URLSession(configuration: configuration),
      tokenProvider: { token })
  }

  private func bodyOf(_ request: URLRequest) -> [String: Any] {
    let data = request.httpBody ?? request.httpBodyStream.map { stream in
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      return data
    } ?? Data()
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  @Test func decodesSnakeCaseIntoTheDetail() async throws {
    let client = client()
    StubProtocol.queue = [(200, detailJSON)]
    let detail = try await client.document(id: "d1")
    #expect(detail.contentHash == "abc")
    #expect(detail.subjects.first?.subjectId == "org-acme")
    #expect(detail.bodyMd == "Scope.")
    #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer evd_test")
  }

  @Test func listsBySubjectRef() async throws {
    let client = client()
    StubProtocol.queue = [(200, #"{"documents":[],"total":0}"#)]
    _ = try await client.documents(about: DocsSubject(kind: "organization", subjectId: "org-acme"))
    let url = try #require(StubProtocol.seen.first?.url)
    #expect(url.path == "/api/docs")
    #expect(url.query?.contains("subject=core:organization:org-acme") == true)
  }

  @Test func createSendsSnakeCaseAndSubjects() async throws {
    let client = client()
    StubProtocol.queue = [(201, detailJSON)]
    _ = try await client.create(
      DocsCreateDocument(
        title: "Acme proposal", folderPath: "/work/organization/acme",
        subjects: [DocsSubject(kind: "organization", subjectId: "org-acme")], message: "Created from Meet"))
    let sent = bodyOf(try #require(StubProtocol.seen.first))
    #expect(sent["folder_path"] as? String == "/work/organization/acme")
    #expect(sent["path"] == nil)
    let subjects = try #require(sent["subjects"] as? [[String: Any]])
    #expect(subjects.first?["subject_id"] as? String == "org-acme")
  }

  @Test func updateCarriesTheHashItReadAndSurfacesMismatch() async throws {
    let client = client()
    StubProtocol.queue = [(409, #"{"error":"The document changed.","code":"hash_mismatch"}"#)]
    await #expect(throws: DocsClientError.hashMismatch) {
      try await client.update(id: "d1", DocsUpdateDocument(bodyMd: "New", ifContentHash: "abc"))
    }
    let sent = bodyOf(try #require(StubProtocol.seen.first))
    #expect(sent["if_content_hash"] as? String == "abc")
    #expect(sent["body_md"] as? String == "New")
    #expect(sent["title"] == nil)
  }

  @Test func readOnlyAndUnauthorizedAreTheirOwnErrors() async throws {
    let client = client()
    StubProtocol.queue = [(409, #"{"error":"This document mirrors core/note — edit it at the source.","code":"read_only"}"#)]
    await #expect(throws: DocsClientError.readOnly("This document mirrors core/note — edit it at the source.")) {
      try await client.update(id: "d1", DocsUpdateDocument(bodyMd: "x"))
    }
    StubProtocol.queue = [(401, #"{"error":"Sign in.","code":"unauthorized"}"#)]
    await #expect(throws: DocsClientError.unauthorized) { try await client.document(id: "d1") }
  }

  @Test func browserCallsHitTheRightRoutesAndDecode() async throws {
    let client = client()
    StubProtocol.queue = [
      (200, #"{"folders":[{"id":"f1","path":"/work","slug":"work","title":"Work","parent_id":null,"depth":0,"icon":null,"description":null,"source_key":null,"document_count":3}]}"#),
      (200, #"{"categories":[{"category":"proposal","label":"Proposals","count":2}],"folders":[{"path":"/work","title":"Work","count":3}],"total":5}"#),
      (200, #"{"documents":[],"total":0}"#),
      (200, #"{"grants":[{"id":"g1","document_id":"d1","folder_id":null,"url":"https://docs.test/d/abc","email":null,"role":"viewer","label":null,"require_verification":false,"created_by":"rosa@example.com","created_at":"2026-09-11T00:00:00.000Z","expires_at":null,"revoked_at":null,"last_used_at":null,"use_count":0}]}"#),
      (204, ""),
    ]
    let tree = try await client.tree()
    #expect(tree.first?.documentCount == 3)
    let summary = try await client.summary()
    #expect(summary.categories.first?.category == "proposal")
    #expect(summary.total == 5)
    _ = try await client.documents(category: "nda")
    let grants = try await client.grants(for: "d1")
    #expect(grants.first?.role == .viewer)
    try await client.revokeGrant(id: "g1")
    let paths = StubProtocol.seen.map { $0.url!.path }
    #expect(paths == ["/api/tree", "/api/docs/summary", "/api/docs", "/api/docs/d1/grants", "/api/grants/g1"])
    #expect(StubProtocol.seen[2].url!.query?.contains("category=nda") == true)
    #expect(StubProtocol.seen[4].httpMethod == "DELETE")
  }

  @Test func writtenDocumentsAskForNativeSourceOnly() async throws {
    let client = client()
    StubProtocol.queue = [(200, #"{"documents":[],"total":0}"#)]
    _ = try await client.writtenDocuments(limit: 50)
    let url = StubProtocol.seen[0].url!
    #expect(url.path == "/api/docs")
    #expect(url.query?.contains("source=native") == true)
    #expect(url.query?.contains("limit=50") == true)
  }

  @Test func annotationsGroupIntoThreadsAndHitTheirRoutes() async throws {
    let client = client()
    let comment = { (id: String, thread: String, parent: String?, at: String, status: String) -> String in
      #"{"id":"\#(id)","document_id":"d1","document_version":1,"thread_id":"\#(thread)","parent_id":\#(parent.map { "\"\($0)\"" } ?? "null"),"author":"ada@example.com","author_name":null,"author_kind":"staff","body_md":"Hi","anchor":{"type":"text","quote":"the ask"},"status":"\#(status)","resolved_by":null,"resolved_at":null,"created_at":"\#(at)","updated_at":"\#(at)"}"#
    }
    StubProtocol.queue = [
      (200, "[\(comment("a2", "a1", "a1", "2026-09-15T09:00:00.000Z", "open")),\(comment("a1", "a1", nil, "2026-09-15T08:00:00.000Z", "open")),\(comment("b1", "b1", nil, "2026-09-14T08:00:00.000Z", "resolved"))]"),
      (201, comment("c1", "c1", nil, "2026-09-15T10:00:00.000Z", "open")),
      (200, comment("a1", "a1", nil, "2026-09-15T08:00:00.000Z", "resolved")),
      (204, ""),
    ]
    let threads = DocsThread.threads(try await client.annotations(for: "d1"))
    #expect(threads.map(\.id) == ["a1", "b1"])
    #expect(threads[0].replies.map(\.id) == ["a2"])
    #expect(threads[0].isOpen && !threads[1].isOpen)
    #expect(threads[0].root.anchor?.quote == "the ask")
    _ = try await client.createAnnotation(for: "d1", DocsCreateAnnotation(bodyMd: "New", parentId: nil))
    _ = try await client.updateAnnotation(id: "a1", DocsUpdateAnnotation(status: "resolved"))
    try await client.deleteAnnotation(id: "a1")
    let paths = StubProtocol.seen.map { "\($0.httpMethod!) \($0.url!.path)" }
    #expect(paths == ["GET /api/docs/d1/annotations", "POST /api/docs/d1/annotations", "PATCH /api/annotations/a1", "DELETE /api/annotations/a1"])
    let posted = bodyOf(StubProtocol.seen[1])
    #expect(posted["body_md"] as? String == "New")
    #expect(posted["anchor"] == nil)
  }

  @Test func updateEncodesCategoryClearButNotAbsence() async throws {
    let client = client()
    StubProtocol.queue = [(200, detailJSON), (200, detailJSON)]
    _ = try await client.update(id: "d1", DocsUpdateDocument(bodyMd: "x"))
    _ = try await client.update(id: "d1", DocsUpdateDocument(category: .some(nil)))
    let absent = bodyOf(StubProtocol.seen[0])
    let cleared = bodyOf(StubProtocol.seen[1])
    #expect(absent["category"] == nil)
    #expect(cleared.keys.contains("category"))
    #expect(cleared["category"] is NSNull)
  }

  @Test func refusesToCallOutWithoutAToken() async throws {
    let client = client(token: nil)
    await #expect(throws: DocsClientError.missingToken) { try await client.document(id: "d1") }
    #expect(StubProtocol.seen.isEmpty)
  }
}

struct DocsDraftStoreTests {
  @Test func roundTripsAndClears() {
    let store = DocsDraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "docskit-\(UUID().uuidString)"))
    #expect(store.read("d1") == nil)
    store.write("d1", body: "# Draft\n")
    #expect(store.read("d1") == "# Draft\n")
    store.write("new:core:organization:x", body: "y")
    #expect(store.read("new:core:organization:x") == "y")
    store.clear("d1")
    #expect(store.read("d1") == nil)
  }
}
