import DocsKit
#if os(macOS)
import AppKit
#endif
import EnvisioningUI
import SwiftUI

/// The one way a document is drawn in a list — the subject's Documents pane,
/// Recent, a folder, a category, search — so a proposal looks the same
/// wherever it is met. The host decides what choosing one means.
public struct DocumentList: View {
  public let documents: [DocsDocumentSummary]
  /// Names for subject chips, by `DocsSubject.ref`. Absent → the kind alone.
  public let subjectNames: [String: String]
  public let selectedID: String?
  public let onOpen: (DocsDocumentSummary) -> Void
  /// What a row offers on secondary click. The host owns the verbs.
  public let rowMenu: ((DocsDocumentSummary) -> AnyView)?
  /// The plain-text payload a row carries when it is dragged, or nil for a
  /// row that does not drag. The host names the token and owns the drop.
  public let dragToken: ((DocsDocumentSummary) -> String?)?
  /// The rows chosen for a bulk act, or nil for a list that opens one row
  /// at a time. With it, a plain click chooses one row and opens it; on the
  /// Mac ⌘-click adds or removes a row and ⇧-click extends from the last
  /// row clicked, without opening (meet#360).
  public let selection: Binding<Set<String>>?
  @State private var anchorID: String?
  @FocusState private var focusedID: String?

  public init(
    documents: [DocsDocumentSummary],
    subjectNames: [String: String] = [:],
    selectedID: String? = nil,
    rowMenu: ((DocsDocumentSummary) -> AnyView)? = nil,
    dragToken: ((DocsDocumentSummary) -> String?)? = nil,
    selection: Binding<Set<String>>? = nil,
    onOpen: @escaping (DocsDocumentSummary) -> Void
  ) {
    self.documents = documents
    self.subjectNames = subjectNames
    self.selectedID = selectedID
    self.rowMenu = rowMenu
    self.dragToken = dragToken
    self.selection = selection
    self.onOpen = onOpen
  }

  public var body: some View {
    List(documents) { document in
      Button { click(document) } label: {
        DocumentRow(
          document: document,
          subjectNames: subjectNames,
          isSelected: isSelected(document),
          isFocused: focusedID == document.id
        )
      }
      .buttonStyle(.plain)
      #if os(macOS)
      // The open/selected card draws the row state itself. Suppress AppKit's
      // second blue focus ring and fold keyboard focus into that same paint.
      .focused($focusedID, equals: document.id)
      .focusEffectDisabled()
      #endif
      // Rows on the ladder (EnvisioningList's trait), so the list reads like
      // every other grouped list in the host: panel rows on the canvas on
      // iOS, clear rows over the window's canvas on the Mac.
      .envisioningListRows()
      #if os(macOS)
      // No vertical inset: an inset is dead space between rows the
      // `Button` never hears. The row carries its own breathing room
      // inside its hit shape, so every point of the column opens something.
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
      // Each Mac row draws its own rounded card, so a hairline between rows
      // is a second idiom on top of the first. Hide it; iOS keeps the
      // ladder's separator between its panel rows.
      .listRowSeparator(.hidden)
      #endif
      .documentRowMenu(rowMenu.map { menu in { menu(document) } })
      .documentRowDrag(dragToken?(document))
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.plain)
    #endif
    .envisioningListSurface()
  }
}

extension DocumentList {
  private func isSelected(_ document: DocsDocumentSummary) -> Bool {
    if let selection, !selection.wrappedValue.isEmpty {
      return selection.wrappedValue.contains(document.id)
    }
    return document.id == selectedID
  }

  private func click(_ document: DocsDocumentSummary) {
    guard let selection else { return onOpen(document) }
    #if os(macOS)
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
      var chosen = selection.wrappedValue
      // The open row counts as chosen: ⌘-click after a plain click makes two.
      if chosen.isEmpty, let selectedID { chosen.insert(selectedID) }
      if chosen.contains(document.id) { chosen.remove(document.id) } else { chosen.insert(document.id) }
      selection.wrappedValue = chosen
      anchorID = document.id
      return
    }
    if flags.contains(.shift), let anchor = anchorID ?? selectedID,
       let from = documents.firstIndex(where: { $0.id == anchor }),
       let to = documents.firstIndex(where: { $0.id == document.id }) {
      selection.wrappedValue = Set(documents[min(from, to)...max(from, to)].map(\.id))
      return
    }
    #endif
    selection.wrappedValue = [document.id]
    anchorID = document.id
    onOpen(document)
  }
}

extension View {
  /// A hold (iOS) or secondary click (Mac) menu only when the host offers
  /// verbs; keep the builder pure because SwiftUI may evaluate it while
  /// updating the list's view graph.
  @ViewBuilder
  fileprivate func documentRowMenu(_ menu: (() -> AnyView)?) -> some View {
    if let menu {
      contextMenu { menu() }
    } else {
      self
    }
  }
}

extension View {
  /// A drag only when the host gave this row a token.
  @ViewBuilder
  fileprivate func documentRowDrag(_ token: String?) -> some View {
    if let token {
      onDrag { NSItemProvider(object: token as NSString) }
    } else {
      self
    }
  }
}

/// The verbs every document list offers on a row, in one place: Open, Copy
/// link, and for a native document Rename and Archive. The host performs
/// Rename and Archive (it owns the list to reload) and hands in the closures;
/// nil hides the verb.
public struct DocumentRowMenu: View {
  public let document: DocsDocumentSummary
  public let onOpen: (DocsDocumentSummary) -> Void
  public let onToast: (String) -> Void
  public let onRename: ((DocsDocumentSummary) -> Void)?
  public let onArchive: ((DocsDocumentSummary) -> Void)?
  /// Where the File submenu files to, and who files (meet#377). Nil hides it.
  public let filing: DocsFilingChoices?
  public let onFile: ((DocsDocumentSummary, DocsFilingAct) -> Void)?

  public init(
    document: DocsDocumentSummary,
    onOpen: @escaping (DocsDocumentSummary) -> Void,
    onToast: @escaping (String) -> Void = { _ in },
    onRename: ((DocsDocumentSummary) -> Void)? = nil,
    onArchive: ((DocsDocumentSummary) -> Void)? = nil,
    filing: DocsFilingChoices? = nil,
    onFile: ((DocsDocumentSummary, DocsFilingAct) -> Void)? = nil
  ) {
    self.document = document
    self.onOpen = onOpen
    self.onToast = onToast
    self.onRename = onRename
    self.onArchive = onArchive
    self.filing = filing
    self.onFile = onFile
  }

  public var body: some View {
    Button { onOpen(document) } label: { Label("Open", systemImage: "doc.text") }
    Button {
      DocsPasteboard.copy(DocsClient.publicLink(path: document.path))
      onToast("Link copied")
    } label: { Label("Copy link", systemImage: "link") }
    if document.editable {
      if let filing, let onFile {
        Divider()
        DocumentFileMenu(documents: [document], choices: filing) { onFile(document, $0) }
      }
      if let onRename {
        Divider()
        Button { onRename(document) } label: { Label("Rename…", systemImage: "pencil") }
      }
      if let onArchive {
        Divider()
        Button(role: .destructive) { onArchive(document) } label: { Label("Archive", systemImage: "archivebox") }
      }
    }
  }
}

struct DocumentRow: View {
  let document: DocsDocumentSummary
  var subjectNames: [String: String] = [:]
  var isSelected = false
  var isFocused = false
  @Environment(\.docsCategories) private var categories

  private var isEmphasized: Bool { isSelected || isFocused }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: document.isLinkSave ? "link" : document.kind == "pdf" ? "doc.richtext" : document.transcript ? "text.quote" : "doc.text")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        Text(document.title).font(.body).lineLimit(1)
        HStack(spacing: 6) {
          if let category = document.category {
            Text(categories.label(for: category)).font(.caption).foregroundStyle(.secondary)
          } else if let link = document.link {
            Text(link.site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        if !document.subjects.isEmpty {
          SubjectChips(subjects: document.subjects, names: subjectNames)
        }
      }
      Spacer(minLength: 0)
      if !document.editable {
        Image(systemName: "lock").font(.footnote).foregroundStyle(.tertiary)
          .help("Mirrored from \(document.sourceSystem); edit it at the source.")
      }
    }
    #if os(macOS)
    .padding(.vertical, 8)
    .padding(.horizontal, 6)
    // The open row is one rung up the ladder with a hairline, the same
    // selected look as the host's sidebar rows. Not the accent: the accent
    // is a fill for a call to action, and a row that is merely open is not
    // one.
    .background(isEmphasized ? EnvisioningSurface.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(EnvisioningSurface.border, lineWidth: isEmphasized ? 1 : 0))
    #endif
    // After the padding, so the click target is the whole row, edge to edge,
    // not the text inside it.
    .contentShape(Rectangle())
  }

  private var subtitle: String {
    var parts: [String] = []
    // Written, then edited when that was another day (meet#385): an import
    // stamps every row with the day it ran, so the edit date alone read as
    // one day of work.
    let written = ISO8601DateFormatter.docs.date(from: document.written)
    let updated = ISO8601DateFormatter.docs.date(from: document.updatedAt)
    if let written {
      parts.append(written.formatted(date: .abbreviated, time: .omitted))
    }
    if let updated, written.map({ !Calendar.current.isDate($0, inSameDayAs: updated) }) ?? true {
      parts.append(String(localized: "edited \(updated.formatted(.relative(presentation: .named)))"))
    }
    if document.version > 1 { parts.append("v\(document.version)") }
    if let who = document.updatedBy?.split(separator: "@").first, who != "core" { parts.append(String(who)) }
    return parts.joined(separator: " · ")
  }
}

/// What a document is about, as small chips. Names come from whoever knows
/// the CRM (the host); without one a chip says the kind.
public struct SubjectChips: View {
  public let subjects: [DocsSubject]
  public let names: [String: String]

  public init(subjects: [DocsSubject], names: [String: String] = [:]) {
    self.subjects = subjects
    self.names = names
  }

  public var body: some View {
    HStack(spacing: 4) {
      ForEach(subjects, id: \.ref) { subject in
        Text(names[subject.ref] ?? subject.kind.capitalized)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.14), in: Capsule())
          .lineLimit(1)
      }
    }
  }
}

/// The workspace's categories, for New and for the editor's title row, plus
/// "No category". `choices` defaults to `\.docsCategories`. Drawn as the
/// category's name and a chevron that open a menu, never a bordered control.
public struct CategoryPicker: View {
  @Binding public var category: DocsCategory?
  public let choices: [DocsCategoryInfo]?
  /// What the label reads with no category.
  public let emptyLabel: LocalizedStringKey
  @Environment(\.docsCategories) private var categories

  public init(category: Binding<DocsCategory?>, choices: [DocsCategoryInfo]? = nil, emptyLabel: LocalizedStringKey = "No category") {
    _category = category
    self.choices = choices
    self.emptyLabel = emptyLabel
  }

  public var body: some View {
    let listed = choices ?? categories
    DocsMenuPicker(selection: $category, options: options(listed)) {
      category.map { Text(listed.label(for: $0)) } ?? Text(emptyLabel)
    }
  }

  private func options(_ listed: [DocsCategoryInfo]) -> [DocsMenuPicker<DocsCategory?, Text>.Option] {
    var options: [DocsMenuPicker<DocsCategory?, Text>.Option] = [.init(value: nil, label: "No category")]
    options += listed.map { .init(value: $0.id, label: $0.label) }
    // A category this list does not hold yet (deleted, or a stale list)
    // still shows what the document says rather than a blank picker.
    if let category, !listed.contains(where: { $0.id == category }) {
      options.append(.init(value: category, label: category.fallbackLabel))
    }
    return options
  }
}

/// A choice of one, drawn as its current value and a chevron that open a
/// menu with a check on the chosen row. The house stand-in for a system
/// `Picker`, which draws a bordered pop-up button.
public struct DocsMenuPicker<Value: Hashable, Label: View>: View {
  public struct Option: Identifiable {
    public let value: Value
    public let label: String
    public var id: String { "\(label)#\(String(describing: value))" }

    public init(value: Value, label: String) {
      self.value = value
      self.label = label
    }
  }

  @Binding var selection: Value
  let options: [Option]
  let label: () -> Label

  public init(selection: Binding<Value>, options: [Option], @ViewBuilder label: @escaping () -> Label) {
    _selection = selection
    self.options = options
    self.label = label
  }

  public var body: some View {
    Menu {
      ForEach(options) { option in
        Button {
          selection = option.value
        } label: {
          if option.value == selection {
            SwiftUI.Label(option.label, systemImage: "checkmark")
          } else {
            Text(option.label)
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        label()
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .foregroundStyle(EnvisioningSurface.secondaryText)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

extension EnvironmentValues {
  /// The workspace's categories in rail order (`DocsClient.categories()`):
  /// what a row's category label and a picker's choices come from. The host
  /// sets it where it has the list; empty shows readable ids.
  public var docsCategories: [DocsCategoryInfo] {
    get { self[DocsCategoriesKey.self] }
    set { self[DocsCategoriesKey.self] = newValue }
  }
}

private struct DocsCategoriesKey: EnvironmentKey {
  static let defaultValue: [DocsCategoryInfo] = []
}
