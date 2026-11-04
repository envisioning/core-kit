import Foundation
import OSLog

public enum CoreAgentClientError: LocalizedError, Sendable {
  case missingToken
  case invalidResponse
  case unsupportedOperation(String)
  case api(status: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingToken: "Add a Core personal access token in Settings."
    case .invalidResponse: "Core returned an invalid response."
    case .unsupportedOperation(let operation): "Core does not publish the \(operation) operation."
    case .api(_, let message): message
    }
  }
}

/// Result of exchanging a Supabase session for a Core personal access token.
public struct CorePATExchange: Decodable, Sendable {
  public let token: String
  public let scopes: [String]
  public let expiresAt: String?
  public let email: String?
}

public struct CRMContactMergeResult: Codable, Sendable {
  public let auditId: String
  public let survivorId: String
  public let mergedContactIds: [String]
  public let fieldConflicts: [String: JSONValue]
  public let relationCounts: [String: Int]
}

public actor CoreAgentClient {
  public static let productionURL = ServerConfig.productionURL

  private let baseURL: URL
  private let space: AgentSpace
  private let tokenProvider: @Sendable () -> String?
  private let session: URLSession
  private let integration: String
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let logger = Logger(subsystem: "work.starlings.corekit", category: "CoreAgentClient")
  private var operationsByID: [String: CRMOperationContract] = [:]

  private func debugLog(_ message: String) {
    #if DEBUG
      print("[CoreAgentClient] \(message)")
    #endif
  }

  public init(
    baseURL: URL = ServerConfig.baseURL,
    space: AgentSpace = .crm,
    session: URLSession = .shared,
    integration: String = "ios",
    tokenProvider: @escaping @Sendable () -> String?
  ) {
    self.baseURL = baseURL
    self.space = space
    self.session = session
    self.integration = integration
    self.tokenProvider = tokenProvider
  }

  /// The active space's endpoint prefix, e.g. `/api/agent` or `/api/agent/cms`.
  private var apiPrefix: String { space.apiPrefix }

  /// Exchanges a Supabase access token (from in-app Google sign-in) for a Core
  /// personal access token. Unlike every other call this does *not* use the
  /// stored PAT — there isn't one yet — so it builds its own request with the
  /// Supabase JWT as the bearer, hitting the server's `/auth/exchange` bridge.
  public func exchangeSupabaseSession(
    accessToken: String,
    deviceName: String
  ) async throws -> CorePATExchange {
    let url = baseURL.appending(path: "/api/agent/auth/exchange")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(integration, forHTTPHeaderField: "X-Envisioning-Integration")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": deviceName])

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CoreAgentClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let apiError = try? decoder.decode(APIErrorBody.self, from: data)
      throw CoreAgentClientError.api(
        status: http.statusCode,
        message: apiError?.error ?? "Sign-in failed (\(http.statusCode))."
      )
    }
    do {
      return try decoder.decode(CorePATExchange.self, from: data)
    } catch {
      throw CoreAgentClientError.invalidResponse
    }
  }

  public func entityContracts() async throws -> CRMEntityContractData {
    let envelope: AgentDataEnvelope<CRMEntityContractData> = try await request(
      path: "\(apiPrefix)/meta/entities")
    return envelope.data
  }

  public func registry() async throws -> CRMRegistryData {
    let envelope: AgentDataEnvelope<CRMRegistryData> = try await request(
      path: "\(apiPrefix)/meta/registry")
    configureRegistry(envelope.data)
    return envelope.data
  }

  public func configureRegistry(_ registry: CRMRegistryData) {
    operationsByID = Dictionary(uniqueKeysWithValues: registry.operations.map { ($0.id, $0) })
  }

  public func canExecute(operationID: String) -> Bool {
    guard let operation = operationsByID[operationID] else { return false }
    return operation.access?.canExecute ?? true
  }

  public func characteristics() async throws -> CRMCharacteristicsVocabulary {
    let envelope: AgentDataEnvelope<CRMCharacteristicsVocabulary> = try await request(
      path: "\(apiPrefix)/meta/characteristics")
    return envelope.data
  }

  public func navigation() async throws -> CRMNavigationData {
    let envelope: AgentDataEnvelope<CRMNavigationData> = try await request(
      path: "\(apiPrefix)/meta/navigation")
    return envelope.data
  }

  /// Assignable team members for `optionsSource: "members"` pickers (task
  /// `assigned_to`). CRM-space only; gated on `tasks:read` server-side.
  public func members() async throws -> [CRMMember] {
    let envelope: AgentDataEnvelope<[CRMMember]> = try await request(
      path: "\(apiPrefix)/members")
    return envelope.data
  }

  public func dashboard() async throws -> CRMDashboardSummary {
    let envelope: AgentDataEnvelope<CRMDashboardSummary> = try await request(
      path: "\(apiPrefix)/dashboard")
    return envelope.data
  }

  public func search(_ query: String, limit: Int = 8) async throws -> AgentSearchEnvelope {
    try await request(path: "\(apiPrefix)/search", queryItems: [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "limit", value: String(limit)),
    ])
  }

  /// Lists the signed-in member's shared favorite references from CRM.
  public func listFavorites() async throws -> [CRMFavorite] {
    let envelope: AgentDataEnvelope<[CRMFavorite]> = try await request(
      path: "/api/agent/favorites"
    )
    return envelope.data
  }

  /// Adds one favorite. Core's unique key makes repeating this call a no-op.
  public func addFavorite(kind: String, targetRef: String) async throws -> CRMFavorite {
    try await addFavorite(target: CRMFavoriteTarget(kind: kind, targetRef: targetRef))
  }

  public func addFavorite(target: CRMFavoriteTarget) async throws -> CRMFavorite {
    let input = FavoriteInput(kind: target.kind, targetRef: target.targetRef)
    let envelope: AgentDataEnvelope<CRMFavorite> = try await request(
      path: "/api/agent/favorites",
      method: "POST",
      body: try encoder.encode(input)
    )
    return envelope.data
  }

  /// Removes one favorite. Core treats a missing row as a successful removal.
  public func removeFavorite(kind: String, targetRef: String) async throws {
    try await removeFavorite(target: CRMFavoriteTarget(kind: kind, targetRef: targetRef))
  }

  public func removeFavorite(target: CRMFavoriteTarget) async throws {
    let _: AgentDataEnvelope<FavoriteRemoveResult> = try await request(
      path: "/api/agent/favorites",
      queryItems: [
        URLQueryItem(name: "kind", value: target.kind),
        URLQueryItem(name: "target_ref", value: target.targetRef),
      ],
      method: "DELETE"
    )
  }

  public func list(
    entity: String,
    query: String? = nil,
    limit: Int = 100,
    offset: Int = 0
  ) async throws -> AgentListEnvelope<CRMRecord> {
    var items = [
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
    return try await request(path: try operationPath("\(entity).list"), queryItems: items)
  }

  /// Lists a collection by direct space path (not a registry operation), with
  /// optional filter columns and server-side search. Used for large CMS
  /// collections that are only listable when scoped — e.g. technologies by
  /// `research_id` — where the client pages and searches server-side instead of
  /// caching the whole set. See docs/CMS_AGENT_ACCESS_MODEL.md.
  public func listCollection(
    entity: String,
    filters: [String: String] = [:],
    query: String? = nil,
    limit: Int = 50,
    offset: Int = 0
  ) async throws -> AgentListEnvelope<CRMRecord> {
    var items = [
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    for key in filters.keys.sorted() {
      items.append(URLQueryItem(name: key, value: filters[key]))
    }
    if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
    return try await request(path: "\(apiPrefix)/\(entity)", queryItems: items)
  }

  public func get(entity: String, id: String) async throws -> CRMRecord {
    let envelope: AgentDataEnvelope<CRMRecord> = try await request(
      path: try operationPath("\(entity).get", id: id))
    return envelope.data
  }

  public func related(
    entity: String,
    id: String,
    relation: String
  ) async throws -> CRMRelatedData {
    let envelope: AgentDataEnvelope<CRMRelatedData> = try await request(
      path: try operationPath("\(entity).\(relation).list", id: id))
    return envelope.data
  }

  public func save(
    entity: String,
    id: String? = nil,
    values: [String: JSONValue]
  ) async throws -> CRMRecord {
    let envelope: AgentDataEnvelope<CRMRecord> = try await request(
      path: try operationPath("\(entity).\(id == nil ? "create" : "update")", id: id),
      method: id == nil ? "POST" : "PATCH",
      body: try encoder.encode(values)
    )
    return envelope.data
  }

  public func delete(entity: String, id: String) async throws {
    let _: AgentDataEnvelope<DeleteResult> = try await request(
      path: try operationPath("\(entity).delete", id: id), method: "DELETE")
  }

  /// Detach a related record from its source without deleting it — the server
  /// clears the relation's foreign key, so the record survives unlinked.
  public func unlinkRelated(
    entity: String,
    id: String,
    relation: String,
    relatedID: String
  ) async throws {
    let _: AgentDataEnvelope<UnlinkResult> = try await request(
      path: try operationPath(
        "\(entity).\(relation).unlink",
        id: id,
        relatedID: relatedID
      ),
      method: "DELETE"
    )
  }

  public func mergeContacts(_ contactIDs: [String]) async throws -> CRMContactMergeResult {
    let input = ContactMergeInput(contactIDs: contactIDs)
    let envelope: AgentDataEnvelope<CRMContactMergeResult> = try await request(
      path: try operationPath("contacts.merge"),
      method: "POST",
      body: try encoder.encode(input)
    )
    return envelope.data
  }

  private func operationPath(
    _ operationID: String,
    id: String? = nil,
    relatedID: String? = nil
  ) throws -> String {
    guard let operation = operationsByID[operationID] else {
      if operationsByID.isEmpty {
        return try legacyOperationPath(operationID, id: id)
      }
      throw CoreAgentClientError.unsupportedOperation(operationID)
    }
    var path = operation.http.path
    if path.contains(":id") {
      guard let id else { throw CoreAgentClientError.unsupportedOperation(operationID) }
      path = path.replacingOccurrences(of: ":id", with: encodedPathComponent(id))
    }
    if path.contains(":relatedId") {
      guard let relatedID else { throw CoreAgentClientError.unsupportedOperation(operationID) }
      path = path.replacingOccurrences(of: ":relatedId", with: encodedPathComponent(relatedID))
    }
    return path
  }

  private func legacyOperationPath(_ operationID: String, id: String?) throws -> String {
    let components = operationID.split(separator: ".").map(String.init)
    guard let entity = components.first, let kind = components.last else {
      throw CoreAgentClientError.unsupportedOperation(operationID)
    }
    if components.count == 3, kind == "list", let id {
      return "\(apiPrefix)/entities/\(entity)/\(encodedPathComponent(id))/related/\(components[1])"
    }
    if kind == "list" || kind == "create" {
      return "\(apiPrefix)/\(entity)"
    }
    if let id {
      return "\(apiPrefix)/\(entity)/\(encodedPathComponent(id))"
    }
    throw CoreAgentClientError.unsupportedOperation(operationID)
  }

  private func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private struct DeleteResult: Codable, Sendable {
    let id: String
    let deleted: Bool
  }

  private struct UnlinkResult: Codable, Sendable {
    let id: String
    let unlinked: Bool
  }

  private struct FavoriteInput: Encodable, Sendable {
    let kind: String
    let targetRef: String

    enum CodingKeys: String, CodingKey {
      case kind
      case targetRef = "target_ref"
    }
  }

  private struct FavoriteRemoveResult: Codable, Sendable {
    let removed: Bool
  }

  private struct ContactMergeInput: Encodable, Sendable {
    let contactIDs: [String]

    enum CodingKeys: String, CodingKey {
      case contactIDs = "contact_ids"
    }
  }

  private struct APIErrorBody: Codable {
    let error: String
    let code: String?
  }

  private func request<Response: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    body: Data? = nil
  ) async throws -> Response {
    guard
      let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { throw CoreAgentClientError.missingToken }

    debugLog("PAT loaded (\(token.count) characters)")

    var components = URLComponents(
      url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
    if !queryItems.isEmpty { components?.queryItems = queryItems }
    guard let url = components?.url else { throw CoreAgentClientError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(integration, forHTTPHeaderField: "X-Envisioning-Integration")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.httpBody = body

    let requestLabel = "\(method) \(path)"
    let startedAt = ContinuousClock.now
    logger.info("Request \(requestLabel, privacy: .public)")
    debugLog("Request: \(requestLabel) host=\(url.host ?? "unknown")")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      debugLog("Cancelled: \(requestLabel)")
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      debugLog("Cancelled: \(requestLabel)")
      throw error
    } catch {
      logger.error(
        "Network failure for \(requestLabel, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      debugLog("Network failure: \(requestLabel) \(error.localizedDescription)")
      throw error
    }
    guard let http = response as? HTTPURLResponse else {
      logger.error("Invalid response for \(requestLabel, privacy: .public)")
      debugLog("Invalid response: \(requestLabel)")
      throw CoreAgentClientError.invalidResponse
    }
    let elapsed = startedAt.duration(to: .now)
    let elapsedMilliseconds = elapsed.components.seconds * 1_000
      + elapsed.components.attoseconds / 1_000_000_000_000_000
    logger.info(
      "Response \(requestLabel, privacy: .public) status=\(http.statusCode) duration=\(elapsedMilliseconds)ms bytes=\(data.count)"
    )
    debugLog(
      "Response: \(requestLabel) status=\(http.statusCode) duration=\(elapsedMilliseconds)ms bytes=\(data.count)"
    )
    guard (200..<300).contains(http.statusCode) else {
      let apiError = try? decoder.decode(APIErrorBody.self, from: data)
      let message = apiError.map { body in
        body.code.map { "\(body.error) [\($0)]" } ?? body.error
      } ?? "Core request failed (\(http.statusCode))."
      logger.error(
        "API error \(requestLabel, privacy: .public) status=\(http.statusCode) message=\(message, privacy: .public)"
      )
      debugLog("API error: \(requestLabel) status=\(http.statusCode) message=\(message)")
      throw CoreAgentClientError.api(status: http.statusCode, message: message)
    }
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      logger.error("Decode failed for \(requestLabel, privacy: .public): \(String(describing: error), privacy: .public)")
      debugLog("Decode failed: \(requestLabel) \(error.localizedDescription)")
      throw CoreAgentClientError.invalidResponse
    }
  }
}
