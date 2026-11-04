import CoreKit
import SwiftUI

/// A registry-driven multi-column table for wide screens (macOS / iPad-regular),
/// porting the web CRM's per-entity table configs (`crmTableColumns`). Uses
/// SwiftUI's native `Table`, so on macOS it's an `NSTableView` under the hood —
/// resizable, reorderable, header-click sortable, keyboard-navigable.
///
/// Interaction follows the native table idiom: single click/arrow selects,
/// double-click or Return opens the record (`primaryAction`), right-click shows
/// the same row context menu the list rows carry (`rowMenu`). Sort order is
/// persisted per entity so a table reopens the way you left it.
struct CRMEntityTableView<Menu: View>: View {
  let entityID: String
  let columns: [CRMColumn]
  let records: [CRMRecord]
  @Binding var selection: CRMRecord.ID?
  let onOpen: (CRMRecord) -> Void
  @ViewBuilder let rowMenu: (CRMRecord) -> Menu
  /// A leading "Favorite" column. The list passes it only when the host has
  /// shared favorites in the environment.
  var favoriteAccessory: ((CRMRecord) -> AnyView)? = nil

  @State private var sortOrder: [CRMColumnComparator]

  init(
    entityID: String,
    columns: [CRMColumn],
    records: [CRMRecord],
    selection: Binding<CRMRecord.ID?>,
    onOpen: @escaping (CRMRecord) -> Void,
    @ViewBuilder rowMenu: @escaping (CRMRecord) -> Menu,
    favoriteAccessory: ((CRMRecord) -> AnyView)? = nil
  ) {
    self.entityID = entityID
    self.columns = columns
    self.records = records
    self._selection = selection
    self.onOpen = onOpen
    self.rowMenu = rowMenu
    self.favoriteAccessory = favoriteAccessory
    self._sortOrder = State(initialValue: Self.loadSort(entityID: entityID, columns: columns))
  }

  var body: some View {
    // `TableColumnForEach` is macOS 14.4 / iOS 17.4. `EntityListView` only
    // presents this view when that holds (`tableColumns` is nil otherwise), so
    // the fallback is a formality the type system asks for.
    if #available(macOS 14.4, iOS 17.4, *) {
      Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
        if let favoriteAccessory {
          TableColumn("Favorite") { record in
            favoriteAccessory(record)
              .frame(maxWidth: .infinity, alignment: .center)
          }
          .width(min: 44, ideal: 48)
        }
        TableColumnForEach(columns) { column in
          TableColumn(Text(verbatim: column.header), sortUsing: column.comparator) { record in
            CRMTableCell(content: column.cell(record))
              .frame(maxWidth: .infinity, alignment: column.alignment)
          }
          .width(min: 56, ideal: column.width)
        }
      }
      .contextMenu(forSelectionType: CRMRecord.ID.self) { ids in
        if let record = record(for: ids) {
          rowMenu(record)
        }
      } primaryAction: { ids in
        if let record = record(for: ids) {
          onOpen(record)
        }
      }
      .onChange(of: sortOrder) { _, newValue in
        Self.saveSort(entityID: entityID, newValue)
      }
    } else {
      EmptyView()
    }
  }

  private func record(for ids: Set<CRMRecord.ID>) -> CRMRecord? {
    guard let id = ids.first else { return nil }
    return records.first { $0.id == id }
  }

  // MARK: - Sort persistence

  private static func sortDefaultsKey(_ entityID: String) -> String {
    "crm.table.sort.\(entityID)"
  }

  private static func loadSort(entityID: String, columns: [CRMColumn]) -> [CRMColumnComparator] {
    if let raw = UserDefaults.standard.string(forKey: sortDefaultsKey(entityID)) {
      let parts = raw.split(separator: "|", maxSplits: 1)
      if let keyPart = parts.first, let column = columns.first(where: { $0.id == String(keyPart) }) {
        var comparator = column.comparator
        comparator.order = (parts.count == 2 && parts[1] == "r") ? .reverse : .forward
        return [comparator]
      }
    }
    return crmDefaultSort(for: columns)
  }

  private static func saveSort(entityID: String, _ order: [CRMColumnComparator]) {
    guard let first = order.first else { return }
    let encoded = "\(first.key)|\(first.order == .reverse ? "r" : "f")"
    UserDefaults.standard.set(encoded, forKey: sortDefaultsKey(entityID))
  }
}

/// Renders one `CRMCellContent` value. The single code path for every table cell.
struct CRMTableCell: View {
  let content: CRMCellContent

  var body: some View {
    switch content {
    case .empty:
      Text(verbatim: "—").foregroundStyle(.tertiary)

    case let .text(value, style):
      styledText(value, style)

    case let .pill(value, type):
      CRMStatusPill(value: value, type: type)

    case let .badge(text, filled):
      CRMOutlineBadge(text: text, filled: filled)

    case let .avatar(url, name, subtitle, strikethrough, shape):
      HStack(spacing: 8) {
        CachedRemoteAvatar(url: url, name: name, size: 26, shape: shape)
        VStack(alignment: .leading, spacing: 1) {
          Text(name)
            .font(.body.weight(.medium))
            .strikethrough(strikethrough)
            .foregroundStyle(strikethrough ? .secondary : .primary)
            .lineLimit(1)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(crmSecondaryText)
              .lineLimit(1)
          }
        }
      }

    case let .symbol(symbol, text, style):
      HStack(spacing: 6) {
        Image(crmSymbol: symbol, fallback: "circle")
          .foregroundStyle(crmSecondaryText)
        styledText(text, style)
      }

    case let .flag(flag, text, style):
      HStack(spacing: 6) {
        if let flag { Text(flag) }
        styledText(text, style)
      }

    case let .readiness(score):
      HStack(spacing: 8) {
        Text(verbatim: "\(score)%")
          .font(.body.weight(.semibold))
          .monospacedDigit()
        CRMStatusPill(value: readinessLevel(score), type: .readinessScore)
      }
    }
  }

  @ViewBuilder
  private func styledText(_ value: String, _ style: CRMTextStyle) -> some View {
    Text(value)
      .font(.body.weight(style.weight))
      .strikethrough(style.strikethrough)
      .foregroundStyle(style.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .lineLimit(1)
  }

  private func readinessLevel(_ score: Int) -> String {
    if score >= 75 { return "High" }
    if score >= 50 { return "Mid" }
    return "Low"
  }
}
