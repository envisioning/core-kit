import Foundation

/// A durable reference to one favoriteable object. `kind` remains open so a
/// client can carry and ignore kinds published by a newer server.
public struct CRMFavoriteTarget: Equatable, Hashable, Identifiable, Sendable {
  public let kind: String
  public let targetRef: String

  public var id: String { stableKey }
  public var stableKey: String { Self.stableKey(kind: kind, targetRef: targetRef) }

  public init(kind: String, targetRef: String) {
    self.kind = kind
    self.targetRef = targetRef
  }

  public static func stableKey(kind: String, targetRef: String) -> String {
    "\(kind):\(targetRef)"
  }
}

/// Where a favorite opens: one registry entity and one record id in it.
public struct CRMFavoriteDestination: Hashable, Sendable {
  public let entityID: String
  public let recordID: String

  public init(entityID: String, recordID: String) {
    self.entityID = entityID
    self.recordID = recordID
  }
}

/// Registry entities whose records are favoriteable as `core.record`. The
/// other kinds (`crm.lead`, `crm.project`, `crm.task`, `crm.partner`,
/// `cms.event`) have their own canonical kind.
private let coreFavoriteRegistryEntities: Set<String> = [
  "organizations", "contacts", "services", "milestones", "licenses", "policies",
  "support_cases", "signals_accounts", "offers", "interactions", "newsletter_subscribers",
]

extension CRMFavoriteTarget {
  /// The favorite reference for a record, or nil when that record cannot be
  /// favorited: no read access, or an entity Core's catalog does not list.
  /// `space` is the space the record was listed from; CMS events are CMS
  /// wherever they are opened.
  public init?(contract: CRMEntityContract, record: CRMRecord, space: AgentSpace) {
    guard contract.hasReadAccess, contract.capabilities.read, !record.id.isEmpty else {
      return nil
    }
    if space == .cms, contract.id == "events" {
      self.init(kind: "cms.event", targetRef: record.id)
      return
    }
    switch contract.id {
    case "leads":
      self.init(kind: "crm.lead", targetRef: record.id)
    case "projects":
      self.init(kind: "crm.project", targetRef: record.id)
    case "tasks":
      self.init(kind: "crm.task", targetRef: record.id)
    case "organizations" where record["is_partner"]?.boolValue == true:
      self.init(kind: "crm.partner", targetRef: record.id)
    default:
      guard coreFavoriteRegistryEntities.contains(contract.id) else { return nil }
      self.init(kind: "core.record", targetRef: "\(contract.id):\(record.id)")
    }
  }

  /// The space that serves this target's record.
  public var space: AgentSpace { kind == "cms.event" ? .cms : .crm }

  /// The entity and record this target opens, or nil for a kind this client
  /// does not know (a newer server's): such a favorite is kept, not opened.
  public var destination: CRMFavoriteDestination? {
    switch kind {
    case "crm.lead": return CRMFavoriteDestination(entityID: "leads", recordID: targetRef)
    case "crm.project": return CRMFavoriteDestination(entityID: "projects", recordID: targetRef)
    case "crm.partner": return CRMFavoriteDestination(entityID: "organizations", recordID: targetRef)
    case "crm.task": return CRMFavoriteDestination(entityID: "tasks", recordID: targetRef)
    case "cms.event": return CRMFavoriteDestination(entityID: "events", recordID: targetRef)
    case "core.record":
      guard let separator = targetRef.firstIndex(of: ":") else { return nil }
      let entityID = String(targetRef[..<separator])
      let recordID = String(targetRef[targetRef.index(after: separator)...])
      guard coreFavoriteRegistryEntities.contains(entityID), !recordID.isEmpty else { return nil }
      return CRMFavoriteDestination(entityID: entityID, recordID: recordID)
    default:
      return nil
    }
  }
}

/// A personal favorite reference returned by Core. `kind` stays a string so
/// clients safely decode catalog kinds added by a newer server.
public struct CRMFavorite: Codable, Equatable, Identifiable, Sendable {
  public let kind: String
  public let targetRef: String
  public let createdAt: Date

  public var target: CRMFavoriteTarget { CRMFavoriteTarget(kind: kind, targetRef: targetRef) }
  public var destination: CRMFavoriteDestination? { target.destination }
  public var id: String { target.stableKey }
  public var stableKey: String { target.stableKey }

  public init(kind: String, targetRef: String, createdAt: Date) {
    self.kind = kind
    self.targetRef = targetRef
    self.createdAt = createdAt
  }

  /// Shared across native surfaces: the canonical kind, one colon, then the
  /// complete reference. Split consumers at the first colon; refs may contain
  /// colons themselves.
  public static func stableKey(kind: String, targetRef: String) -> String {
    CRMFavoriteTarget.stableKey(kind: kind, targetRef: targetRef)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case targetRef = "target_ref"
    case createdAt = "created_at"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    targetRef = try container.decode(String.self, forKey: .targetRef)
    let rawDate = try container.decode(String.self, forKey: .createdAt)
    guard let date = Self.date(from: rawDate) else {
      throw DecodingError.dataCorruptedError(
        forKey: .createdAt,
        in: container,
        debugDescription: "created_at must be an ISO-8601 timestamp."
      )
    }
    createdAt = date
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(targetRef, forKey: .targetRef)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try container.encode(formatter.string(from: createdAt), forKey: .createdAt)
  }

  private static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// In-process fan-out for open native surfaces sharing one CRM account. The
/// durable snapshot remains in `CRMCacheStore`; this only keeps current views
/// in the same process in sync after a favorite mutation or refresh.
public actor CRMFavoriteUpdates {
  public static let shared = CRMFavoriteUpdates()

  private var latestByAccount: [String: [CRMFavorite]] = [:]
  private var continuations: [String: [UUID: AsyncStream<[CRMFavorite]>.Continuation]] = [:]

  public init() {}

  public func stream(accountKey: String, initial: [CRMFavorite]) -> AsyncStream<[CRMFavorite]> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[accountKey, default: [:]][id] = continuation
      continuation.yield(latestByAccount[accountKey] ?? initial)
      continuation.onTermination = { @Sendable _ in
        Task { await self.removeContinuation(id, accountKey: accountKey) }
      }
    }
  }

  public func publish(_ favorites: [CRMFavorite], accountKey: String) {
    latestByAccount[accountKey] = favorites
    if let listeners = continuations[accountKey] {
      for continuation in listeners.values {
        continuation.yield(favorites)
      }
    }
  }

  private func removeContinuation(_ id: UUID, accountKey: String) {
    continuations[accountKey]?.removeValue(forKey: id)
    if continuations[accountKey]?.isEmpty == true {
      continuations.removeValue(forKey: accountKey)
    }
  }
}
