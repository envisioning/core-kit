import Foundation
import OSLog

/// Memoizing front for `PlausibleClient` — the only type the UI talks to.
///
/// - Returns `nil` on ANY failure or missing configuration; stats render
///   nothing rather than erroring (fail closed, silent).
/// - In-memory only: ~5 min TTL keyed by (kind, scope, range, site, host) so
///   scroll churn and tab switches never re-fire identical queries, and a
///   settings change can never serve another site's cached numbers.
/// - In-flight dedup: concurrent callers share one fetch `Task`; a cancelled
///   SwiftUI `.task` does not cancel a sibling row's request because the
///   shared task is unstructured.
public actor PlausibleStatsProvider {
  public static let shared = PlausibleStatsProvider()

  private let client: PlausibleClient
  private let configProvider: @Sendable () -> PlausibleConfig?
  private let ttl: TimeInterval
  private let logger = Logger(subsystem: "work.starlings.corekit", category: "plausible")

  private enum Kind: Hashable { case aggregate, series, breakdown }

  private struct CacheKey: Hashable {
    let kind: Kind
    let scope: PublicPagePath
    let range: PlausibleRange
    let siteID: String
    let baseURL: URL
  }

  private enum CachedValue: Sendable {
    case stats(PlausibleStats)
    case series([PlausibleTimePoint])
    case breakdown([String: PlausibleStats])
  }

  private var cache: [CacheKey: (value: CachedValue, at: Date)] = [:]
  private var inFlight: [CacheKey: Task<CachedValue?, Never>] = [:]
  private var generation = 0

  public init(
    client: PlausibleClient? = nil,
    configProvider: @escaping @Sendable () -> PlausibleConfig? = { PlausibleSettings.config() },
    ttl: TimeInterval = 300
  ) {
    self.configProvider = configProvider
    self.client = client ?? PlausibleClient(configProvider: configProvider)
    self.ttl = ttl
  }

  public func aggregate(
    scope: PublicPagePath, range: PlausibleRange
  ) async -> PlausibleStats? {
    guard case .stats(let stats)? = await fetch(kind: .aggregate, scope: scope, range: range)
    else { return nil }
    return stats
  }

  public func timeSeries(
    scope: PublicPagePath, range: PlausibleRange
  ) async -> [PlausibleTimePoint]? {
    guard case .series(let points)? = await fetch(kind: .series, scope: scope, range: range)
    else { return nil }
    return points
  }

  public func breakdown(
    scope: PublicPagePath, range: PlausibleRange
  ) async -> [String: PlausibleStats]? {
    guard case .breakdown(let rows)? = await fetch(kind: .breakdown, scope: scope, range: range)
    else { return nil }
    return rows
  }

  /// Drops everything — call after the Plausible settings change.
  public func invalidateAll() {
    generation += 1
    cache.removeAll()
    inFlight.removeAll()
  }

  private func fetch(
    kind: Kind, scope: PublicPagePath, range: PlausibleRange
  ) async -> CachedValue? {
    guard let config = configProvider() else { return nil }
    let key = CacheKey(
      kind: kind, scope: scope, range: range,
      siteID: config.siteID, baseURL: config.baseURL)

    if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl {
      return hit.value
    }
    if let running = inFlight[key] {
      return await running.value
    }

    let client = self.client
    let logger = self.logger
    let task = Task<CachedValue?, Never> {
      do {
        switch kind {
        case .aggregate:
          return .stats(try await client.aggregate(scope: scope, range: range))
        case .series:
          return .series(try await client.timeSeries(scope: scope, range: range))
        case .breakdown:
          return .breakdown(try await client.pageBreakdown(scope: scope, range: range))
        }
      } catch {
        logger.debug("Plausible query failed: \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }
    inFlight[key] = task
    let startGeneration = generation
    let value = await task.value
    if generation == startGeneration {
      inFlight[key] = nil
      if let value { cache[key] = (value, Date()) }
    }
    return value
  }
}
