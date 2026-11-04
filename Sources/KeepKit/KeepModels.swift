import Foundation

// Wire shapes for keep.envisioning.com, mirroring `envisioning/keep`
// `packages/contracts/src/index.ts`. Snake case on the wire; `KeepCoding`
// does the mapping so no type carries its own CodingKeys.
//
// Read every type with the one rule in mind: a field is plaintext only when
// the server needs it to list, route or audit. Anything a person would call
// "the secret" arrives sealed.

public enum KeepSuite {
  public static let current = "keep-v1"
  /// Fixed PRF salt: the passkey returns the same 32 bytes on every unlock.
  public static let prfSaltLabel = "keep.envisioning.com/prf/v1"
  /// PBKDF2 rounds for the passphrase path. The server refuses fewer.
  public static let pbkdf2Iterations = 600_000
}

/// AES-256-GCM output: a 12-byte IV and ciphertext with the 16-byte tag appended.
public struct KeepSealed: Codable, Equatable, Sendable {
  public var iv: String
  public var ciphertext: String
  public init(iv: String, ciphertext: String) {
    self.iv = iv
    self.ciphertext = ciphertext
  }
}

/// A symmetric key wrapped to a P-256 public key (ECIES).
public struct KeepWrappedKey: Codable, Equatable, Sendable {
  public var ephemeralPublicKey: String
  public var iv: String
  public var ciphertext: String
  public init(ephemeralPublicKey: String, iv: String, ciphertext: String) {
    self.ephemeralPublicKey = ephemeralPublicKey
    self.iv = iv
    self.ciphertext = ciphertext
  }
}

/// How the private key is wrapped: by a passkey's PRF output or a passphrase.
public enum KeepWrapParams: Codable, Equatable, Sendable {
  case prf(credentialId: String, hkdfSalt: String)
  case passphrase(pbkdf2Salt: String, pbkdf2Iterations: Int)

  private enum CodingKeys: String, CodingKey {
    case method
    case credentialId
    case hkdfSalt
    case pbkdf2Salt
    case pbkdf2Iterations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .method) {
    case "prf":
      self = .prf(
        credentialId: try container.decode(String.self, forKey: .credentialId),
        hkdfSalt: try container.decode(String.self, forKey: .hkdfSalt))
    case "passphrase":
      self = .passphrase(
        pbkdf2Salt: try container.decode(String.self, forKey: .pbkdf2Salt),
        pbkdf2Iterations: try container.decode(Int.self, forKey: .pbkdf2Iterations))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .method, in: container, debugDescription: "Unknown wrap method \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .prf(let credentialId, let hkdfSalt):
      try container.encode("prf", forKey: .method)
      try container.encode(credentialId, forKey: .credentialId)
      try container.encode(hkdfSalt, forKey: .hkdfSalt)
    case .passphrase(let salt, let iterations):
      try container.encode("passphrase", forKey: .method)
      try container.encode(salt, forKey: .pbkdf2Salt)
      try container.encode(iterations, forKey: .pbkdf2Iterations)
    }
  }

  public var isPasskey: Bool {
    if case .prf = self { return true }
    return false
  }
}

public struct KeepEnrolInput: Encodable, Sendable {
  public var suite = KeepSuite.current
  public var publicKey: String
  public var wrappedPrivateKey: KeepSealed
  public var wrap: KeepWrapParams
  public init(publicKey: String, wrappedPrivateKey: KeepSealed, wrap: KeepWrapParams) {
    self.publicKey = publicKey
    self.wrappedPrivateKey = wrappedPrivateKey
    self.wrap = wrap
  }
}

/// One way to unwrap the private key. A person may hold several.
public struct KeepKeyWrap: Codable, Equatable, Sendable {
  public var wrappedPrivateKey: KeepSealed
  public var wrap: KeepWrapParams
  public init(wrappedPrivateKey: KeepSealed, wrap: KeepWrapParams) {
    self.wrappedPrivateKey = wrappedPrivateKey
    self.wrap = wrap
  }
}

public struct KeepStaffKey: Codable, Equatable, Sendable {
  public var email: String
  public var name: String
  public var suite: String
  public var publicKey: String
  /// The enrolment wrap; `wraps.first` is the same.
  public var wrappedPrivateKey: KeepSealed
  public var wrap: KeepWrapParams
  /// Every way this key can be unwrapped, enrolment first. One per method.
  public var wraps: [KeepKeyWrap]
  public var createdAt: String
  public var updatedAt: String

  public var passkeyWrap: KeepKeyWrap? { wraps.first { $0.wrap.isPasskey } }
  public var passphraseWrap: KeepKeyWrap? { wraps.first { !$0.wrap.isPasskey } }
}

public struct KeepMe: Decodable, Equatable, Sendable {
  public var email: String
  public var name: String
  public var enrolled: Bool
  public var key: KeepStaffKey?
  public var coreWebOrigin: String
}

public struct KeepDirectoryEntry: Decodable, Equatable, Sendable, Identifiable {
  public var email: String
  public var name: String
  public var publicKey: String
  public var enrolledAt: String
  public var id: String { email }
}

public struct KeepRecoveryKey: Decodable, Equatable, Sendable {
  public var publicKey: String
  public var holders: [String]
  public var createdBy: String
  public var createdAt: String
}

public struct KeepSetRecoveryInput: Encodable, Sendable {
  public var suite = KeepSuite.current
  public var publicKey: String
  public var holders: [String]
  public init(publicKey: String, holders: [String]) {
    self.publicKey = publicKey
    self.holders = holders
  }
}

/// A vault as a recovering person sees it: name and members in the clear,
/// the key sealed to the recovery key.
public struct KeepRecoveryVaultEntry: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var icon: String?
  public var projectId: String?
  public var keyVersion: Int
  public var memberCount: Int
  public var members: [String]
  public var recoveryWrappedKey: KeepWrappedKey
}

public struct KeepMemberWrap: Codable, Equatable, Sendable {
  public var email: String
  public var wrappedKey: KeepWrappedKey
  public init(email: String, wrappedKey: KeepWrappedKey) {
    self.email = email
    self.wrappedKey = wrappedKey
  }
}

public struct KeepCreateVaultInput: Encodable, Sendable {
  public var name: String
  public var icon: String?
  public var projectId: String?
  public var members: [KeepMemberWrap]
  public var recoveryWrappedKey: KeepWrappedKey?
  public init(name: String, icon: String? = nil, projectId: String?, members: [KeepMemberWrap], recoveryWrappedKey: KeepWrappedKey?) {
    self.name = name
    self.icon = icon
    self.projectId = projectId
    self.members = members
    self.recoveryWrappedKey = recoveryWrappedKey
  }

  // `recovery_wrapped_key` must be present as null when absent: the server
  // distinguishes "no recovery wrap" from a missing field.
  private enum CodingKeys: String, CodingKey { case name, icon, projectId, members, recoveryWrappedKey }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(icon, forKey: .icon)
    try container.encode(projectId, forKey: .projectId)
    try container.encode(members, forKey: .members)
    try container.encode(recoveryWrappedKey, forKey: .recoveryWrappedKey)
  }
}

public struct KeepRotateInput: Encodable, Sendable {
  public struct Item: Encodable, Sendable {
    public var id: String
    public var sealed: KeepSealed
    public init(id: String, sealed: KeepSealed) {
      self.id = id
      self.sealed = sealed
    }
  }
  public var keyVersion: Int
  public var members: [KeepMemberWrap]
  public var recoveryWrappedKey: KeepWrappedKey?
  public var items: [Item]
  public init(keyVersion: Int, members: [KeepMemberWrap], recoveryWrappedKey: KeepWrappedKey?, items: [Item]) {
    self.keyVersion = keyVersion
    self.members = members
    self.recoveryWrappedKey = recoveryWrappedKey
    self.items = items
  }
  private enum CodingKeys: String, CodingKey { case keyVersion, members, recoveryWrappedKey, items }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(keyVersion, forKey: .keyVersion)
    try container.encode(members, forKey: .members)
    try container.encode(recoveryWrappedKey, forKey: .recoveryWrappedKey)
    try container.encode(items, forKey: .items)
  }
}

/// The glyphs a vault can wear. A handful, chosen here so every client
/// draws the same set; the server stores the name and checks only its shape.
public enum KeepVaultIcon {
  public static let `default` = "lock.square.stack"
  public static let choices: [String] = [
    "lock.square.stack", "folder", "building.2", "person.2", "globe", "server.rack",
    "cloud", "creditcard", "envelope", "key", "terminal", "antenna.radiowaves.left.and.right",
    "megaphone", "cart", "banknote", "shippingbox",
  ]
  public static func symbol(_ icon: String?) -> String {
    guard let icon, !icon.isEmpty else { return `default` }
    return icon
  }
}

public struct KeepVaultSummary: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var icon: String?
  public var projectId: String?
  public var keyVersion: Int
  /// This caller's wrapped copy of the current vault key.
  public var wrappedKey: KeepWrappedKey
  /// Whether the current vault key is also wrapped to the recovery key.
  public var recoveryWrapped: Bool
  public var memberCount: Int
  public var itemCount: Int
  public var createdBy: String
  public var createdAt: String
  public var updatedAt: String
}

public struct KeepVaultMember: Decodable, Equatable, Sendable, Identifiable {
  public var email: String
  public var name: String
  public var grantedBy: String
  public var createdAt: String
  public var id: String { email }
}

public enum KeepItemKind: String, Codable, CaseIterable, Sendable {
  case login
  case apiKey = "api_key"
  case note
  case database
  case sshKey = "ssh_key"
  case other

  public var label: String {
    switch self {
    case .login: "Login"
    case .apiKey: "API key"
    case .note: "Note"
    case .database: "Database"
    case .sshKey: "SSH key"
    case .other: "Other"
    }
  }

  public var symbolName: String {
    switch self {
    case .login: "person.badge.key"
    case .apiKey: "key"
    case .note: "note.text"
    case .database: "cylinder"
    case .sshKey: "terminal"
    case .other: "lock"
    }
  }
}

public struct KeepItemSummary: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var vaultId: String
  public var name: String
  public var kind: KeepItemKind
  public var keyVersion: Int
  public var createdBy: String
  public var createdAt: String
  public var updatedAt: String
  public var rotatedAt: String?
}

public struct KeepItemDetail: Decodable, Equatable, Sendable {
  public var id: String
  public var vaultId: String
  public var name: String
  public var kind: KeepItemKind
  public var keyVersion: Int
  public var sealed: KeepSealed
}

public struct KeepVaultDetail: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var icon: String?
  public var projectId: String?
  public var keyVersion: Int
  public var wrappedKey: KeepWrappedKey
  public var memberCount: Int
  public var itemCount: Int
  public var createdBy: String
  public var createdAt: String
  public var updatedAt: String
  public var members: [KeepVaultMember]
  public var recoveryWrapped: Bool
  public var items: [KeepItemSummary]
}

/// The plaintext inside a sealed item. Never sent to the server as such.
/// Field names and order are the contract's, so the JSON the two clients
/// seal is the same document.
public struct KeepItemBody: Codable, Equatable, Sendable {
  public var username: String
  public var password: String
  public var url: String
  public var notes: String
  public var totp: String

  public init(username: String = "", password: String = "", url: String = "", notes: String = "", totp: String = "") {
    self.username = username
    self.password = password
    self.url = url
    self.notes = notes
    self.totp = totp
  }

  private enum CodingKeys: String, CodingKey { case username, password, url, notes, totp }

  /// Every field defaults to empty, as the contract's zod schema does, so a
  /// body sealed by an older client still opens.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
    url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    totp = try container.decodeIfPresent(String.self, forKey: .totp) ?? ""
  }
}

public struct KeepCreateItemInput: Encodable, Sendable {
  public var id: String
  public var name: String
  public var kind: KeepItemKind
  public var sealed: KeepSealed
  public var keyVersion: Int
  public init(id: String, name: String, kind: KeepItemKind, sealed: KeepSealed, keyVersion: Int) {
    self.id = id
    self.name = name
    self.kind = kind
    self.sealed = sealed
    self.keyVersion = keyVersion
  }
}

public struct KeepUpdateItemInput: Encodable, Sendable {
  public var name: String?
  public var kind: KeepItemKind?
  public var sealed: KeepSealed?
  public var keyVersion: Int?
  public init(name: String? = nil, kind: KeepItemKind? = nil, sealed: KeepSealed? = nil, keyVersion: Int? = nil) {
    self.name = name
    self.kind = kind
    self.sealed = sealed
    self.keyVersion = keyVersion
  }
}

public struct KeepAuditEvent: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var vaultId: String?
  public var itemId: String?
  public var itemName: String?
  public var actor: String
  public var kind: String
  public var createdAt: String
}

public struct KeepDeviceToken: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var deviceName: String
  public var createdAt: String
  public var lastUsedAt: String?
  public var expiresAt: String
  public var revokedAt: String?
}

public enum KeepCoding {
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
