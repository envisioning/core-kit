import Foundation

public struct CRMRepositoryRecord: Sendable {
  public let record: CRMRecord
  public let isCached: Bool
}

public final class CRMRepository: Sendable {
  public static let defaultFreshness: TimeInterval = 5 * 60

  public let space: AgentSpace
  private let client: CoreAgentClient
  private let cache: CRMCacheStore
  private let tokenProvider: @Sendable () -> String?

  public init(
    space: AgentSpace = .crm,
    client: CoreAgentClient? = nil,
    cache: CRMCacheStore = .shared,
    tokenProvider: @escaping @Sendable () -> String? = { TokenManager().readToken() }
  ) {
    self.space = space
    self.tokenProvider = tokenProvider
    self.client = client ?? CoreAgentClient(space: space, tokenProvider: tokenProvider)
    self.cache = cache
  }

  public var hasToken: Bool {
    normalizedToken != nil
  }

  public var accountKey: String? {
    normalizedToken.map { CRMCacheIdentity.accountKey(for: $0, space: space) }
  }

  public func cachedContracts() async throws -> CRMEntityContractData? {
    try await cache.contracts(accountKey: try requiredAccountKey())
  }

  public func cachedRegistry() async throws -> CRMRegistryData? {
    let registry = try await cache.registry(accountKey: try requiredAccountKey())
    if let registry { await client.configureRegistry(registry) }
    return registry
  }

  public func refreshRegistry() async throws -> CRMRegistryData {
    let accountKey = try requiredAccountKey()
    let value = try await client.registry()
    try? await cache.saveRegistry(value, accountKey: accountKey)
    return value
  }

  public func refreshContracts() async throws -> CRMEntityContractData {
    let accountKey = try requiredAccountKey()
    let value = try await client.entityContracts()
    try? await cache.saveContracts(value, accountKey: accountKey)
    return value
  }

  public func cachedNavigation() async throws -> CRMNavigationData? {
    try await cache.navigation(accountKey: try requiredAccountKey())
  }

  public func refreshNavigation() async throws -> CRMNavigationData {
    let accountKey = try requiredAccountKey()
    let value = try await client.navigation()
    try? await cache.saveNavigation(value, accountKey: accountKey)
    return value
  }

  public func cachedCharacteristics() async throws -> CRMCharacteristicsVocabulary? {
    try await cache.characteristics(accountKey: try requiredAccountKey())
  }

  public func refreshCharacteristics() async throws -> CRMCharacteristicsVocabulary {
    let accountKey = try requiredAccountKey()
    let value = try await client.characteristics()
    try? await cache.saveCharacteristics(value, accountKey: accountKey)
    return value
  }

  /// Assignable team members for `optionsSource: "members"` pickers (task
  /// `assigned_to`). Small, live list — fetched straight from the server rather
  /// than cached like the heavier registry snapshots.
  public func members() async throws -> [CRMMember] {
    try await client.members()
  }

  public func cachedFavorites() async throws -> [CRMFavorite]? {
    try await cache.favorites(accountKey: try requiredFavoritesAccountKey())
  }

  public func refreshFavorites() async throws -> [CRMFavorite] {
    let accountKey = try requiredFavoritesAccountKey()
    let favorites = try await client.listFavorites()
    try? await cache.saveFavorites(favorites, accountKey: accountKey)
    await CRMFavoriteUpdates.shared.publish(favorites, accountKey: accountKey)
    return favorites
  }

  public func addFavorite(kind: String, targetRef: String) async throws -> CRMFavorite {
    try await addFavorite(target: CRMFavoriteTarget(kind: kind, targetRef: targetRef))
  }

  public func addFavorite(target: CRMFavoriteTarget) async throws -> CRMFavorite {
    let accountKey = try requiredFavoritesAccountKey()
    var favorites = try await favoritesBeforeMutation(accountKey: accountKey)
    let favorite = try await client.addFavorite(target: target)
    let key = favorite.stableKey
    if let index = favorites.firstIndex(where: { $0.stableKey == key }) {
      favorites[index] = favorite
    } else {
      favorites.append(favorite)
    }
    favorites.sort {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.stableKey < $1.stableKey
    }
    try? await cache.saveFavorites(favorites, accountKey: accountKey)
    await CRMFavoriteUpdates.shared.publish(favorites, accountKey: accountKey)
    return favorite
  }

  public func removeFavorite(kind: String, targetRef: String) async throws {
    try await removeFavorite(target: CRMFavoriteTarget(kind: kind, targetRef: targetRef))
  }

  public func removeFavorite(target: CRMFavoriteTarget) async throws {
    let accountKey = try requiredFavoritesAccountKey()
    var favorites = try await favoritesBeforeMutation(accountKey: accountKey)
    try await client.removeFavorite(target: target)
    favorites.removeAll { $0.target == target }
    try? await cache.saveFavorites(favorites, accountKey: accountKey)
    await CRMFavoriteUpdates.shared.publish(favorites, accountKey: accountKey)
  }

  /// Open views subscribe here and reload when another surface in this process
  /// changes the shared favorites snapshot.
  public func observeFavorites() async throws -> AsyncStream<[CRMFavorite]> {
    let accountKey = try requiredFavoritesAccountKey()
    let initial = (try? await cache.favorites(accountKey: accountKey)) ?? []
    return await CRMFavoriteUpdates.shared.stream(accountKey: accountKey, initial: initial)
  }

  public func cachedDashboard() async throws -> CRMDashboardSummary? {
    try await cache.dashboard(accountKey: try requiredAccountKey())
  }

  public func refreshDashboard() async throws -> CRMDashboardSummary {
    let accountKey = try requiredAccountKey()
    let value = try await client.dashboard()
    try? await cache.saveDashboard(value, accountKey: accountKey)
    return value
  }

  public func cachedRecords(entity: String) async throws -> CachedCRMRecords {
    try await cache.records(accountKey: try requiredAccountKey(), entity: entity)
  }

  public func recordsAreFresh(
    fetchedAt: Date?,
    maxAge: TimeInterval = CRMRepository.defaultFreshness
  ) -> Bool {
    fetchedAt.map { Date().timeIntervalSince($0) < maxAge } ?? false
  }

  public func refreshRecords(
    entity: String,
    primaryField: String,
    pageSize: Int = 200
  ) async throws -> [CRMRecord] {
    let accountKey = try requiredAccountKey()
    var records: [CRMRecord] = []
    var offset = 0

    while true {
      let page = try await client.list(
        entity: entity,
        query: nil,
        limit: pageSize,
        offset: offset
      )
      try Task.checkCancellation()
      records.append(contentsOf: page.data)
      guard !page.data.isEmpty, records.count < page.meta.count else { break }
      offset += page.data.count
    }

    try? await cache.replaceRecords(
      records,
      accountKey: accountKey,
      entity: entity,
      primaryField: primaryField
    )
    return records
  }

  public func recordCount(entity: String) async -> Int? {
    try? await client.list(entity: entity, limit: 1).meta.count
  }

  public func record(
    entity: String,
    id: String,
    primaryField: String
  ) async throws -> CRMRepositoryRecord {
    let accountKey = try requiredAccountKey()
    let cached = try? await cachedRecords(entity: entity)
    let cachedRecord = cached?.records.first { $0.id == id }

    do {
      let live = try await client.get(entity: entity, id: id)
      try? await mergeRecord(
        live,
        entity: entity,
        primaryField: primaryField,
        cached: cached,
        accountKey: accountKey
      )
      return CRMRepositoryRecord(record: live, isCached: false)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if let cachedRecord {
        return CRMRepositoryRecord(record: cachedRecord, isCached: true)
      }
      throw error
    }
  }

  /// Opens a favorite's record from the live server only. Unlike `record`, a
  /// failure is not papered over with a cached row: a revoked grant or a
  /// deleted record has to read as unavailable, not as stale data.
  public func resolveFavoriteRecord(
    entity: String,
    id: String,
    primaryField: String
  ) async throws -> CRMRecord {
    let accountKey = try requiredAccountKey()
    let cached = try? await cachedRecords(entity: entity)
    let live = try await client.get(entity: entity, id: id)
    try? await mergeRecord(
      live,
      entity: entity,
      primaryField: primaryField,
      cached: cached,
      accountKey: accountKey
    )
    return live
  }

  public func cachedRelated(
    entity: String,
    recordID: String,
    relation: String
  ) async throws -> CRMRelatedData? {
    try await cache.related(
      accountKey: try requiredAccountKey(),
      entity: entity,
      recordID: recordID,
      relation: relation
    )
  }

  public func refreshRelated(
    entity: String,
    recordID: String,
    relation: String
  ) async throws -> CRMRelatedData {
    let accountKey = try requiredAccountKey()
    let value = try await client.related(entity: entity, id: recordID, relation: relation)
    try? await cache.saveRelated(
      value,
      accountKey: accountKey,
      entity: entity,
      recordID: recordID
    )
    return value
  }

  /// Detach a related record from its source and return the section's refreshed
  /// contents. The unlinked record still exists — only the relation is cleared —
  /// so the target entity's own cached list stays valid and is left alone.
  @discardableResult
  public func unlinkRelated(
    entity: String,
    recordID: String,
    relation: String,
    relatedID: String
  ) async throws -> CRMRelatedData {
    try await client.unlinkRelated(
      entity: entity,
      id: recordID,
      relation: relation,
      relatedID: relatedID
    )
    return try await refreshRelated(entity: entity, recordID: recordID, relation: relation)
  }

  /// Whether the server published an executable unlink operation for a relation
  /// and granted this token the scopes for it. Fails closed when absent.
  public func canUnlink(entity: String, relation: String) async -> Bool {
    await client.canExecute(operationID: "\(entity).\(relation).unlink")
  }

  public func search(_ query: String, limit: Int = 8) async throws -> AgentSearchEnvelope {
    try await client.search(query, limit: limit)
  }

  /// Server-paged, server-searched slice of a scoped collection (e.g. a research
  /// hub's technologies). Deliberately uncached — large content collections page
  /// in on demand rather than caching the whole set. Returns the page plus the
  /// total match count so the caller knows when to stop.
  public func listScopedCollection(
    entity: String,
    filterColumn: String,
    filterValue: String,
    query: String,
    limit: Int,
    offset: Int
  ) async throws -> (records: [CRMRecord], total: Int) {
    let envelope = try await client.listCollection(
      entity: entity,
      filters: [filterColumn: filterValue],
      query: query,
      limit: limit,
      offset: offset
    )
    return (envelope.data, envelope.meta.count)
  }

  public func save(
    entity: String,
    id: String?,
    values: [String: JSONValue],
    primaryField: String
  ) async throws -> CRMRecord {
    let accountKey = try requiredAccountKey()
    let saved = try await client.save(entity: entity, id: id, values: values)
    let cached = try? await cachedRecords(entity: entity)
    try? await mergeRecord(
      saved,
      entity: entity,
      primaryField: primaryField,
      cached: cached,
      accountKey: accountKey
    )
    return saved
  }

  public func delete(entity: String, id: String, primaryField: String) async throws {
    let accountKey = try requiredAccountKey()
    try await client.delete(entity: entity, id: id)
    guard let cached = try? await cachedRecords(entity: entity), !cached.records.isEmpty else {
      return
    }
    try? await cache.replaceRecords(
      cached.records.filter { $0.id != id },
      accountKey: accountKey,
      entity: entity,
      primaryField: primaryField
    )
  }

  public func canMergeContacts() async -> Bool {
    await client.canExecute(operationID: "contacts.merge")
  }

  public func mergeContacts(_ contactIDs: [String]) async throws -> CRMRecord {
    let accountKey = try requiredAccountKey()
    let result = try await client.mergeContacts(contactIDs)
    let survivor = try await client.get(entity: "contacts", id: result.survivorId)

    if let cached = try? await cachedRecords(entity: "contacts"), !cached.records.isEmpty {
      var records = cached.records.filter { !result.mergedContactIds.contains($0.id) }
      if let index = records.firstIndex(where: { $0.id == survivor.id }) {
        records[index] = survivor
      } else {
        records.append(survivor)
      }
      try? await cache.replaceRecords(
        records,
        accountKey: accountKey,
        entity: "contacts",
        primaryField: "name"
      )
    }

    return survivor
  }

  private var normalizedToken: String? {
    let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
    return token?.isEmpty == false ? token : nil
  }

  private func requiredAccountKey() throws -> String {
    guard let accountKey else { throw CoreAgentClientError.missingToken }
    return accountKey
  }

  /// Favorites live in the shared CRM API even while the UI is browsing CMS.
  private func requiredFavoritesAccountKey() throws -> String {
    guard let token = normalizedToken else { throw CoreAgentClientError.missingToken }
    return CRMCacheIdentity.accountKey(for: token)
  }

  private func favoritesBeforeMutation(accountKey: String) async throws -> [CRMFavorite] {
    if let favorites = try? await cache.favorites(accountKey: accountKey) { return favorites }
    let favorites = try await client.listFavorites()
    try? await cache.saveFavorites(favorites, accountKey: accountKey)
    return favorites
  }

  private func mergeRecord(
    _ record: CRMRecord,
    entity: String,
    primaryField: String,
    cached: CachedCRMRecords?,
    accountKey: String
  ) async throws {
    guard var records = cached?.records, !records.isEmpty else { return }
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      records[index] = record
    } else {
      records.append(record)
    }
    try await cache.replaceRecords(
      records,
      accountKey: accountKey,
      entity: entity,
      primaryField: primaryField
    )
  }
}
