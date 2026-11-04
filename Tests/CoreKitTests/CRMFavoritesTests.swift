import Foundation
import Testing

@testable import CoreKit

// Serialized: the tests share FavoritesURLProtocolStub's static responses and
// captured requests, and in parallel one test read the other's requests.
@Suite(.serialized)
struct CRMFavoritesTests {
  private let favoriteJSON = #"{"kind":"future.kind","target_ref":"doc:Folder:MixedCase","created_at":"2026-09-24T10:00:00.000Z"}"#

  @Test func futureFavoriteKindsDecodeAndKeepStableReferenceKey() throws {
    let favorite = try JSONDecoder().decode(CRMFavorite.self, from: Data(favoriteJSON.utf8))
    let target = CRMFavoriteTarget(kind: "future.kind", targetRef: "doc:Folder:MixedCase")

    #expect(favorite.kind == "future.kind")
    #expect(favorite.targetRef == "doc:Folder:MixedCase")
    #expect(favorite.stableKey == "future.kind:doc:Folder:MixedCase")
    #expect(favorite.target == target)
    #expect(target.id == "future.kind:doc:Folder:MixedCase")
    #expect(
      CRMFavorite.stableKey(kind: "docs.document", targetRef: "a:b")
        == "docs.document:a:b"
    )
  }

  private func contract(_ id: String, read: Bool = true, canRead: Bool = true) throws -> CRMEntityContract {
    let json = """
      {"id":"\(id)","singularLabel":"X","pluralLabel":"Xs","icon":"star","primaryField":"name",
       "secondaryFields":[],
       "capabilities":{"list":true,"read":\(read),"create":false,"update":false,"delete":false},
       "access":{"canRead":\(canRead),"canWrite":false,"missingScopes":[]},
       "fields":[]}
      """
    return try JSONDecoder().decode(CRMEntityContract.self, from: Data(json.utf8))
  }

  private func record(_ id: String, _ fields: [String: JSONValue] = [:]) throws -> CRMRecord {
    var all = fields
    all["id"] = .string(id)
    return CRMRecord(fields: all)
  }

  @Test func recordsMapToTheirCanonicalFavoriteKind() throws {
    func target(_ entity: String, _ id: String, _ fields: [String: JSONValue] = [:], space: AgentSpace = .crm) throws -> CRMFavoriteTarget? {
      CRMFavoriteTarget(contract: try contract(entity), record: try record(id, fields), space: space)
    }

    #expect(try target("leads", "L1") == CRMFavoriteTarget(kind: "crm.lead", targetRef: "L1"))
    #expect(try target("projects", "P1") == CRMFavoriteTarget(kind: "crm.project", targetRef: "P1"))
    #expect(try target("tasks", "T1") == CRMFavoriteTarget(kind: "crm.task", targetRef: "T1"))
    #expect(
      try target("organizations", "O1", ["is_partner": .bool(true)])
        == CRMFavoriteTarget(kind: "crm.partner", targetRef: "O1"))
    #expect(
      try target("organizations", "O2")
        == CRMFavoriteTarget(kind: "core.record", targetRef: "organizations:O2"))
    #expect(
      try target("contacts", "C1") == CRMFavoriteTarget(kind: "core.record", targetRef: "contacts:C1"))
    #expect(
      try target("events", "E1", space: .cms) == CRMFavoriteTarget(kind: "cms.event", targetRef: "E1"))
    // An entity Core's catalog does not list, and a CRM-space `events`, are not favoriteable.
    #expect(try target("events", "E1") == nil)
    #expect(try target("unknown_entity", "U1") == nil)
  }

  @Test func recordsWithoutReadAccessAreNotFavoriteable() throws {
    #expect(
      CRMFavoriteTarget(
        contract: try contract("leads", canRead: false), record: try record("L1"), space: .crm) == nil)
    #expect(
      CRMFavoriteTarget(
        contract: try contract("leads", read: false), record: try record("L1"), space: .crm) == nil)
  }

  @Test func destinationsRoundTripAndIgnoreKindsFromANewerServer() throws {
    #expect(
      CRMFavoriteTarget(kind: "crm.lead", targetRef: "L1").destination
        == CRMFavoriteDestination(entityID: "leads", recordID: "L1"))
    #expect(
      CRMFavoriteTarget(kind: "core.record", targetRef: "contacts:a:b").destination
        == CRMFavoriteDestination(entityID: "contacts", recordID: "a:b"))
    #expect(CRMFavoriteTarget(kind: "core.record", targetRef: "nonsense:1").destination == nil)
    #expect(CRMFavoriteTarget(kind: "core.record", targetRef: "contacts:").destination == nil)
    #expect(CRMFavoriteTarget(kind: "future.kind", targetRef: "x").destination == nil)
    #expect(CRMFavoriteTarget(kind: "cms.event", targetRef: "E1").space == .cms)
    #expect(CRMFavoriteTarget(kind: "crm.task", targetRef: "T1").space == .crm)
  }

  @Test func clientUsesTheSharedFavoritesEndpointsAndWireNames() async throws {
    FavoritesURLProtocolStub.configure(responses: [
      "GET": Data(#"{"data":[{"kind":"future.kind","target_ref":"doc:Folder:MixedCase","created_at":"2026-09-24T10:00:00.000Z"}]}"#.utf8),
      "POST": Data(#"{"data":{"kind":"future.kind","target_ref":"doc:Folder:MixedCase","created_at":"2026-09-24T10:00:00.000Z"}}"#.utf8),
      "DELETE": Data(#"{"data":{"removed":true}}"#.utf8),
    ])
    let client = makeClient()
    let target = CRMFavoriteTarget(kind: "future.kind", targetRef: "doc:Folder:MixedCase")

    let listed = try await client.listFavorites()
    let added = try await client.addFavorite(target: target)
    try await client.removeFavorite(target: target)

    #expect(listed.count == 1)
    #expect(added.stableKey == listed[0].stableKey)
    let requests = FavoritesURLProtocolStub.requests()
    #expect(requests.map(\.method) == ["GET", "POST", "DELETE"])
    #expect(requests.allSatisfy { $0.url.path == "/api/agent/favorites" })

    let post = try #require(requests.first { $0.method == "POST" })
    let postBody = try #require(post.body)
    let postJSON = try #require(JSONSerialization.jsonObject(with: postBody) as? [String: String])
    #expect(postJSON == ["kind": "future.kind", "target_ref": "doc:Folder:MixedCase"])

    let delete = try #require(requests.first { $0.method == "DELETE" })
    let query = try #require(URLComponents(url: delete.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(Dictionary(uniqueKeysWithValues: query.compactMap { item in item.value.map { (item.name, $0) } }) == [
      "kind": "future.kind",
      "target_ref": "doc:Folder:MixedCase",
    ])
  }

  @Test func repositoryUpdatesCacheAndOpenObserversAfterMutations() async throws {
    let token = "favorites-test-\(UUID().uuidString)"
    let accountKey = CRMCacheIdentity.accountKey(for: token)
    let cache = CRMCacheStore.shared
    defer { Task { try? await cache.purge(accountKey: accountKey) } }
    try await cache.saveFavorites([], accountKey: accountKey)

    FavoritesURLProtocolStub.configure(responses: [
      "POST": Data(#"{"data":{"kind":"future.kind","target_ref":"doc:Folder:MixedCase","created_at":"2026-09-24T10:00:00.000Z"}}"#.utf8),
      "DELETE": Data(#"{"data":{"removed":true}}"#.utf8),
    ])
    let repository = CRMRepository(client: makeClient(), cache: cache, tokenProvider: { token })
    let target = CRMFavoriteTarget(kind: "future.kind", targetRef: "doc:Folder:MixedCase")
    let stream = try await repository.observeFavorites()
    var updates = stream.makeAsyncIterator()

    #expect(await updates.next() == [])
    _ = try await repository.addFavorite(target: target)
    let afterAdd = try #require(await updates.next())
    #expect(afterAdd.map(\.stableKey) == ["future.kind:doc:Folder:MixedCase"])
    #expect(try await repository.cachedFavorites()?.count == 1)

    _ = try await repository.addFavorite(target: target)
    let afterDuplicateAdd = try #require(await updates.next())
    #expect(afterDuplicateAdd.count == 1)
    #expect(afterDuplicateAdd[0].createdAt == afterAdd[0].createdAt)

    try await repository.removeFavorite(target: target)
    #expect(await updates.next() == [])
    #expect(try await repository.cachedFavorites() == [])
  }

  private func makeClient() -> CoreAgentClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FavoritesURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    return CoreAgentClient(
      baseURL: URL(string: "https://core.example")!,
      session: session,
      tokenProvider: { "test-pat" }
    )
  }
}

private final class FavoritesURLProtocolStub: URLProtocol, @unchecked Sendable {
  struct CapturedRequest: Sendable {
    let method: String
    let url: URL
    let body: Data?
  }

  private static let lock = NSLock()
  private static var responseByMethod: [String: Data] = [:]
  private static var capturedRequests: [CapturedRequest] = []

  static func configure(responses: [String: Data]) {
    lock.withLock {
      responseByMethod = responses
      capturedRequests = []
    }
  }

  static func requests() -> [CapturedRequest] {
    lock.withLock { capturedRequests }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = request.httpMethod ?? "GET"
    let responseData = Self.lock.withLock { () -> Data in
      let body = Self.bodyData(from: request)
      Self.capturedRequests.append(
        CapturedRequest(method: method, url: request.url!, body: body)
      )
      return Self.responseByMethod[method] ?? Data()
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 4_096)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
