import Foundation

/// Client for the Plausible Stats API v2 — a single endpoint,
/// `POST {base}/api/v2/query`, bearer-authenticated with a Stats API key.
///
/// Every read the app needs is one of four query shapes:
/// 1. Detail aggregate — no dimensions; filter is `.exact` (technology opened
///    from its hub), `.wildcard` `/research/*/<slug>` (technology reached
///    without hub context), or `.subtree` (hub page + descendants).
/// 2. Detail time-series — same filter plus `dimensions: ["time:day"]`
///    (7d/30d) or `["time:month"]` (12mo).
/// 3. Technologies-list breakdown — `/research/<hub>/*` as a regex filter
///    plus `dimensions: ["event:page"]`; one query covers every row.
/// 4. Research-list breakdown — `contains "/research/"` plus
///    `dimensions: ["event:page"]`; rows are rolled up per hub client-side.
///
/// Rate limit is 600 requests/hour on plausible.io → HTTP 429
/// (`PlausibleClientError.rateLimited`). Callers memoize via
/// `PlausibleStatsProvider`; this type is pure transport.
public struct PlausibleConfig: Sendable, Hashable {
  public let baseURL: URL
  public let siteID: String
  public let apiKey: String

  public init(baseURL: URL, siteID: String, apiKey: String) {
    self.baseURL = baseURL
    self.siteID = siteID
    self.apiKey = apiKey
  }
}

/// Query ranges surfaced in the UI. Raw values are Plausible `date_range`
/// shorthands except for `last12Months`, whose request value is expanded to an
/// explicit current-month-inclusive calendar window by `apiDateRange`.
public enum PlausibleRange: String, CaseIterable, Sendable, Hashable {
  case last7Days = "7d"
  case last30Days = "30d"
  case last12Months = "12mo"

  /// Time dimension for series queries at this range.
  public var timeDimension: String {
    switch self {
    case .last7Days, .last30Days: "time:day"
    case .last12Months: "time:month"
    }
  }

  /// Short label for segmented pickers.
  public var label: String {
    switch self {
    case .last7Days: "7D"
    case .last30Days: "30D"
    case .last12Months: "12M"
    }
  }
}

enum PlausibleAPIDateRange: Sendable, Equatable {
  case shorthand(String)
  case dates(from: String, through: String)

  var jsonValue: Any {
    switch self {
    case .shorthand(let value): value
    case .dates(let from, let through): [from, through]
    }
  }
}

extension PlausibleRange {
  /// Plausible defines `12mo` as the 12 COMPLETE months before the current
  /// month. The dashboard promises "This month", so use an explicit 12-month
  /// calendar window that starts 11 months ago and runs through today.
  func apiDateRange(relativeTo now: Date, calendar sourceCalendar: Calendar) -> PlausibleAPIDateRange {
    guard self == .last12Months else { return .shorthand(rawValue) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = sourceCalendar.timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    guard
      let currentMonth = calendar.dateInterval(of: .month, for: now),
      let firstMonth = calendar.date(byAdding: .month, value: -11, to: currentMonth.start)
    else { return .shorthand(rawValue) }

    return .dates(
      from: Self.apiDateString(firstMonth, calendar: calendar),
      through: Self.apiDateString(now, calendar: calendar)
    )
  }

  private static func apiDateString(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return "" }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}

public struct PlausibleStats: Sendable, Hashable {
  public let visitors: Int
  public let pageviews: Int
  /// Average visit duration in seconds (0 when the query omitted the metric).
  public let visitDuration: TimeInterval

  public init(visitors: Int, pageviews: Int, visitDuration: TimeInterval) {
    self.visitors = visitors
    self.pageviews = pageviews
    self.visitDuration = visitDuration
  }

  public static let zero = PlausibleStats(visitors: 0, pageviews: 0, visitDuration: 0)

  /// Client-side rollup across pages. Pageviews are additive; summed visitors
  /// are an upper bound (a visitor seeing two pages counts twice). Duration
  /// keeps the pageview-weighted average so rollups stay plausible.
  public static func + (lhs: PlausibleStats, rhs: PlausibleStats) -> PlausibleStats {
    let views = lhs.pageviews + rhs.pageviews
    let duration = views > 0
      ? (lhs.visitDuration * Double(lhs.pageviews) + rhs.visitDuration * Double(rhs.pageviews))
        / Double(views)
      : 0
    return PlausibleStats(
      visitors: lhs.visitors + rhs.visitors,
      pageviews: views,
      visitDuration: duration
    )
  }
}

public struct PlausibleTimePoint: Sendable, Hashable, Identifiable {
  /// Bucket key as returned by the API ("2026-07-01" for days, "2026-07-01"
  /// with month granularity for months) — sortable lexicographically.
  public let key: String
  public let stats: PlausibleStats

  public init(key: String, stats: PlausibleStats) {
    self.key = key
    self.stats = stats
  }

  public var id: String { key }
}

public enum PlausibleClientError: LocalizedError, Sendable {
  case missingConfiguration
  case invalidResponse
  case rateLimited
  case api(status: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingConfiguration:
      "Add a Plausible API key and site ID in Settings → Analytics."
    case .invalidResponse: "Plausible returned an invalid response."
    case .rateLimited: "Plausible rate limit hit (600 requests/hour). Try again shortly."
    case .api(_, let message): message
    }
  }
}

public actor PlausibleClient {
  private static let metrics = ["visitors", "pageviews", "visit_duration"]

  private let session: URLSession
  private let configProvider: @Sendable () -> PlausibleConfig?
  private let nowProvider: @Sendable () -> Date
  private let calendar: Calendar

  public init(
    session: URLSession = .shared,
    configProvider: @escaping @Sendable () -> PlausibleConfig?,
    nowProvider: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.session = session
    self.configProvider = configProvider
    self.nowProvider = nowProvider
    self.calendar = calendar
  }

  /// Aggregate totals for a page scope (detail strips, connection test).
  public func aggregate(
    scope: PublicPagePath, range: PlausibleRange
  ) async throws -> PlausibleStats {
    let json = try await query(scope: scope, range: range, dimensions: nil)
    guard let first = Self.results(of: json).first else { return .zero }
    return Self.parseStats(first["metrics"])
  }

  /// Per-day/per-month buckets for the sparkline, ascending by bucket key.
  public func timeSeries(
    scope: PublicPagePath, range: PlausibleRange
  ) async throws -> [PlausibleTimePoint] {
    let json = try await query(scope: scope, range: range, dimensions: [range.timeDimension])
    var pointsByKey: [String: PlausibleTimePoint] = [:]
    for row in Self.results(of: json) {
      guard let key = (row["dimensions"] as? [Any])?.first as? String else { continue }
      pointsByKey[key] = PlausibleTimePoint(key: key, stats: Self.parseStats(row["metrics"]))
    }

    // Plausible omits buckets with no data from `results`. Because every time
    // query asks for `include.time_labels`, union those labels with the returned
    // rows and materialize the gaps as zeroes. The dashboard can then trust the
    // last point to mean the latest calendar bucket, including a zero-traffic
    // current month.
    let timeLabels = ((json["meta"] as? [String: Any])?["time_labels"] as? [String]) ?? []
    return Set(pointsByKey.keys).union(timeLabels).sorted().map { key in
      pointsByKey[key] ?? PlausibleTimePoint(key: key, stats: .zero)
    }
  }

  /// Per-page rows under a scope (one query per list screen), keyed by path.
  public func pageBreakdown(
    scope: PublicPagePath, range: PlausibleRange
  ) async throws -> [String: PlausibleStats] {
    let json = try await query(scope: scope, range: range, dimensions: ["event:page"])
    var stats: [String: PlausibleStats] = [:]
    for row in Self.results(of: json) {
      guard let path = (row["dimensions"] as? [Any])?.first as? String else { continue }
      stats[path] = Self.parseStats(row["metrics"])
    }
    return stats
  }

  // MARK: - Query building

  /// The only place filter operators live. The v2 API rejected
  /// `matches_wildcard` ("invalid filter"), so wildcard and subtree scopes
  /// use the `matches` regex operator instead (RE2, anchored).
  private static func filters(for scope: PublicPagePath) -> [[Any]] {
    switch scope {
    case .exact(let path):
      return [["is", "event:page", [path]]]
    case .wildcard(let pattern):
      return [["matches", "event:page", [Self.regex(forWildcard: pattern)]]]
    case .subtree(let root):
      // Root subtree ("/") means the whole site.
      guard root != "/" else { return [["matches", "event:page", ["^/.*$"]]] }
      let escaped = NSRegularExpression.escapedPattern(for: root)
      return [["matches", "event:page", ["^\(escaped)(/.*)?$"]]]
    }
  }

  /// `/research/*/<slug>` → `^/research/[^/]+/<slug>$`: `*` is one path
  /// segment, `**` any suffix; literal segments are regex-escaped.
  private static func regex(forWildcard pattern: String) -> String {
    let segments = pattern.split(separator: "/").map { segment -> String in
      switch segment {
      case "**": ".*"
      case "*": "[^/]+"
      default: NSRegularExpression.escapedPattern(for: String(segment))
      }
    }
    return "^/" + segments.joined(separator: "/") + "$"
  }

  private func query(
    scope: PublicPagePath, range: PlausibleRange, dimensions: [String]?
  ) async throws -> [String: Any] {
    guard let config = configProvider() else {
      throw PlausibleClientError.missingConfiguration
    }
    var body: [String: Any] = [
      "site_id": config.siteID,
      "metrics": Self.metrics,
      "date_range": range.apiDateRange(
        relativeTo: nowProvider(), calendar: calendar
      ).jsonValue,
      "filters": Self.filters(for: scope),
    ]
    if let dimensions {
      body["dimensions"] = dimensions
      body["pagination"] = ["limit": 10000]
      if dimensions.contains(where: { $0.hasPrefix("time:") }) {
        body["include"] = ["time_labels": true]
      }
    }
    return try await post(config: config, body: body)
  }

  // MARK: - Transport

  private func post(config: PlausibleConfig, body: [String: Any]) async throws -> [String: Any] {
    let url = config.baseURL.appending(path: "/api/v2/query")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 30
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw PlausibleClientError.invalidResponse
    }
    if http.statusCode == 429 { throw PlausibleClientError.rateLimited }
    guard (200..<300).contains(http.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw PlausibleClientError.api(status: http.statusCode, message: message)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PlausibleClientError.invalidResponse
    }
    return json
  }

  // MARK: - Parsing

  private static func results(of json: [String: Any]) -> [[String: Any]] {
    json["results"] as? [[String: Any]] ?? []
  }

  /// Metric values arrive positionally, matching the requested `metrics`
  /// order (visitors, pageviews, visit_duration).
  private static func parseStats(_ metrics: Any?) -> PlausibleStats {
    let values = (metrics as? [Any]) ?? []
    func number(_ index: Int) -> Double {
      guard index < values.count else { return 0 }
      if let double = values[index] as? Double { return double }
      if let int = values[index] as? Int { return Double(int) }
      return 0
    }
    return PlausibleStats(
      visitors: Int(number(0)),
      pageviews: Int(number(1)),
      visitDuration: number(2)
    )
  }
}
