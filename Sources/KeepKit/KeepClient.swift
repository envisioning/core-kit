import Foundation

/// A 204: nothing came back, and nothing was expected.
public struct KeepEmpty: Decodable, Sendable { public init() {} }

public enum KeepClientError: LocalizedError, Sendable, Equatable {
  case missingToken
  case invalidResponse
  case unauthorized
  /// The vault's key moved under the client. Reload, seal again.
  case staleRotation(String)
  case api(status: Int, code: String?, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingToken: "Connect Keep first."
    case .invalidResponse: "Keep returned an invalid response."
    case .unauthorized: "Keep no longer accepts this device's token. Reconnect in Settings."
    case .staleRotation(let message): message
    case .api(_, _, let message): message
    }
  }
}

/// The device's line to keep.envisioning.com. Same shape as `DocsClient`: an
/// actor, a base URL, and a closure that yields the current bearer — the
/// token itself lives in the app's credential store, never here.
///
/// Every method here moves ciphertext or metadata. Nothing in this file
/// can open anything; that is `KeepCrypto`, driven by `KeepSession`.
public actor KeepClient {
  /// The served origin. Never the Gandi redirect: a redirected POST arrives
  /// as a GET with no body. Also the passkey relying party.
  public static let productionURL = URL(string: "https://keep.envisioning.workers.dev")!

  private let baseURL: URL
  private let tokenProvider: @Sendable () -> String?
  private let session: URLSession

  public init(
    baseURL: URL = KeepClient.productionURL,
    session: URLSession = .shared,
    tokenProvider: @escaping @Sendable () -> String?
  ) {
    self.baseURL = baseURL
    self.session = session
    self.tokenProvider = tokenProvider
  }

  public var relyingPartyIdentifier: String { baseURL.host ?? "keep.envisioning.workers.dev" }

  // MARK: Identity and keys

  public func me() async throws -> KeepMe {
    try await request("GET", "/api/me")
  }

  public func enrol(_ input: KeepEnrolInput, replace: Bool = false) async throws -> KeepStaffKey {
    try await request("PUT", "/api/keys/me", query: replace ? [("replace", "1")] : [], body: input)
  }

  /// Add a way to unwrap: the same private key, sealed under another method.
  public func addWrap(_ wrap: KeepKeyWrap) async throws -> KeepStaffKey {
    try await request("POST", "/api/keys/me/wraps", body: wrap)
  }

  public func directory() async throws -> [KeepDirectoryEntry] {
    struct Envelope: Decodable { let entries: [KeepDirectoryEntry] }
    let envelope: Envelope = try await request("GET", "/api/keys/directory")
    return envelope.entries
  }

  public func recoveryKey() async throws -> KeepRecoveryKey? {
    struct Envelope: Decodable { let recovery: KeepRecoveryKey? }
    let envelope: Envelope = try await request("GET", "/api/recovery")
    return envelope.recovery
  }

  public func setRecoveryKey(_ input: KeepSetRecoveryInput) async throws -> KeepRecoveryKey {
    try await request("PUT", "/api/recovery", body: input)
  }

  /// A member adds the recovery wrap a vault made before the key existed is missing.
  public func coverVault(_ vaultId: String, recoveryWrappedKey: KeepWrappedKey) async throws -> KeepVaultDetail {
    struct Body: Encodable { let recoveryWrappedKey: KeepWrappedKey }
    return try await request("POST", "/api/vaults/\(vaultId)/recovery", body: Body(recoveryWrappedKey: recoveryWrappedKey))
  }

  /// Every covered vault with its recovery wrap. Audited server-side.
  public func recoveryVaults() async throws -> [KeepRecoveryVaultEntry] {
    struct Envelope: Decodable { let vaults: [KeepRecoveryVaultEntry] }
    let envelope: Envelope = try await request("GET", "/api/recovery/vaults")
    return envelope.vaults
  }

  /// Join a vault opened through recovery. Audited server-side, loudly.
  public func recoveryJoin(_ vaultId: String, wrappedKey: KeepWrappedKey) async throws {
    struct Body: Encodable { let wrappedKey: KeepWrappedKey }
    let _: KeepEmpty = try await request("POST", "/api/recovery/vaults/\(vaultId)/join", body: Body(wrappedKey: wrappedKey))
  }

  // MARK: Vaults

  public func vaults() async throws -> [KeepVaultSummary] {
    struct Envelope: Decodable { let vaults: [KeepVaultSummary] }
    let envelope: Envelope = try await request("GET", "/api/vaults")
    return envelope.vaults
  }

  public func vault(_ id: String) async throws -> KeepVaultDetail {
    try await request("GET", "/api/vaults/\(id)")
  }

  public func createVault(_ input: KeepCreateVaultInput) async throws -> KeepVaultDetail {
    try await request("POST", "/api/vaults", body: input)
  }

  public func updateVault(_ id: String, name: String, icon: String?, projectId: String?) async throws -> KeepVaultDetail {
    struct Body: Encodable {
      let name: String
      let icon: String?
      let projectId: String?
      private enum CodingKeys: String, CodingKey { case name, icon, projectId }
      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(projectId, forKey: .projectId)
      }
    }
    return try await request("PATCH", "/api/vaults/\(id)", body: Body(name: name, icon: icon, projectId: projectId))
  }

  public func deleteVault(_ id: String) async throws {
    let _: KeepEmpty = try await request("DELETE", "/api/vaults/\(id)")
  }

  public func grant(_ vaultId: String, _ member: KeepMemberWrap) async throws -> KeepVaultDetail {
    try await request("POST", "/api/vaults/\(vaultId)/members", body: member)
  }

  public func rotate(_ vaultId: String, _ input: KeepRotateInput) async throws -> KeepVaultDetail {
    try await request("POST", "/api/vaults/\(vaultId)/rotate", body: input)
  }

  public func audit(vault vaultId: String) async throws -> [KeepAuditEvent] {
    struct Envelope: Decodable { let events: [KeepAuditEvent] }
    let envelope: Envelope = try await request("GET", "/api/vaults/\(vaultId)/audit")
    return envelope.events
  }

  public func recentAudit() async throws -> [KeepAuditEvent] {
    struct Envelope: Decodable { let events: [KeepAuditEvent] }
    let envelope: Envelope = try await request("GET", "/api/audit")
    return envelope.events
  }

  // MARK: Items

  public func createItem(_ vaultId: String, _ input: KeepCreateItemInput) async throws -> KeepItemDetail {
    try await request("POST", "/api/vaults/\(vaultId)/items", body: input)
  }

  /// The reveal: one ciphertext, one audit row under this person's name.
  public func reveal(_ vaultId: String, item itemId: String) async throws -> KeepItemDetail {
    try await request("GET", "/api/vaults/\(vaultId)/items/\(itemId)")
  }

  public func updateItem(_ vaultId: String, item itemId: String, _ input: KeepUpdateItemInput) async throws -> KeepItemDetail {
    try await request("PATCH", "/api/vaults/\(vaultId)/items/\(itemId)", body: input)
  }

  public func deleteItem(_ vaultId: String, item itemId: String) async throws {
    let _: KeepEmpty = try await request("DELETE", "/api/vaults/\(vaultId)/items/\(itemId)")
  }

  // MARK: Devices

  public func deviceTokens() async throws -> [KeepDeviceToken] {
    struct Envelope: Decodable { let tokens: [KeepDeviceToken] }
    let envelope: Envelope = try await request("GET", "/api/tokens")
    return envelope.tokens
  }

  public func revokeDeviceToken(_ id: String) async throws {
    let _: KeepEmpty = try await request("DELETE", "/api/tokens/\(id)")
  }

  // MARK: Plumbing

  /// The request path for extensions in other files of this module.
  func send<Response: Decodable>(
    _ method: String, _ path: String, query: [(String, String)] = [], body: (any Encodable)? = nil
  ) async throws -> Response {
    try await request(method, path, query: query, body: body)
  }

  private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
  }

  private struct ErrorBody: Decodable {
    let error: String?
    let code: String?
  }

  private func request<Response: Decodable>(
    _ method: String,
    _ path: String,
    query: [(String, String)] = [],
    body: (any Encodable)? = nil
  ) async throws -> Response {
    guard let token = tokenProvider(), !token.isEmpty else { throw KeepClientError.missingToken }

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
      request.httpBody = try KeepCoding.encoder.encode(AnyEncodable(body))
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw KeepClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let parsed = try? KeepCoding.decoder.decode(ErrorBody.self, from: data)
      switch (http.statusCode, parsed?.code) {
      case (401, _): throw KeepClientError.unauthorized
      case (409, "stale_rotation"): throw KeepClientError.staleRotation(parsed?.error ?? "The vault changed; reload.")
      default:
        throw KeepClientError.api(
          status: http.statusCode, code: parsed?.code,
          message: parsed?.error ?? "Keep answered \(http.statusCode).")
      }
    }
    if data.isEmpty, let empty = KeepEmpty() as? Response { return empty }
    do {
      return try KeepCoding.decoder.decode(Response.self, from: data)
    } catch {
      throw KeepClientError.invalidResponse
    }
  }
}
