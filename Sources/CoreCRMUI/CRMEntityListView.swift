import CoreKit
import EnvisioningUI
import SwiftUI

private enum EntitySortOrder: String, CaseIterable, Identifiable {
  case newest
  case oldest
  case dateAscending
  case dateDescending
  case nameAscending
  case nameDescending
  case mostViewed
  case mostVisitors

  var id: String { rawValue }

  var label: String {
    switch self {
    case .newest: "Newest first"
    case .oldest: "Oldest first"
    case .dateAscending: "Date: earliest first"
    case .dateDescending: "Date: latest first"
    case .nameAscending: "Name A–Z"
    case .nameDescending: "Name Z–A"
    case .mostViewed: "Most viewed"
    case .mostVisitors: "Most visitors"
    }
  }

  var symbol: String {
    switch self {
    case .newest: "arrow.down"
    case .oldest: "arrow.up"
    case .dateAscending: "calendar"
    case .dateDescending: "calendar.badge.clock"
    case .nameAscending: "textformat.abc"
    case .nameDescending: "textformat.abc.dottedunderline"
    case .mostViewed: "chart.bar"
    case .mostVisitors: "person.2"
    }
  }

  var isAlphabetical: Bool {
    self == .nameAscending || self == .nameDescending
  }

  /// Orders that sort on the entity's own date field — only offered for
  /// entities that have one (events, milestones, tasks, …).
  var usesDateField: Bool {
    self == .dateAscending || self == .dateDescending
  }

  /// Orders that rank by Plausible data — only offered for entities whose
  /// records are public pages, and only meaningful once stats have loaded.
  var usesWebsiteStats: Bool {
    self == .mostViewed || self == .mostVisitors
  }
}

@MainActor
private final class EntityListModel: ObservableObject {
  @Published var records: [CRMRecord] = []
  // Start in the loading state. SwiftUI renders once before the view's async
  // task begins; starting false briefly showed the empty-state UI on every
  // cold list open, even when records were about to arrive.
  @Published var isLoading = true
  @Published var errorMessage: String?
  @Published var isShowingCachedData = false
  @Published private(set) var sortOrder: EntitySortOrder
  /// Field name → selected stored value. Deliberately *not* persisted, unlike
  /// sort: a sticky sort is benign, but a sticky filter silently hides records
  /// on a later launch and reads as missing data.
  @Published private(set) var filters: [String: String] = [:]

  private let contract: CRMEntityContract
  private let repository: CRMRepository
  private var allRecords: [CRMRecord] = []
  private var cachedAt: Date?
  private var didLoadCache = false
  private var currentQuery = ""
  private var websiteStats: [String: PlausibleStats] = [:]

  init(contract: CRMEntityContract, repository: CRMRepository) {
    self.contract = contract
    self.repository = repository
    let savedSort = UserDefaults.standard.string(forKey: Self.sortKey(for: contract.id))
    var initial = savedSort.flatMap(EntitySortOrder.init(rawValue:)) ?? .newest
    // A persisted date sort is invalid if this entity has no date field (e.g.
    // the saved order carried over from a different list); fall back gracefully.
    if initial.usesDateField, contract.dateField == nil { initial = .newest }
    sortOrder = initial
  }

  func setSortOrder(_ order: EntitySortOrder) {
    guard sortOrder != order else { return }
    sortOrder = order
    UserDefaults.standard.set(order.rawValue, forKey: Self.sortKey(for: contract.id))
    applyFilter(currentQuery)
  }

  /// Website stats keyed by record id. Arrives after the list renders (the
  /// screen's one breakdown query), so a stats-ranked sort re-applies when it
  /// lands rather than freezing whatever order was on screen first.
  func setWebsiteStats(_ stats: [String: PlausibleStats]) {
    guard websiteStats != stats else { return }
    websiteStats = stats
    guard sortOrder.usesWebsiteStats else { return }
    applyFilter(currentQuery)
  }

  /// An empty `value` clears the field's filter.
  func setFilter(field: String, value: String) {
    if value.isEmpty {
      guard filters.removeValue(forKey: field) != nil else { return }
    } else {
      guard filters[field] != value else { return }
      filters[field] = value
    }
    applyFilter(currentQuery)
  }

  func clearFilters() {
    guard !filters.isEmpty else { return }
    filters.removeAll()
    applyFilter(currentQuery)
  }

  func load(query: String = "", forceRefresh: Bool = false) async {
    currentQuery = query
    if !didLoadCache {
      if let cached = try? await repository.cachedRecords(entity: contract.id) {
        allRecords = cached.records
        cachedAt = cached.fetchedAt
      }
      didLoadCache = true
    }

    applyFilter(query)
    let isFresh = repository.recordsAreFresh(fetchedAt: cachedAt)
    guard forceRefresh || allRecords.isEmpty || !isFresh else {
      isLoading = false
      return
    }

    isLoading = allRecords.isEmpty
    defer {
      if !Task.isCancelled {
        isLoading = false
      }
    }
    do {
      allRecords = try await repository.refreshRecords(
        entity: contract.id,
        primaryField: contract.primaryField
      )
      cachedAt = Date()
      applyFilter(query)
      isShowingCachedData = false
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch let error as URLError where error.code == .cancelled {
      return
    } catch {
      if allRecords.isEmpty {
        errorMessage = error.localizedDescription
      } else {
        isShowingCachedData = true
      }
    }
  }

  func move(recordID: String, field: String, value: String) async -> Bool {
    guard contract.canUpdate,
      let index = allRecords.firstIndex(where: { $0.id == recordID })
    else { return false }

    let previous = allRecords[index]
    var optimistic = previous
    optimistic[field] = .string(value)
    allRecords[index] = optimistic
    applyFilter(currentQuery)

    do {
      let saved = try await repository.save(
        entity: contract.id,
        id: recordID,
        values: [field: .string(value)],
        primaryField: contract.primaryField
      )
      if let savedIndex = allRecords.firstIndex(where: { $0.id == recordID }) {
        // Merge rather than replace: a status PATCH may echo back a partial
        // record, and a wholesale swap would drop fields it omits (due date,
        // assignee) — which read as the subtitle blinking out while a completed
        // task lingers on screen before fading. Server-returned fields win.
        var merged = allRecords[savedIndex]
        for (key, value) in saved.fields { merged[key] = value }
        allRecords[savedIndex] = merged
      }
      applyFilter(currentQuery)
      errorMessage = nil
      return true
    } catch {
      if let rollbackIndex = allRecords.firstIndex(where: { $0.id == recordID }) {
        allRecords[rollbackIndex] = previous
      }
      applyFilter(currentQuery)
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func applyFilter(_ query: String) {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    // Field filters narrow first — they're cheap equality checks, and every
    // active one must match (AND), so the text scan runs over less.
    let active = filters.compactMap { name, value -> CRMListFilter? in
      guard let field = contract.fields.first(where: { $0.name == name }) else { return nil }
      return CRMListFilter(field: name, value: value, kind: field.kind)
    }
    var filtered = active.isEmpty ? allRecords : allRecords.filter { record in
      active.allSatisfy { $0.matches(record) }
    }
    if !normalized.isEmpty {
      filtered = filtered.filter { record in
        record.fields.values.map(\.searchableText)
          .joined(separator: " ")
          .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
          .contains(normalized)
      }
    }
    records = filtered.sorted(by: comesBefore)
  }

  private func comesBefore(_ left: CRMRecord, _ right: CRMRecord) -> Bool {
    switch sortOrder {
    case .newest:
      return dateValue(left) > dateValue(right)
    case .oldest:
      return dateValue(left) < dateValue(right)
    case .dateAscending:
      return ordersByDate(left, right, ascending: true)
    case .dateDescending:
      return ordersByDate(left, right, ascending: false)
    case .nameAscending:
      return nameValue(left).localizedStandardCompare(nameValue(right)) == .orderedAscending
    case .nameDescending:
      return nameValue(left).localizedStandardCompare(nameValue(right)) == .orderedDescending
    case .mostViewed:
      return ranksBefore(left, right) { $0.pageviews }
    case .mostVisitors:
      return ranksBefore(left, right) { $0.visitors }
    }
  }

  /// Orders by the entity's own date field. Undated records fall to the bottom
  /// in both directions (a missing date shouldn't outrank a real one), with a
  /// stable name order among them. Values are ISO date/timestamp strings, so a
  /// lexicographic compare is chronological.
  private func ordersByDate(
    _ left: CRMRecord, _ right: CRMRecord, ascending: Bool
  ) -> Bool {
    let l = eventDateValue(left)
    let r = eventDateValue(right)
    if l.isEmpty != r.isEmpty { return !l.isEmpty }
    if l == r {
      return nameValue(left).localizedStandardCompare(nameValue(right)) == .orderedAscending
    }
    return ascending ? l < r : l > r
  }

  private func eventDateValue(_ record: CRMRecord) -> String {
    guard let field = contract.dateField else { return "" }
    return record[field]?.stringValue ?? ""
  }

  /// Ranks by a website metric, descending. Records with no traffic — or none
  /// yet loaded — fall to the bottom and keep a stable name order there, so an
  /// unmeasured record never looks like a zero-traffic one that outranks it.
  private func ranksBefore(
    _ left: CRMRecord, _ right: CRMRecord, by metric: (PlausibleStats) -> Int
  ) -> Bool {
    let leftValue = websiteStats[left.id].map(metric)
    let rightValue = websiteStats[right.id].map(metric)
    switch (leftValue, rightValue) {
    case (let l?, let r?) where l != r:
      return l > r
    case (nil, .some):
      return false
    case (.some, nil):
      return true
    default:
      return nameValue(left).localizedStandardCompare(nameValue(right)) == .orderedAscending
    }
  }

  private func dateValue(_ record: CRMRecord) -> String {
    record["created_at"]?.stringValue ?? ""
  }

  private func nameValue(_ record: CRMRecord) -> String {
    record.displayName(primaryField: contract.primaryField)
  }

  private static func sortKey(for entity: String) -> String {
    "crm.list.sort.\(entity)"
  }
}

public struct EntityListView: View {
  @Environment(CRMFavoriteCenter.self) private var favorites: CRMFavoriteCenter?
  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let onToast: (String) -> Void

  @StateObject private var model: EntityListModel
  @StateObject private var sectionStats = PlausibleSectionStatsModel()
  @State private var searchText = ""
  @State private var presentingCreate = false
  @State private var createPrefill: [String: JSONValue] = [:]
  @State private var pendingToastMessage: String?
  /// nil = follow the layout default (`resolvedPresentation`); a non-nil value
  /// is an explicit user choice from the toolbar picker.
  @State private var presentationOverride: EntityPresentation?
  @State private var tableSelection: CRMRecord.ID?
  /// The record the table opened (double-click / Return), pushed as detail.
  @State private var openedTableRecord: CRMRecord?
  @FocusState private var searchFocused: Bool
  @State private var contextFeedback = 0
  /// Cached navigation, for building a record's web permalink in the context
  /// menu (same source the detail view's Copy/Share affordance uses).
  @State private var navigation: CRMNavigationData?
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  // Tasks just concluded via the checkbox: kept on screen, crossed out, for a
  // few seconds before the filter drops them, so a completion is never a
  // jarring instant vanish.
  @State private var lingeringTaskIDs: Set<String> = []
  @AppStorage("crm.tasks.showCompleted") private var showCompleted = false

  public init(
    contract: CRMEntityContract,
    allContracts: [CRMEntityContract],
    repository: CRMRepository,
    onToast: @escaping (String) -> Void
  ) {
    self.contract = contract
    self.allContracts = allContracts
    self.repository = repository
    self.onToast = onToast
    _model = StateObject(
      wrappedValue: EntityListModel(contract: contract, repository: repository)
    )
  }

  /// True where a multi-column table is worthwhile: always on macOS (the Dock
  /// app is a wide window), and only in regular width on iOS (never iPhone).
  private var isWideLayout: Bool {
    #if os(macOS)
      return true
    #else
      return horizontalSizeClass == .regular
    #endif
  }

  /// The web CRM's table columns for this entity, or nil if it has no table
  /// surface (events, docs, tasks, signals sections stay lists).
  private var tableColumns: [CRMColumn]? {
    // `Table` with dynamic columns (`TableColumnForEach`) is macOS 14.4 / iOS
    // 17.4; below that the list presentation stands in for the table.
    guard #available(macOS 14.4, iOS 17.4, *) else { return nil }
    return crmTableColumns(for: contract)
  }

  /// Whether this entity can be shown as a table on the current screen.
  private var tableAvailable: Bool { isWideLayout && tableColumns != nil }

  /// The presentation actually rendered: an explicit picker choice if any, else
  /// a table on wide screens for entities that have a table config, else a list.
  private var resolvedPresentation: EntityPresentation {
    if let presentationOverride { return presentationOverride }
    if tableAvailable { return .table }
    return .list
  }

  /// Picker binding: shows the presentation actually on screen, and records an
  /// explicit override when the user switches.
  private var presentationSelection: Binding<EntityPresentation> {
    Binding(
      get: { resolvedPresentation },
      set: { presentationOverride = $0 }
    )
  }

  @ViewBuilder
  private func detailView(for record: CRMRecord) -> some View {
    EntityDetailView(
      contract: contract,
      allContracts: allContracts,
      record: record,
      repository: repository,
      onToast: onToast,
      onChanged: reload
    )
  }

  /// The screen body, kept apart from the modifier chain in `body`: as one
  /// expression the two together were more than the type checker would finish.
  @ViewBuilder
  private var listContent: some View {
    if model.isLoading && model.records.isEmpty {
      EntityListLoadingView()
    } else if model.records.isEmpty {
      ContentUnavailableView.search(text: searchText)
    } else if resolvedPresentation == .board, let board = contract.board {
      CRMBoardView(
        contract: contract,
        board: board,
        records: model.records,
        onMove: moveRecord,
        onRefresh: { await refreshAll() },
        onFavoriteError: onToast
      )
    } else if contract.id == "tasks" {
      taskChecklist
    } else if resolvedPresentation == .table, let columns = tableColumns {
      CRMEntityTableView(
        entityID: contract.id,
        columns: columns,
        records: model.records,
        selection: $tableSelection,
        onOpen: { openedTableRecord = $0 },
        rowMenu: { recordContextMenu($0) },
        favoriteAccessory: favorites == nil
          ? nil
          : { record in
            guard let target = favorites?.target(for: record, in: contract) else {
              return AnyView(EmptyView())
            }
            return AnyView(CRMFavoriteToggleButton(target: target, onError: onToast))
          }
      )
    } else {
      EnvisioningList {
        if contract.id == "contacts", model.sortOrder.isAlphabetical {
          ForEach(alphabeticalSections) { section in
            Section(section.title) {
              ForEach(section.records) { record in
                recordButton(record)
              }
            }
            // The A–Z index rail is an iOS 26 affordance.
            .crmSectionIndexLabel(section.title)
          }
        } else {
          ForEach(model.records) { record in
            recordButton(record)
          }
        }
      }
      .crmListSectionIndexVisible(contract.id == "contacts" && model.sortOrder.isAlphabetical)
      .refreshable { await refreshAll() }
    }
  }

  public var body: some View {
    listContent
    .navigationTitle(contract.pluralLabel)
    .listCountSubtitle(model.isLoading && model.records.isEmpty ? nil : model.records.count)
    .searchable(text: $searchText, prompt: "Search \(contract.pluralLabel.lowercased())")
    .searchFocusedCompat($searchFocused)
    .task(id: searchText) {
      if !searchText.isEmpty {
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard !Task.isCancelled else { return }
      await model.load(query: searchText)
    }
    .task {
      // One breakdown query for the whole screen; entities with no public
      // pages resolve a nil scope and this no-ops.
      await sectionStats.load(scope: statsScope)
    }
    // TTL-gated (see `refreshAll`): a quick app switch replays the memo, a
    // long absence re-queries.
    .onAppActivation { Task { await sectionStats.load(scope: statsScope) } }
    .onRefreshRequest { Task { await refreshAll() } }
    .task { navigation = try? await repository.cachedNavigation() }
    // Hand the model stats keyed by record id so it can rank by them. Keyed
    // on both sides: the breakdown and the records arrive independently.
    .task(id: statsKeyingInputs) { model.setWebsiteStats(recordStats()) }
    .toolbar {
      ToolbarItem(placement: .secondaryAction) {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
          Picker("Order", selection: Binding(
            get: { model.sortOrder },
            set: { model.setSortOrder($0) }
          )) {
            ForEach(sortOrders) { order in
              Label(order.label, systemImage: order.symbol).tag(order)
            }
          }
        }
      }
      if !filterableFields.isEmpty {
        ToolbarItem(placement: .secondaryAction) { filterMenu }
      }
      if contract.board != nil || tableAvailable {
        ToolbarItem(placement: .secondaryAction) {
          Picker("Presentation", selection: presentationSelection) {
            Label("List", systemImage: "list.bullet").tag(EntityPresentation.list)
            if tableAvailable {
              Label("Table", systemImage: "tablecells").tag(EntityPresentation.table)
            }
            if contract.board != nil {
              Label("Board", systemImage: "rectangle.split.3x1").tag(EntityPresentation.board)
            }
          }
          .pickerStyle(.menu)
        }
      }
      if contract.id == "tasks" {
        ToolbarItem(placement: .secondaryAction) {
          Toggle(isOn: $showCompleted) {
            Label("Show Completed", systemImage: "checkmark.circle")
          }
        }
      }
      if model.isShowingCachedData {
        ToolbarItem(placement: .secondaryAction) {
          Image(systemName: "wifi.slash")
            .foregroundStyle(crmSecondaryText)
            .accessibilityLabel("Showing cached data")
        }
      }
      if contract.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Add", systemImage: "plus") { presentCreate() }
        }
      }
    }
    .sheet(isPresented: $presentingCreate, onDismiss: finishSheet) {
      DynamicEntityFormView(
        contract: contract,
        allContracts: allContracts,
        repository: repository,
        initialValues: createPrefill,
        onCompleted: { pendingToastMessage = $0 }
      )
    }
    .navigationDestination(for: CRMRecord.self) { record in
      detailView(for: record)
    }
    // The table opens on its primary action (double-click / Return) rather than
    // on mere selection, so navigation is keyed off the opened record. SwiftUI
    // clears the item on back automatically.
    .navigationDestination(item: $openedTableRecord) { record in
      detailView(for: record)
    }
    .alert("Unable to Load", isPresented: Binding(
      get: { model.errorMessage != nil },
      set: { if !$0 { model.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .sensoryFeedback(.selection, trigger: contextFeedback)
    // Sort and filter both silently rewrite what's on screen, so they get the
    // same `.selection` the context actions use. Both only fire on an actual
    // change, never on first render.
    .sensoryFeedback(.selection, trigger: model.sortOrder)
    .sensoryFeedback(.selection, trigger: model.filters)
    // Covers a failed board move or checkbox toggle, whose optimistic change is
    // rolled back under the user — the one case where the list visibly undoes
    // itself and needs to say why.
    .sensoryFeedback(.error, trigger: model.errorMessage)
    .background {
      Group {
        Button("Find in \(contract.pluralLabel)") { searchFocused = true }
          .keyboardShortcut("f", modifiers: .command)

        // iOS only: on macOS the window owns the single ⌘R (see
        // `globalKeyboardCommands`), which reaches this screen through
        // `onRefreshRequest`. Two buttons claiming ⌘R resolve unpredictably.
        #if os(iOS)
          Button("Refresh \(contract.pluralLabel)") {
            Task { await refreshAll() }
          }
          .keyboardShortcut("r", modifiers: .command)
        #endif

        if contract.canCreate {
          Button("New \(contract.singularLabel)") { presentCreate() }
            .keyboardShortcut("n", modifiers: .command)
        }
      }
      .hidden()
    }
  }

  private func moveRecord(_ recordID: String, _ field: String, _ value: String) {
    Task {
      if await model.move(recordID: recordID, field: field, value: value) {
        onToast("Moved to \(value)")
      }
    }
  }

  private func reload() {
    Task { await model.load(query: searchText, forceRefresh: true) }
  }

  private func presentCreate(prefill: [String: JSONValue] = [:]) {
    createPrefill = prefill
    presentingCreate = true
  }

  private func finishSheet() {
    createPrefill = [:]
    reload()
    guard let pendingToastMessage else { return }
    self.pendingToastMessage = nil
    onToast(pendingToastMessage)
  }

  private var alphabeticalSections: [AlphabeticalSection] {
    let grouped = Dictionary(grouping: model.records) { record in
      alphabeticalIndexTitle(
        for: record.displayName(primaryField: contract.primaryField)
      )
    }

    let ascendingTitles = grouped.keys.sorted { left, right in
      if left == "#" { return false }
      if right == "#" { return true }
      return left.localizedStandardCompare(right) == .orderedAscending
    }
    let titles = model.sortOrder == .nameDescending
      ? Array(ascendingTitles.reversed())
      : ascendingTitles

    return titles.map { title in
      AlphabeticalSection(
        title: title,
        records: grouped[title, default: []].sorted {
          let comparison = $0.displayName(primaryField: contract.primaryField).localizedStandardCompare(
            $1.displayName(primaryField: contract.primaryField)
          )
          return model.sortOrder == .nameDescending
            ? comparison == .orderedDescending
            : comparison == .orderedAscending
        }
      )
    }
  }

  private func alphabeticalIndexTitle(for value: String) -> String {
    let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    guard let first = folded.first, first.isLetter else { return "#" }
    return String(first).uppercased(with: .current)
  }

  /// Date orders are hidden for entities with no date field; website-ranked
  /// orders are hidden for entities with no public pages ("Most viewed" on a
  /// CRM list would rank by nothing).
  private var sortOrders: [EntitySortOrder] {
    let hasPublicPages =
      PublicPermalinkMap().sectionScope(entityID: contract.id, hubSlug: nil) != nil
    let hasDateField = contract.dateField != nil
    return EntitySortOrder.allCases.filter { order in
      if order.usesWebsiteStats, !hasPublicPages { return false }
      if order.usesDateField, !hasDateField { return false }
      return true
    }
  }

  /// Changes when either input to the stats lookup does.
  /// The screen's website-stats scope — `nil` for entities with no public
  /// pages, which makes every stats load a no-op.
  private var statsScope: PublicPagePath? {
    PublicPermalinkMap().sectionScope(entityID: contract.id, hubSlug: nil)
  }

  /// Pull-to-refresh: records first, then the website numbers. The stats task
  /// has no id to re-fire on and the provider memoizes each query for 5
  /// minutes, so an explicit refresh has to drop the cache and re-run the
  /// breakdown itself.
  private func refreshAll() async {
    await model.load(query: searchText, forceRefresh: true)
    guard statsScope != nil else { return }
    await PlausibleStatsProvider.shared.invalidateAll()
    await sectionStats.load(scope: statsScope)
  }

  private var statsKeyingInputs: Int {
    var hasher = Hasher()
    hasher.combine(sectionStats.rows.count)
    hasher.combine(model.records.count)
    return hasher.finalize()
  }

  /// The screen's breakdown re-keyed from page path to record id, which is
  /// what the model sorts on.
  private func recordStats() -> [String: PlausibleStats] {
    let map = PublicPermalinkMap()
    var byRecord: [String: PlausibleStats] = [:]
    for record in model.records {
      guard
        let path = map.pagePath(entityID: contract.id, record: record, hubSlug: nil),
        let stats = sectionStats.stats(for: path)
      else { continue }
      byRecord[record.id] = stats
    }
    return byRecord
  }

  @ViewBuilder
  private func recordButton(_ record: CRMRecord) -> some View {
    let row = NavigationLink(value: record) {
      CRMRecordRow(
        contract: contract,
        record: record,
        plausibleStats: sectionStats.stats(
          for: PublicPermalinkMap().pagePath(
            entityID: contract.id, record: record, hubSlug: nil))
      )
    }
    if let target = favorites?.target(for: record, in: contract) {
      HStack(spacing: 8) {
        row
        CRMFavoriteToggleButton(target: target, onError: onToast)
      }
      .buttonStyle(.plain)
      .contextMenu { recordContextMenu(record) }
    } else {
      row
        .contextMenu { recordContextMenu(record) }
    }
  }

  // MARK: - Tasks

  /// Tasks render as a Reminders-style checklist grouped into a section per
  /// project, each row led by a checkbox that completes (or reopens) the task in
  /// place. Completed tasks stay visible — checked and struck through, sorted to
  /// the bottom of their section; cancelled tasks are hidden.
  @ViewBuilder
  private var taskChecklist: some View {
    let sections = taskProjectSections
    if sections.isEmpty {
      ContentUnavailableView {
        Label("All Caught Up", systemImage: "checkmark.circle")
      } description: {
        Text("No open tasks.")
      } actions: {
        if contract.canCreate {
          Button("New Task", systemImage: "plus") { presentCreate() }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
      }
    } else {
      EnvisioningList {
        ForEach(sections) { section in
          Section {
            ForEach(section.records) { record in
              taskRow(record)
            }
          } header: {
            taskSectionHeader(section)
          }
        }
        if contract.canCreate {
          Section {
            Button {
              presentCreate()
            } label: {
              Label("New Task", systemImage: "plus.circle.fill")
                .font(.body.weight(.medium))
            }
            .tint(.primary)
          }
        }
      }
      .refreshable { await refreshAll() }
    }
  }

  private func taskSectionHeader(_ section: TaskProjectSection) -> some View {
    HStack {
      Text(section.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .textCase(nil)
      Spacer()
      if contract.canCreate {
        Button {
          presentCreate(prefill: taskCreatePrefill(for: section))
        } label: {
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .accessibilityLabel("New task in \(section.title)")
      }
    }
  }

  private func taskCreatePrefill(for section: TaskProjectSection) -> [String: JSONValue] {
    guard let projectId = section.projectId else { return [:] }
    return ["project_id": .string(projectId)]
  }

  @ViewBuilder
  private func taskRow(_ record: CRMRecord) -> some View {
    let done = isTaskDone(record)
    HStack(spacing: CRMListRow.iconSpacing) {
      Button {
        toggleTask(record)
      } label: {
        Image(systemName: done ? "checkmark.square.fill" : "square")
          .font(.title2)
          .foregroundStyle(done ? Color.primary : crmSecondaryText)
          .contentShape(.rect(cornerRadius: 6))
      }
      .buttonStyle(.borderless)
      .disabled(!contract.canUpdate)
      .accessibilityLabel(done ? "Reopen \(taskTitle(record))" : "Complete \(taskTitle(record))")

      NavigationLink(value: record) {
        VStack(alignment: .leading, spacing: 3) {
          Text(taskTitle(record))
            .font(.body)
            .strikethrough(done, color: .secondary)
            .foregroundStyle(done ? .secondary : .primary)
          let due = taskDueLabel(record)
          let party = taskResponsibleLabel(record)
          if due != nil || party != nil {
            VStack(alignment: .leading, spacing: CRMListRow.indicatorSpacing) {
              if let due {
                Label(due, systemImage: "calendar")
                  .foregroundStyle(crmSecondaryText)
              }
              if let party {
                Label(party, systemImage: "person")
                  .foregroundStyle(crmSecondaryText)
              }
            }
            .font(.caption)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      if let target = favorites?.target(for: record, in: contract) {
        CRMFavoriteToggleButton(target: target, onError: onToast)
      }
    }
    .contextMenu { recordContextMenu(record) }
  }

  private func toggleTask(_ record: CRMRecord) {
    guard contract.canUpdate else { return }
    contextFeedback += 1
    let done = isTaskDone(record)
    let name = taskTitle(record)
    let id = record.id
    if done {
      // Reopening: cancel any pending linger so the row behaves normally.
      lingeringTaskIDs.remove(id)
    } else {
      // Concluding: hold the crossed-out row on screen briefly before it drops out.
      lingeringTaskIDs.insert(id)
      scheduleLingerRemoval(id)
    }
    Task {
      if await model.move(
        recordID: id, field: "status", value: done ? "pending" : "completed")
      {
        onToast(done ? "Reopened \(name)" : "Completed \(name)")
      } else {
        // Save failed and the optimistic status rolled back — drop the linger too.
        lingeringTaskIDs.remove(id)
      }
    }
  }

  /// After a short grace period, let a concluded task fade out of the list.
  private func scheduleLingerRemoval(_ id: String, after seconds: Double = 3) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      withAnimation(.easeInOut(duration: 0.3)) {
        _ = lingeringTaskIDs.remove(id)
      }
    }
  }

  private var taskProjectSections: [TaskProjectSection] {
    let visible = model.records.filter { record in
      let status = record["status"]?.stringValue ?? ""
      if status == "cancelled" { return false }
      // A just-concluded task lingers, crossed out, before dropping out.
      if status == "completed" && !showCompleted && !lingeringTaskIDs.contains(record.id) {
        return false
      }
      return true
    }
    let grouped = Dictionary(grouping: visible) { taskProjectName($0) ?? "" }
    let namedTitles = grouped.keys.filter { !$0.isEmpty }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var sections = namedTitles.map { title -> TaskProjectSection in
      let records = sortedTasks(grouped[title] ?? [])
      let projectId = records.first.flatMap { $0["project_id"]?.stringValue }
      return TaskProjectSection(id: title, title: title, projectId: projectId, records: records)
    }
    if let noProject = grouped[""], !noProject.isEmpty {
      sections.append(
        TaskProjectSection(
          id: "\u{FFFF}no-project", title: "No Project", projectId: nil,
          records: sortedTasks(noProject))
      )
    }
    return sections
  }

  private func taskProjectName(_ record: CRMRecord) -> String? {
    guard let name = record["project"]?.objectValue?["title"]?.stringValue, !name.isEmpty else {
      return nil
    }
    return name
  }

  /// Open tasks first (soonest due, undated last), completed tasks sink to the
  /// bottom ordered by most recent activity.
  private func sortedTasks(_ records: [CRMRecord]) -> [CRMRecord] {
    records.sorted { left, right in
      // A lingering task keeps its open-task position until it fades out,
      // rather than jumping to the bottom the instant it's concluded.
      let leftDone = isTaskDone(left) && !lingeringTaskIDs.contains(left.id)
      let rightDone = isTaskDone(right) && !lingeringTaskIDs.contains(right.id)
      if leftDone != rightDone { return !leftDone }

      if !leftDone {
        let leftDue = taskDueKey(left)
        let rightDue = taskDueKey(right)
        if leftDue != rightDue {
          switch (leftDue, rightDue) {
          case let (lhs?, rhs?): return lhs < rhs
          case (_?, nil): return true
          case (nil, _?): return false
          case (nil, nil): break
          }
        }
      }
      return taskRecency(left) > taskRecency(right)
    }
  }

  private func isTaskDone(_ record: CRMRecord) -> Bool {
    record["status"]?.stringValue == "completed"
  }

  /// Who owns the task. Team tasks show the assignee's name when the backend
  /// resolved it, otherwise "Envisioning"; `unassigned` is hidden to keep rows quiet.
  private func taskResponsibleLabel(_ record: CRMRecord) -> String? {
    switch record["responsible_party"]?.stringValue {
    case "team": return taskAssigneeName(record) ?? "Envisioning"
    case "client": return "Client"
    default: return nil
    }
  }

  private func taskAssigneeName(_ record: CRMRecord) -> String? {
    let assignee = record["assignee"]?.objectValue
    for candidate in [assignee?["name"], record["assignee_name"], assignee?["email"]] {
      if let value = candidate?.stringValue, !value.isEmpty { return value }
    }
    return nil
  }

  private func taskRecency(_ record: CRMRecord) -> String {
    record["completed_at"]?.stringValue ?? record["created_at"]?.stringValue ?? ""
  }

  private func taskTitle(_ record: CRMRecord) -> String {
    record.displayName(primaryField: contract.primaryField, fallback: contract.singularLabel)
  }

  private func taskDueKey(_ record: CRMRecord) -> String? {
    let value = record["due_date"]?.stringValue
    return (value?.isEmpty == false) ? value : nil
  }

  private func taskDueDate(_ record: CRMRecord) -> Date? {
    guard let raw = taskDueKey(record) else { return nil }
    return Self.taskDueFormatter.date(from: raw)
  }

  private func taskDueLabel(_ record: CRMRecord) -> String? {
    guard let date = taskDueDate(record) else { return nil }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  private static let taskDueFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  /// Contract-derived, so a new filterable field on the server appears here
  /// with no client change — and an entity with none shows no Filter control.
  private var filterableFields: [CRMFieldContract] { contract.filterableFields }

  private var filterMenu: some View {
    Menu(
      "Filter",
      systemImage: model.filters.isEmpty
        ? "line.3.horizontal.decrease.circle"
        : "line.3.horizontal.decrease.circle.fill"
    ) {
      ForEach(filterableFields) { field in
        Menu(field.label) {
          Picker(field.label, selection: Binding(
            get: { model.filters[field.name] ?? "" },
            set: { model.setFilter(field: field.name, value: $0) }
          )) {
            Text("Any").tag("")
            ForEach(filterOptions(for: field)) { option in
              Text(option.label).tag(option.value)
            }
          }
        }
      }
      if !model.filters.isEmpty {
        Divider()
        Button("Clear Filters", systemImage: "xmark.circle") { model.clearFilters() }
      }
    }
  }

  /// Toggles publish no options — their closed set is simply yes/no.
  private func filterOptions(for field: CRMFieldContract) -> [CRMFieldOption] {
    guard field.kind != "toggle" else {
      return [
        CRMFieldOption(value: "true", label: "Yes"),
        CRMFieldOption(value: "false", label: "No"),
      ]
    }
    return field.options ?? []
  }

  @ViewBuilder
  private func recordContextMenu(_ record: CRMRecord) -> some View {
    Button("Copy name", systemImage: "doc.on.doc") {
      copyToPasteboard(record.displayName(primaryField: contract.primaryField))
      contextFeedback += 1
      onToast("Name copied")
    }
    if let link = navigation?.recordWebURL(entityId: contract.id, recordID: record.id) {
      Button("Copy Link", systemImage: "link") {
        copyToPasteboard(link.absoluteString)
        contextFeedback += 1
        onToast("Link copied")
      }
    }
    if let shareURL = ServerConfig.publicShareURL(entityID: contract.id, recordID: record.id) {
      Button("Copy Public Link", systemImage: "globe") {
        copyToPasteboard(shareURL.absoluteString)
        contextFeedback += 1
        onToast("Public link copied")
      }
    }
    if let email = record["email"]?.stringValue,
      let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "mailto:\(encoded)") {
      Link(destination: url) { Label("Email", systemImage: "envelope") }
    }
    if let rawURL = record["website"]?.stringValue ?? record["url"]?.stringValue,
      let url = URL(string: rawURL) {
      Link(destination: url) { Label("Open link", systemImage: "arrow.up.right.square") }
    }
    if contract.canUpdate,
      let board = contract.board,
      let options = contract.fields.first(where: { $0.name == board.field })?.options {
      Menu("Move", systemImage: "arrow.left.arrow.right") {
        ForEach(options.filter { $0.value != record[board.field]?.stringValue }) { option in
          Button(option.label) { moveRecord(record.id, board.field, option.value) }
        }
      }
    }
  }
}

/// Holds the list's shape while its first page is loading, avoiding both an
/// empty-state flash and a blank screen with only an indeterminate spinner.
struct EntityListLoadingView: View {
  var body: some View {
    EnvisioningList {
      ForEach(0..<8, id: \.self) { index in
        HStack(spacing: 12) {
          Circle()
            .fill(.quaternary)
            .frame(width: 34, height: 34)

          VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: index.isMultiple(of: 3) ? 150 : 190, height: 10)
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: index.isMultiple(of: 2) ? 105 : 135, height: 8)
          }
        }
        .padding(.vertical, 3)
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading records")
  }
}

private enum EntityPresentation: Hashable {
  case list
  case board
  case table
}

private struct CRMBoardView: View {
  let contract: CRMEntityContract
  let board: CRMBoardContract
  let records: [CRMRecord]
  let onMove: (String, String, String) -> Void
  let onRefresh: () async -> Void
  let onFavoriteError: (String) -> Void

  private var columns: [CRMFieldOption] {
    contract.fields.first { $0.name == board.field }?.options ?? []
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(columns) { column in
            CRMBoardColumnView(
              contract: contract,
              board: board,
              column: column,
              columns: columns,
              records: records(in: column),
              onMove: onMove,
              onRefresh: onRefresh,
              onFavoriteError: onFavoriteError
            )
            .frame(width: min(320, geometry.size.width * 0.84))
          }
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .scrollIndicators(.hidden)
    }
  }

  private func records(in column: CRMFieldOption) -> [CRMRecord] {
    records.filter { $0[board.field]?.stringValue == column.value }
  }
}

private struct CRMBoardColumnView: View {
  @Environment(CRMFavoriteCenter.self) private var favorites: CRMFavoriteCenter?
  let contract: CRMEntityContract
  let board: CRMBoardContract
  let column: CRMFieldOption
  let columns: [CRMFieldOption]
  let records: [CRMRecord]
  let onMove: (String, String, String) -> Void
  let onRefresh: () async -> Void
  let onFavoriteError: (String) -> Void

  @State private var isTargeted = false

  private var canDrop: Bool { contract.canUpdate }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(column.label)
          .font(.headline)
        Spacer()
        Text(records.count, format: .number)
          .font(.caption.monospacedDigit())
          .foregroundStyle(crmSecondaryText)
      }
      .padding(.horizontal, 4)

      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(records) { record in
            card(record)
          }
          if isTargeted {
            dropPlaceholder
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
      }
      .refreshable { await onRefresh() }
    }
    .padding(12)
    .background(columnBackground)
    .overlay {
      if isTargeted {
        RoundedRectangle(cornerRadius: EnvisioningRadius.card)
          .strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
    .dropDestination(for: String.self) { recordIDs, _ in
      guard canDrop else { return false }
      var moved = false
      for recordID in recordIDs where records.allSatisfy({ $0.id != recordID }) {
        onMove(recordID, board.field, column.value)
        moved = true
      }
      return moved
    } isTargeted: { targeted in
      guard canDrop else { return }
      isTargeted = targeted
    }
    .animation(.easeInOut(duration: 0.15), value: isTargeted)
  }

  @ViewBuilder
  private var columnBackground: some View {
    RoundedRectangle(cornerRadius: EnvisioningRadius.card)
      .fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.fill.quinary))
  }

  private var dropPlaceholder: some View {
    RoundedRectangle(cornerRadius: EnvisioningRadius.card)
      .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
      .frame(height: 52)
      .overlay {
        Label("Move to \(column.label)", systemImage: "arrow.down")
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.primary)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.96)))
  }

  @ViewBuilder
  private func card(_ record: CRMRecord) -> some View {
    if contract.canUpdate {
      cardLink(record)
        .draggable(record.id)
        .contextMenu {
          ForEach(columns.filter { $0.value != column.value }) { destination in
            Button("Move to \(destination.label)") {
              onMove(record.id, board.field, destination.value)
            }
          }
        }
    } else {
      cardLink(record)
    }
  }

  @ViewBuilder
  private func cardLink(_ record: CRMRecord) -> some View {
    if let target = favorites?.target(for: record, in: contract) {
      // The star sits beside the link, not inside it, so tapping it does not
      // open the record.
      HStack(spacing: 6) {
        NavigationLink(value: record) {
          CRMRecordRow(contract: contract, record: record)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        CRMFavoriteToggleButton(target: target, onError: onFavoriteError)
          .padding(.trailing, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(EnvisioningSurface.elevated, in: .rect(cornerRadius: EnvisioningRadius.card))
      .overlay {
        RoundedRectangle(cornerRadius: EnvisioningRadius.card)
          .strokeBorder(.separator, lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    } else {
      NavigationLink(value: record) {
        CRMRecordRow(contract: contract, record: record)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(EnvisioningSurface.elevated, in: .rect(cornerRadius: EnvisioningRadius.card))
          .overlay {
            RoundedRectangle(cornerRadius: EnvisioningRadius.card)
              .strokeBorder(.separator, lineWidth: 1)
          }
          .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
      }
      .buttonStyle(.plain)
    }
  }
}

private struct AlphabeticalSection: Identifiable {
  let title: String
  let records: [CRMRecord]
  var id: String { title }
}

private struct TaskProjectSection: Identifiable {
  let id: String
  let title: String
  let projectId: String?
  let records: [CRMRecord]
}

private struct CRMRecordRow: View {
  let contract: CRMEntityContract
  let record: CRMRecord
  /// Website stats slice from the screen's single breakdown query; only the
  /// generic list passes it (CMS entities with public pages), so every other
  /// call site keeps the default and renders no badge.
  var plausibleStats: PlausibleStats? = nil

  var body: some View {
    HStack(spacing: CRMListRow.iconSpacing) {
      if identity.usesHeroLayout {
        ContentRecordThumbnail(contract: contract, record: record)
      } else if showsAvatar {
        CachedRemoteAvatar(
          url: record.avatarURL,
          name: primaryText,
          fallbackSymbol: contract.icon,
          shape: .resolve(entityID: contract.id)
        )
      } else {
        // Every row carries a leading icon for a consistent left rail; entities
        // with no avatar or hero image fall back to their registry symbol.
        Image(crmSymbol: contract.icon, fallback: "circle")
          .font(.title3)
          .frame(width: 40, height: 40)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(crmSecondaryText)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(primaryText)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
        VStack(alignment: .leading, spacing: CRMListRow.indicatorSpacing) {
          ForEach(subtitleLines, id: \.self) { line in
            Text(line)
              .font(.subheadline)
              .foregroundStyle(crmSecondaryText)
              .lineLimit(1)
          }
          PlausibleStatBadge(stats: plausibleStats)
        }
      }
      if let countdown = eventCountdown {
        Spacer(minLength: 8)
        EventCountdownBadge(countdown: countdown)
      } else if !accessories.isEmpty {
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 4) {
          if let metric = accessories.metric {
            Text(metric)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
              .monospacedDigit()
              .lineLimit(1)
          }
          if let status = accessories.status {
            statusAccessory(status)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
  }

  private var accessories: CRMRowAccessories {
    crmRowAccessories(for: contract, record: record)
  }

  @ViewBuilder
  private func statusAccessory(_ status: CRMRowStatus) -> some View {
    switch status {
    case let .pill(value, type):
      CRMStatusPill(value: value, type: type)
    case let .badge(text, filled):
      CRMOutlineBadge(text: text, filled: filled)
    }
  }

  private var primaryText: String {
    if contract.id == "licenses",
      let organization = record["organization"]?.objectValue?["name"]?.stringValue,
      !organization.isEmpty {
      return organization
    }
    return record.displayName(
      primaryField: contract.primaryField,
      fallback: contract.singularLabel
    )
  }

  /// The subtitle, rendered one indicator per line. A leading country flag
  /// rides on the first line; an empty result collapses the subtitle entirely.
  private var subtitleLines: [String] {
    var lines = detailValues.filter { !$0.isEmpty }
    guard let flag = leadingFlag else { return lines }
    if lines.isEmpty { return [flag] }
    lines[0] = "\(flag) \(lines[0])"
    return lines
  }

  /// Flag emoji for the record's own country. Only organizations and contacts
  /// opt into this; other entities keep their plain subtitle.
  private var leadingFlag: String? {
    guard contract.id == "organizations" || contract.id == "contacts",
      let country = record["country"]?.stringValue, !country.isEmpty
    else { return nil }
    return CountryCatalog.flag(forStoredValue: country)
  }

  private var detailValues: [String] {
    switch contract.id {
    case "events":
      // Weekday + date, then where it's held. The event's image already renders
      // as the row thumbnail, and the countdown shows as a trailing badge.
      let day = eventDate.map { Self.eventDisplayFormatter.string(from: $0) }
      let place = trimmed(record["place"]?.stringValue)
      let location = trimmed(record["location"]?.stringValue)
      return [day, place ?? location].compactMap { $0 }.filter { !$0.isEmpty }
    case "licenses":
      // Amount (ARR) and active-state move to the trailing accessories, so the
      // subtitle keeps just the identifying product/plan/renewal.
      return [
        record["product"]?.stringValue?.capitalized,
        record["plan_type"]?.stringValue?.capitalized,
        record["renewal_date"]?.stringValue.map { "Renews \($0)" },
      ].compactMap { $0 }.filter { !$0.isEmpty }
    case "organizations":
      // Short name is the title; surface the legal name underneath when it
      // exists and actually differs. Otherwise keep the registry secondaries,
      // minus country — which the flag now represents.
      let name = primaryText
      if let legal = record["legal_name"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !legal.isEmpty, legal.caseInsensitiveCompare(name) != .orderedSame {
        return [legal]
      }
      return contract.secondaryFields.filter { $0 != "country" }
        .compactMap { secondaryValue(for: $0) }
        .filter { !$0.isEmpty }
    case "contacts":
      // Show the linked organization's short name (not its legal name) plus the
      // role; the country reads from the flag.
      let organization = record["organization"]?.objectValue?["name"]?.stringValue
      let role = record["company_role"]?.stringValue
      return [organization, role]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    default:
      // Drop fields shown as trailing accessories (status/metric) so they don't
      // repeat in the stacked subtitle.
      let consumed = crmRowAccessoryFields(for: contract)
      return contract.secondaryFields.filter { !consumed.contains($0) }
        .compactMap { secondaryValue(for: $0) }
        .filter { !$0.isEmpty }
    }
  }

  /// Raw stored value for a secondary field, humanized where the code isn't
  /// self-explanatory. Industry values arrive as `ent_<slug>` taxonomy ids and
  /// must render like the detail view (via `crmDisplayValue`), not raw.
  private func secondaryValue(for name: String) -> String? {
    guard let raw = record[name]?.stringValue else { return nil }
    if contract.fields.first(where: { $0.name == name })?.kind == "industry" {
      return CRMFieldContract.industryLabel(for: raw)
    }
    return raw
  }

  private var showsAvatar: Bool {
    identity.showsAvatar || record.avatarURL != nil
  }

  private var identity: CRMEntityIdentity {
    CRMEntityIdentity.resolve(contract)
  }

  private func trimmed(_ value: String?) -> String? {
    guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty
    else { return nil }
    return v
  }

  /// The event's calendar day, parsed from the plain `event_date` (YYYY-MM-DD).
  /// Events only — nil elsewhere, which keeps the date subtitle and countdown
  /// badge off every other entity's rows.
  private var eventDate: Date? {
    guard contract.id == "events",
      let raw = trimmed(record["event_date"]?.stringValue)
    else { return nil }
    return Self.eventDateParser.date(from: String(raw.prefix(10)))
  }

  /// Whole days from today (UTC) to the event. Both ends use UTC so the two
  /// don't drift relative to each other; near-midnight local edge cases are
  /// acceptable for a countdown badge.
  private var eventCountdown: EventCountdown? {
    guard let date = eventDate else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let today = calendar.startOfDay(for: Date())
    let day = calendar.startOfDay(for: date)
    guard let days = calendar.dateComponents([.day], from: today, to: day).day
    else { return nil }
    return EventCountdown(days: days)
  }

  private static let eventDateParser: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  private static let eventDisplayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
    return f
  }()
}

/// Days-until-event, resolved to a short label and whether it's still upcoming.
private struct EventCountdown {
  let days: Int

  var isUpcoming: Bool { days >= 0 }

  var label: String {
    switch days {
    case let d where d > 1: return "\(d) days"
    case 1: return "Tomorrow"
    case 0: return "Today"
    case -1: return "Yesterday"
    default: return "Past"
    }
  }
}

private struct EventCountdownBadge: View {
  let countdown: EventCountdown

  var body: some View {
    Text(countdown.label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(countdown.isUpcoming ? Color.primary : crmSecondaryText)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        (countdown.isUpcoming ? Color.primary : crmSecondaryText).opacity(0.12),
        in: Capsule()
      )
      .fixedSize()
      .accessibilityLabel(
        countdown.days == 0 ? "Today"
          : countdown.days > 0 ? "In \(countdown.days) days"
          : "Past event"
      )
  }
}
