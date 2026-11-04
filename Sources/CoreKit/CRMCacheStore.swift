import CryptoKit
import Foundation
import SwiftData

@Model
final class CachedCRMRecord {
  @Attribute(.unique) var cacheKey: String
  var accountKey: String
  var entityID: String
  var recordID: String
  var displayName: String
  var searchText: String
  var sectionIndex: String
  var payload: Data
  var fetchedAt: Date

  init(
    cacheKey: String,
    accountKey: String,
    entityID: String,
    recordID: String,
    displayName: String,
    searchText: String,
    sectionIndex: String,
    payload: Data,
    fetchedAt: Date
  ) {
    self.cacheKey = cacheKey
    self.accountKey = accountKey
    self.entityID = entityID
    self.recordID = recordID
    self.displayName = displayName
    self.searchText = searchText
    self.sectionIndex = sectionIndex
    self.payload = payload
    self.fetchedAt = fetchedAt
  }
}

@Model
final class CachedCRMSnapshot {
  @Attribute(.unique) var cacheKey: String
  var accountKey: String
  var kind: String
  var payload: Data
  var fetchedAt: Date

  init(cacheKey: String, accountKey: String, kind: String, payload: Data, fetchedAt: Date) {
    self.cacheKey = cacheKey
    self.accountKey = accountKey
    self.kind = kind
    self.payload = payload
    self.fetchedAt = fetchedAt
  }
}

public struct CachedCRMRecords: Sendable {
  public let records: [CRMRecord]
  public let fetchedAt: Date?
}

public enum CRMCacheIdentity {
  public static func accountKey(for token: String) -> String {
    let digest = SHA256.hash(data: Data(token.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Space-scoped account key so the same token's CRM and CMS caches never
  /// collide. CRM keeps the original unprefixed key (no cache invalidation on
  /// upgrade); other spaces are namespaced by their raw value.
  public static func accountKey(for token: String, space: AgentSpace) -> String {
    let base = accountKey(for: token)
    return space == .crm ? base : "\(space.rawValue):\(base)"
  }
}

public actor CRMCacheStore {
  public static let shared = CRMCacheStore()

  private let container: ModelContainer
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private init() {
    let schema = Schema([CachedCRMRecord.self, CachedCRMSnapshot.self])
    do {
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      try FileManager.default.createDirectory(
        at: applicationSupport,
        withIntermediateDirectories: true
      )
      let storeURL = applicationSupport.appending(path: "crm-cache-v2.store")
      let configuration = ModelConfiguration(
        "CRMCacheV2",
        schema: schema,
        url: storeURL
      )
      container = try ModelContainer(for: schema, configurations: [configuration])
    } catch {
      let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
      container = try! ModelContainer(for: schema, configurations: [fallback])
      #if DEBUG
        print("[CRMCacheStore] Persistent store unavailable; using memory cache: \(error)")
      #endif
    }
  }

  public func contracts(accountKey: String) throws -> CRMEntityContractData? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "entity-contracts") else {
      return nil
    }
    return try decoder.decode(CRMEntityContractData.self, from: snapshot.payload)
  }

  public func registry(accountKey: String) throws -> CRMRegistryData? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "registry") else {
      return nil
    }
    return try decoder.decode(CRMRegistryData.self, from: snapshot.payload)
  }

  public func saveRegistry(_ registry: CRMRegistryData, accountKey: String) throws {
    if let cached = try self.registry(accountKey: accountKey),
      cached.registryVersion != registry.registryVersion
        || cached.schemaVersion != registry.schemaVersion
        || cached.metadataSchemaVersion != registry.metadataSchemaVersion
    {
      try deleteSnapshots(
        accountKey: accountKey,
        kinds: ["registry", "entity-contracts", "navigation"]
      )
    }
    try saveSnapshot(
      payload: encoder.encode(registry),
      accountKey: accountKey,
      kind: "registry"
    )
  }

  public func saveContracts(_ contracts: CRMEntityContractData, accountKey: String) throws {
    try saveSnapshot(
      payload: encoder.encode(contracts),
      accountKey: accountKey,
      kind: "entity-contracts"
    )
  }

  public func navigation(accountKey: String) throws -> CRMNavigationData? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "navigation") else {
      return nil
    }
    return try decoder.decode(CRMNavigationData.self, from: snapshot.payload)
  }

  public func saveNavigation(_ navigation: CRMNavigationData, accountKey: String) throws {
    try saveSnapshot(
      payload: encoder.encode(navigation),
      accountKey: accountKey,
      kind: "navigation"
    )
  }

  public func characteristics(accountKey: String) throws -> CRMCharacteristicsVocabulary? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "characteristics") else {
      return nil
    }
    return try decoder.decode(CRMCharacteristicsVocabulary.self, from: snapshot.payload)
  }

  public func saveCharacteristics(
    _ characteristics: CRMCharacteristicsVocabulary,
    accountKey: String
  ) throws {
    try saveSnapshot(
      payload: encoder.encode(characteristics),
      accountKey: accountKey,
      kind: "characteristics"
    )
  }

  public func favorites(accountKey: String) throws -> [CRMFavorite]? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "favorites") else {
      return nil
    }
    return try decoder.decode([CRMFavorite].self, from: snapshot.payload)
  }

  public func saveFavorites(_ favorites: [CRMFavorite], accountKey: String) throws {
    try saveSnapshot(
      payload: encoder.encode(favorites),
      accountKey: accountKey,
      kind: "favorites"
    )
  }

  public func dashboard(accountKey: String) throws -> CRMDashboardSummary? {
    guard let snapshot = try snapshot(accountKey: accountKey, kind: "dashboard") else {
      return nil
    }
    return try decoder.decode(CRMDashboardSummary.self, from: snapshot.payload)
  }

  public func saveDashboard(_ dashboard: CRMDashboardSummary, accountKey: String) throws {
    try saveSnapshot(
      payload: encoder.encode(dashboard),
      accountKey: accountKey,
      kind: "dashboard"
    )
  }

  public func related(
    accountKey: String,
    entity: String,
    recordID: String,
    relation: String
  ) throws -> CRMRelatedData? {
    let kind = "related:\(entity):\(recordID):\(relation)"
    guard let snapshot = try snapshot(accountKey: accountKey, kind: kind) else { return nil }
    return try decoder.decode(CRMRelatedData.self, from: snapshot.payload)
  }

  public func saveRelated(
    _ related: CRMRelatedData,
    accountKey: String,
    entity: String,
    recordID: String
  ) throws {
    try saveSnapshot(
      payload: encoder.encode(related),
      accountKey: accountKey,
      kind: "related:\(entity):\(recordID):\(related.relation)"
    )
  }

  public func records(accountKey: String, entity: String) throws -> CachedCRMRecords {
    let requestedEntityID = entity
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<CachedCRMRecord>(
      predicate: #Predicate {
        $0.accountKey == accountKey && $0.entityID == requestedEntityID
      },
      sortBy: [SortDescriptor(\.displayName)]
    )
    let rows = try context.fetch(descriptor)
    let decoded = rows.compactMap { try? decoder.decode(CRMRecord.self, from: $0.payload) }
    return CachedCRMRecords(records: decoded, fetchedAt: rows.map(\.fetchedAt).max())
  }

  public func replaceRecords(
    _ records: [CRMRecord],
    accountKey: String,
    entity: String,
    primaryField: String
  ) throws {
    let requestedEntityID = entity
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<CachedCRMRecord>(
      predicate: #Predicate {
        $0.accountKey == accountKey && $0.entityID == requestedEntityID
      }
    )
    let existing = try context.fetch(descriptor)
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordID, $0) })
    let incomingIDs = Set(records.map(\.id))
    let fetchedAt = Date()

    for record in records where !record.id.isEmpty {
      let payload = try encoder.encode(record)
      let displayName = record.displayName(primaryField: primaryField, fallback: record.id)
      let searchText = record.fields.values.map(\.searchableText)
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let sectionIndex = Self.sectionIndex(for: displayName)

      if let row = byID[record.id] {
        row.displayName = displayName
        row.searchText = searchText
        row.sectionIndex = sectionIndex
        row.payload = payload
        row.fetchedAt = fetchedAt
      } else {
        context.insert(
          CachedCRMRecord(
            cacheKey: "\(accountKey):\(entity):\(record.id)",
            accountKey: accountKey,
            entityID: requestedEntityID,
            recordID: record.id,
            displayName: displayName,
            searchText: searchText,
            sectionIndex: sectionIndex,
            payload: payload,
            fetchedAt: fetchedAt
          )
        )
      }
    }

    for row in existing where !incomingIDs.contains(row.recordID) {
      context.delete(row)
    }
    try context.save()
  }

  public func purge(accountKey: String) throws {
    let context = ModelContext(container)
    let recordDescriptor = FetchDescriptor<CachedCRMRecord>(
      predicate: #Predicate { $0.accountKey == accountKey }
    )
    let snapshotDescriptor = FetchDescriptor<CachedCRMSnapshot>(
      predicate: #Predicate { $0.accountKey == accountKey }
    )
    for record in try context.fetch(recordDescriptor) { context.delete(record) }
    for snapshot in try context.fetch(snapshotDescriptor) { context.delete(snapshot) }
    try context.save()
  }

  private func snapshot(accountKey: String, kind: String) throws -> CachedCRMSnapshot? {
    let cacheKey = "\(accountKey):\(kind)"
    let context = ModelContext(container)
    var descriptor = FetchDescriptor<CachedCRMSnapshot>(
      predicate: #Predicate { $0.cacheKey == cacheKey }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func saveSnapshot(payload: Data, accountKey: String, kind: String) throws {
    let context = ModelContext(container)
    let cacheKey = "\(accountKey):\(kind)"
    var descriptor = FetchDescriptor<CachedCRMSnapshot>(
      predicate: #Predicate { $0.cacheKey == cacheKey }
    )
    descriptor.fetchLimit = 1
    if let existing = try context.fetch(descriptor).first {
      existing.payload = payload
      existing.fetchedAt = Date()
    } else {
      context.insert(
        CachedCRMSnapshot(
          cacheKey: cacheKey,
          accountKey: accountKey,
          kind: kind,
          payload: payload,
          fetchedAt: Date()
        )
      )
    }
    try context.save()
  }

  private func deleteSnapshots(accountKey: String, kinds: Set<String>) throws {
    let requestedAccountKey = accountKey
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<CachedCRMSnapshot>(
      predicate: #Predicate { $0.accountKey == requestedAccountKey }
    )
    for row in try context.fetch(descriptor) where kinds.contains(row.kind) {
      context.delete(row)
    }
    try context.save()
  }

  private static func sectionIndex(for value: String) -> String {
    let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    guard let first = folded.first, first.isLetter else { return "#" }
    return String(first).uppercased(with: .current)
  }
}
