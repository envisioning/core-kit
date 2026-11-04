import CryptoKit
import Foundation

// Attended releases (ADR 0007 decisions 5 and 10 to 12 in envisioning/meet,
// envisioning/keep#5). The Swift half of `releases.ts` and of `sealRelease`
// in Keep's `packages/crypto`.
//
// An agent asks in a Meet thread for one item, with a P-256 public key it
// made for that one request. A member of the item's vault approves here.
// This device opens the item, seals its body under a one-time release key
// and wraps that key to the agent's session key. Keep stores only the
// sealed body and the wrap. The release key is dropped with the call.
//
//   body   the item's `KeepItemBody` JSON, AES-256-GCM,
//          AAD = `release:<release id>:<vault id>:<item id>`.
//   wrap   `wrapKey(releaseKey, toPublicKey: sessionPublicKey)`, as for a person.
//
// The body, not a key: a person's vault key opens every item in the vault,
// so wrapping it would release the whole vault.

/// How long a release may live. The approver picks; Keep refuses outside these.
public enum KeepReleaseLimits {
  public static let minSeconds = 60
  public static let maxSeconds = 24 * 60 * 60
  /// ADR 0007 decision 11.
  public static let defaultSeconds = 15 * 60
}

/// `POST /api/vaults/:id/releases`. `id` is the request id from the agent's card.
public struct KeepCreateReleaseInput: Encodable, Sendable {
  public var id: String
  public var itemId: String
  public var agent: String
  public var task: String
  public var reason: String?
  public var sessionPublicKey: String
  public var expiresInSeconds: Int
  public var sealed: KeepSealed
  public var wrappedKey: KeepWrappedKey
}

/// One release as a person sees it. Never the sealed body, never the wrap.
public struct KeepRelease: Decodable, Equatable, Sendable, Identifiable {
  public struct Agent: Decodable, Equatable, Sendable {
    public var address: String
    public var name: String
  }

  public var id: String
  public var vaultId: String
  public var itemId: String
  public var itemName: String
  public var agent: Agent
  public var approver: String
  public var task: String
  public var reason: String?
  /// `live`, `used`, `ended` or `expired`. Open: a newer Keep may add one.
  public var status: String
  public var createdAt: String
  public var expiresAt: String
  public var fetchedAt: String?
  public var endedAt: String?
  public var endedBy: String?

  public var expiryDate: Date? { KeepRelease.date(expiresAt) }

  static func date(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}

/// What an agent asked for, as its card says it. The item is named, never valued.
public struct KeepReleaseRequest: Equatable, Sendable {
  /// The agent's request id: becomes the release id. Lowercase UUID.
  public var requestId: String
  /// A vault id or name.
  public var vault: String
  /// An item id or name.
  public var item: String
  /// The agent's roster address.
  public var agent: String
  public var task: String
  public var reason: String?
  /// Raw P-256 public key, base64url, the agent made for this request.
  public var sessionPublicKey: String

  public init(requestId: String, vault: String, item: String, agent: String, task: String, reason: String?, sessionPublicKey: String) {
    self.requestId = requestId
    self.vault = vault
    self.item = item
    self.agent = agent
    self.task = task
    self.reason = reason
    self.sessionPublicKey = sessionPublicKey
  }
}

public enum KeepReleaseError: LocalizedError, Equatable, Sendable {
  /// No vault of this person's matches the reference.
  case vaultNotFound
  /// Two of this person's vaults carry that name.
  case vaultAmbiguous
  case itemNotFound
  case itemAmbiguous

  public var errorDescription: String? {
    switch self {
    case .vaultNotFound: "None of your vaults matches this request."
    case .vaultAmbiguous: "Two of your vaults have this name. The agent must name the vault by its id."
    case .itemNotFound: "The vault has no item that matches this request."
    case .itemAmbiguous: "Two items in the vault have this name. The agent must name the item by its id."
    }
  }
}

extension KeepCrypto {
  private static func releaseAAD(releaseId: String, vaultId: String, itemId: String) -> Data {
    Data("release:\(releaseId):\(vaultId):\(itemId)".utf8)
  }

  /// The approving device's half: seal the opened body under a fresh release
  /// key and wrap that key to the agent's session public key.
  public static func sealRelease(
    _ body: KeepItemBody, sessionPublicKey: String, releaseId: String, vaultId: String, itemId: String
  ) throws -> (sealed: KeepSealed, wrappedKey: KeepWrappedKey) {
    let releaseKey = randomBytes(32)
    let plaintext = try JSONEncoder().encode(body)
    let nonce = AES.GCM.Nonce()
    let box = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: releaseKey), nonce: nonce,
      authenticating: releaseAAD(releaseId: releaseId, vaultId: vaultId, itemId: itemId))
    let sealed = KeepSealed(iv: base64URL(Data(nonce)), ciphertext: base64URL(box.ciphertext + box.tag))
    return (sealed, try wrapKey(releaseKey, toPublicKey: sessionPublicKey))
  }

  /// The agent's half: unwrap the release key with the session private key, then open the body.
  public static func openRelease(
    sealed: KeepSealed, wrappedKey: KeepWrappedKey,
    sessionPrivateKey: P256.KeyAgreement.PrivateKey, sessionPublicKey: String,
    releaseId: String, vaultId: String, itemId: String
  ) throws -> KeepItemBody {
    let releaseKey = try unwrapKey(wrappedKey, privateKey: sessionPrivateKey, ownPublicKey: sessionPublicKey)
    let combined = try data(base64URL: sealed.ciphertext)
    guard combined.count >= 16 else { throw KeepCryptoError.cannotOpen }
    let plaintext: Data
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: try data(base64URL: sealed.iv)),
        ciphertext: combined.prefix(combined.count - 16), tag: combined.suffix(16))
      plaintext = try AES.GCM.open(
        box, using: SymmetricKey(data: releaseKey),
        authenticating: releaseAAD(releaseId: releaseId, vaultId: vaultId, itemId: itemId))
    } catch {
      throw KeepCryptoError.cannotOpen
    }
    do {
      return try JSONDecoder().decode(KeepItemBody.self, from: plaintext)
    } catch {
      throw KeepCryptoError.badEncoding
    }
  }
}

extension KeepClient {
  public func createRelease(_ vaultId: String, _ input: KeepCreateReleaseInput) async throws -> KeepRelease {
    try await send("POST", "/api/vaults/\(vaultId)/releases", body: input)
  }

  /// One release's state. Never its payload.
  public func release(_ vaultId: String, id releaseId: String) async throws -> KeepRelease {
    try await send("GET", "/api/vaults/\(vaultId)/releases/\(releaseId)")
  }

  /// End now. Any member may; ending a closed release changes nothing.
  public func endRelease(_ vaultId: String, id releaseId: String) async throws -> KeepRelease {
    try await send("POST", "/api/vaults/\(vaultId)/releases/\(releaseId)/end")
  }
}

extension KeepSession {
  /// The vault and the item a request names, among this person's vaults: by
  /// id first, then by name (case and accents ignored). A machine vault is
  /// never in the list, so it never matches.
  public func resolveRelease(_ request: KeepReleaseRequest) async throws -> (vault: KeepVaultDetail, item: KeepItemSummary) {
    if !vaultsLoaded { await loadVaults() }
    let vaultRef = request.vault.trimmingCharacters(in: .whitespacesAndNewlines)
    let byVaultId = vaults.first { $0.id == vaultRef.lowercased() }
    let byVaultName = vaults.filter { Self.sameName($0.name, vaultRef) }
    guard let summary = byVaultId ?? byVaultName.first else { throw KeepReleaseError.vaultNotFound }
    if byVaultId == nil, byVaultName.count > 1 { throw KeepReleaseError.vaultAmbiguous }
    let vault = try await client.vault(summary.id)
    let itemRef = request.item.trimmingCharacters(in: .whitespacesAndNewlines)
    let byItemId = vault.items.first { $0.id == itemRef.lowercased() }
    let byItemName = vault.items.filter { Self.sameName($0.name, itemRef) }
    guard let item = byItemId ?? byItemName.first else { throw KeepReleaseError.itemNotFound }
    if byItemId == nil, byItemName.count > 1 { throw KeepReleaseError.itemAmbiguous }
    return (vault, item)
  }

  private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }

  /// Approve: reveal the item (audited as this person's reveal), open it
  /// here, seal it to the agent's session key, and post the release. The
  /// plaintext and the release key go out of scope with this call.
  public func release(
    _ request: KeepReleaseRequest, vault: KeepVaultDetail, item: KeepItemSummary, expiresInSeconds: Int
  ) async throws -> KeepRelease {
    let body = try await open(item, in: vault)
    let releaseId = request.requestId.lowercased()
    let payload = try KeepCrypto.sealRelease(
      body, sessionPublicKey: request.sessionPublicKey, releaseId: releaseId, vaultId: vault.id, itemId: item.id)
    let seconds = min(max(expiresInSeconds, KeepReleaseLimits.minSeconds), KeepReleaseLimits.maxSeconds)
    return try await client.createRelease(
      vault.id,
      KeepCreateReleaseInput(
        id: releaseId, itemId: item.id, agent: request.agent.lowercased(), task: request.task, reason: request.reason,
        sessionPublicKey: request.sessionPublicKey, expiresInSeconds: seconds,
        sealed: payload.sealed, wrappedKey: payload.wrappedKey))
  }

  /// End a release now. Needs only the token: ending opens nothing.
  public func endRelease(vaultId: String, releaseId: String) async throws -> KeepRelease {
    try await client.endRelease(vaultId, id: releaseId.lowercased())
  }
}
