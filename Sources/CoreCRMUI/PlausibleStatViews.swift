import CoreKit
import SwiftUI

/// Compact per-row website-stats badge. Takes PRECOMPUTED stats — it never
/// fetches; list screens run one breakdown query via
/// `PlausibleSectionStatsModel` and hand each row its slice. `nil` renders
/// nothing (no key, no permalink, no traffic row — fail closed).
public struct PlausibleStatBadge: View {
  let stats: PlausibleStats?
  /// Drops the visitor count, leaving just "1.2M views" — for tight slots
  /// like the dashboard rows, where the row already carries its own number.
  var showsVisitors = true

  public init(stats: PlausibleStats?, showsVisitors: Bool = true) {
    self.stats = stats; self.showsVisitors = showsVisitors
  }

  public var body: some View {
    if let stats {
      // Leading glyph so this subtitle line carries an icon like every other
      // row indicator — consistency across lists wins over the earlier worry
      // that a static chart symbol reads as a live chart.
      Label {
        Text(label(for: stats))
          .monospacedDigit()
          .lineLimit(1)
      } icon: {
        Image(systemName: "chart.bar.xaxis")
      }
      .font(.caption2)
      .foregroundStyle(crmSecondaryText)
    }
  }

  private func label(for stats: PlausibleStats) -> String {
    let views = "\(compact(stats.pageviews)) views"
    guard showsVisitors else { return views }
    return "\(views) · \(compact(stats.visitors)) visitors"
  }

  private func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
  }
}

/// Detail-page "Website" section: live Plausible numbers for the record's
/// public page. Renders nothing until the first successful load; keeps the
/// last numbers on screen while a range switch loads so the section never
/// flickers away.
public struct PlausibleStatsStrip: View {
  let path: PublicPagePath
  /// Bumped by an enclosing pull-to-refresh so the strip re-queries. The range
  /// alone can't do it: on an explicit refresh nothing about the query changes,
  /// so without this the `.task` never re-fires.
  var reloadToken = 0

  @State private var range: PlausibleRange = .last30Days
  @State private var stats: PlausibleStats?

  private var loadKey: [String] { [range.rawValue, String(reloadToken)] }

  public init(path: PublicPagePath, reloadToken: Int = 0) {
    self.path = path; self.reloadToken = reloadToken
  }

  public var body: some View {
    if let stats {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Range", selection: $range) {
            ForEach(PlausibleRange.allCases, id: \.self) { range in
              Text(range.label).tag(range)
            }
          }
          .pickerStyle(.segmented)

          HStack(alignment: .top, spacing: 12) {
            statColumn(
              label: "Visitors",
              value: stats.visitors.formatted(.number.notation(.compactName)))
            statColumn(
              label: "Views",
              value: stats.pageviews.formatted(.number.notation(.compactName)))
            statColumn(label: "Avg. Visit", value: durationLabel(stats.visitDuration))
            Spacer(minLength: 0)
          }
        }
        .padding(.vertical, 4)
        .task(id: loadKey) { await load() }
        .onAppActivation { Task { await load() } }
        .onRefreshRequest { Task { await load() } }
      } header: {
        Text("Website")
      }
    } else {
      // Invisible until the first load succeeds; occupies no space on
      // failure. Color.clear (not EmptyView) so `.task` actually runs.
      Color.clear
        .frame(height: 0)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .task(id: loadKey) { await load() }
        .onAppActivation { Task { await load() } }
        .onRefreshRequest { Task { await load() } }
    }
  }

  /// Deliberately does NOT invalidate the provider's cache, so the foreground
  /// re-load stays cheap: a quick app switch replays the memoized window, and
  /// only an absence longer than the 5-minute TTL costs a real query. Dropping
  /// the cache on every activation would burn the 600-requests/hour budget.
  private func load() async {
    let loaded = await PlausibleStatsProvider.shared.aggregate(scope: path, range: range)
    guard !Task.isCancelled else { return }
    if let loaded { stats = loaded }
  }

  private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(crmSecondaryText)
        .textCase(.uppercase)
        .lineLimit(1)
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
  }

  private func durationLabel(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
  }
}

/// Settings → Analytics: Plausible key, site, host, and the master toggle.
/// The one place Plausible errors surface (the Test Connection footer) —
/// everywhere else the integration fails closed and silent.
public struct PlausibleSettingsSection: View {
  public init() {}

  @State private var apiKey = ""
  @State private var siteID = PlausibleSettings.siteID
  @State private var baseURL = PlausibleSettings.baseURLString
  @State private var statsEnabled = PlausibleSettings.statsEnabled
  @State private var savedKey = PlausibleSettings.readAPIKey() ?? ""
  @State private var testResult: String?
  @State private var isTesting = false

  public var body: some View {
    Section {
      Toggle("Show website stats", isOn: $statsEnabled)
        .tint(.accentColor)
        .onChange(of: statsEnabled) { _, enabled in
          PlausibleSettings.statsEnabled = enabled
          invalidate()
        }
      SecureField(
        "API Key",
        text: $apiKey,
        prompt: Text(savedKey.isEmpty ? "Plausible Stats API key" : CRMAccountView.maskToken(savedKey))
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onSubmit(commitKey)
      LabeledContent("Site") {
        TextField("Site", text: $siteID, prompt: Text(PlausibleSettings.defaultSiteID))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .multilineTextAlignment(.trailing)
          .onSubmit(commitEndpoint)
      }
      LabeledContent("Host") {
        TextField("Host", text: $baseURL, prompt: Text(PlausibleSettings.defaultBaseURLString))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .multilineTextAlignment(.trailing)
          .onSubmit(commitEndpoint)
      }
      Button(isTesting ? "Testing…" : "Test Connection") {
        Task { await test() }
      }
      .disabled(isTesting)
    } header: {
      Text("Analytics")
    } footer: {
      Text(testResult ?? "Website stats for CMS content, from Plausible. Create a Stats API key in your Plausible account settings.")
    }
  }

  private func commitKey() {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    PlausibleSettings.saveAPIKey(trimmed)
    savedKey = trimmed
    apiKey = ""
    invalidate()
  }

  private func commitEndpoint() {
    PlausibleSettings.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
    PlausibleSettings.baseURLString = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    invalidate()
  }

  private func invalidate() {
    testResult = nil
    Task { await PlausibleStatsProvider.shared.invalidateAll() }
  }

  private func test() async {
    isTesting = true
    defer { isTesting = false }
    commitKey()
    commitEndpoint()
    guard let config = PlausibleSettings.config() else {
      testResult = statsEnabled
        ? "Add an API key and site first."
        : "Turn on website stats first."
      return
    }
    let client = PlausibleClient(configProvider: { config })
    do {
      let stats = try await client.aggregate(scope: .subtree("/"), range: .last7Days)
      testResult =
        "Connected — \(stats.visitors.formatted()) visitors on \(config.siteID) in the last 7 days."
    } catch {
      testResult = error.localizedDescription
    }
  }
}

private enum PlausibleSectionLoad: Sendable {
  case total(String, PlausibleStats)
  case trend(String, [PlausibleTimePoint])
}

/// Per-section dashboard data: a recent total for each row's badge, plus a
/// 12-month trend for the growth tiles. Every query flies at once.
///
/// Deliberately not one site-wide breakdown — that would be a single request
/// but a multi-thousand-row payload, and summing per-page rows overcounts
/// visitors. Aggregates keep the payloads tiny and let Plausible do the
/// visitor dedup properly. The request count is bounded by the permalink map
/// (a handful of sections), never by how many records exist.
@MainActor
public final class PlausibleSectionTotalsModel: ObservableObject {
  public init() {}

  @Published public private(set) var totals: [String: PlausibleStats] = [:]
  @Published public private(set) var trends: [String: [PlausibleTimePoint]] = [:]
  /// True while a section fan-out is in flight (with at least one scope to
  /// fetch), so the dashboard can show tile skeletons until totals/trends land.
  @Published public private(set) var isLoading = false

  public func load(entityIDs: [String], range: PlausibleRange = .last30Days) async {
    let map = PublicPermalinkMap()
    let scopes = entityIDs.compactMap { id -> (String, PublicPagePath)? in
      guard let scope = map.sectionScope(entityID: id, hubSlug: nil) else { return nil }
      return (id, scope)
    }
    guard !scopes.isEmpty else { return }

    isLoading = true
    defer { isLoading = false }

    var loadedTotals: [String: PlausibleStats] = [:]
    var loadedTrends: [String: [PlausibleTimePoint]] = [:]
    await withTaskGroup(of: PlausibleSectionLoad?.self) { group in
      for (id, scope) in scopes {
        group.addTask {
          guard let stats = await PlausibleStatsProvider.shared.aggregate(scope: scope, range: range)
          else { return nil }
          return .total(id, stats)
        }
        group.addTask {
          guard
            let points = await PlausibleStatsProvider.shared.timeSeries(
              scope: scope, range: .last12Months),
            !points.isEmpty
          else { return nil }
          return .trend(id, points)
        }
      }
      for await result in group {
        switch result {
        case .total(let id, let stats): loadedTotals[id] = stats
        case .trend(let id, let points): loadedTrends[id] = points
        case nil: break
        }
      }
    }
    guard !Task.isCancelled else { return }
    totals = loadedTotals
    trends = loadedTrends
  }

  /// `nil` for entities with no public pages — which is how a dashboard row
  /// signals it has nothing to measure.
  public func stats(for entityID: String) -> PlausibleStats? { totals[entityID] }

  /// Monthly points for an entity's section, oldest first.
  public func trend(for entityID: String) -> [PlausibleTimePoint]? { trends[entityID] }
}

/// One breakdown query per list screen: loads every tracked page under the
/// screen's scope, then each row looks up its slice with `stats(for:)`.
@MainActor
public final class PlausibleSectionStatsModel: ObservableObject {
  public init() {}

  @Published public private(set) var rows: [String: PlausibleStats] = [:]

  public func load(scope: PublicPagePath?, range: PlausibleRange = .last30Days) async {
    guard let scope else { return }
    let loaded = await PlausibleStatsProvider.shared.breakdown(scope: scope, range: range)
    guard !Task.isCancelled, let loaded else { return }
    rows = loaded
  }

  /// Sums every breakdown row the path matches: exact/wildcard paths hit one
  /// row; a subtree path rolls up the root page plus all descendants.
  /// `nil` when nothing matched (badge renders nothing).
  public func stats(for path: PublicPagePath?) -> PlausibleStats? {
    guard let path else { return nil }
    var total: PlausibleStats?
    for (pagePath, stats) in rows where path.matches(pagePath) {
      total = (total ?? .zero) + stats
    }
    return total
  }
}
