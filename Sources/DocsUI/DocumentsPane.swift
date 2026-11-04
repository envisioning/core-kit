import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI

/// Every document about one subject, with a way to start another. Sits
/// beside Fields on a subject page; the host decides where an opened document
/// goes (a hosted column on the Mac, a push on the phone) through `onOpen`.
///
/// "New" creates the document on the server immediately, pre-linked to the
/// subject and filed at `/work/<kind>/<slug>/`, then hands it to `onOpen` — so
/// there is never an unsaved "new document" state to lose, only a draft body.
public struct DocumentsPane: View {
  /// Post this to open the New document prompt from outside the pane — a
  /// menu item, a toolbar, a shortcut the host owns. `object` is the subject
  /// ref (`core:project:<id>`) the request is about, or nil for whichever
  /// pane is showing.
  public static let requestNew = Notification.Name("DocsUI.DocumentsPane.requestNew")

  public let subject: DocsSubject
  /// Where a new document is filed: the subject's slug under its kind.
  public let subjectSlug: String
  public let client: DocsClient
  public let onOpen: (DocsDocumentSummary) -> Void
  public let onToast: (String) -> Void

  @State private var documents: [DocsDocumentSummary] = []
  @State private var loaded = false
  @State private var errorMessage: String?
  @State private var creating = false
  @State private var newTitle = ""
  @State private var newCategory: DocsCategory?
  @State private var categories: [DocsCategoryInfo] = []
  @State private var askingTitle = false
  @State private var renaming: DocsDocumentSummary?
  @State private var renameTitle = ""

  public init(
    subject: DocsSubject,
    subjectSlug: String,
    client: DocsClient,
    onOpen: @escaping (DocsDocumentSummary) -> Void,
    onToast: @escaping (String) -> Void = { _ in }
  ) {
    self.subject = subject
    self.subjectSlug = subjectSlug
    self.client = client
    self.onOpen = onOpen
    self.onToast = onToast
  }

  public var body: some View {
    VStack(spacing: 0) {
      // The action lives in the pane, not a SwiftUI toolbar: hosted under an
      // AppKit window there is no toolbar for `.toolbar` to land in, and a
      // button nobody can see is no button.
      HStack {
        Text(loaded && !documents.isEmpty ? "\(documents.count) document\(documents.count == 1 ? "" : "s")" : "")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Spacer()
        newButton
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      content
    }
    .sheet(isPresented: $askingTitle) {
      NewDocumentSheet(title: $newTitle, category: $newCategory, note: "Filed under this \(subject.kind); move it later if it belongs elsewhere.") {
        Task { await create() }
      }
      .environment(\.docsCategories, categories)
    }
    .environment(\.docsCategories, categories)
    .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Title", text: $renameTitle)
      Button("Rename") {
        guard let document = renaming else { return }
        let title = renameTitle
        Task { await rename(document, to: title) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .task(id: subject.ref) { await load() }
    .refreshable { await load() }
    .onReceive(NotificationCenter.default.publisher(for: Self.requestNew)) { note in
      let ref = note.object as? String
      if ref == nil || ref == subject.ref { askingTitle = true }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let errorMessage {
      EnvisioningRetryState("Couldn’t load documents", message: errorMessage) {
        Task { await load() }
      }
    } else if !loaded {
      EnvisioningLoadingState("Loading documents…")
    } else if documents.isEmpty {
      VStack(spacing: 14) {
        EnvisioningEmptyState(
          "No documents yet", systemImage: "doc.text",
          message: "Proposals, briefs and contracts about this \(subject.kind) live here.")
          .frame(maxHeight: 220)
        Button { askingTitle = true } label: { Label("New document", systemImage: "plus") }
          .buttonStyle(EnvisioningFilledButtonStyle(expands: false))
          .disabled(creating)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      DocumentList(
        documents: documents,
        rowMenu: { document in
          AnyView(DocumentRowMenu(
            document: document, onOpen: onOpen, onToast: onToast,
            onRename: { renameTitle = $0.title; renaming = $0 },
            onArchive: { document in Task { await archive(document) } }))
        },
        onOpen: onOpen)
    }
  }

  private var newButton: some View {
    Button { askingTitle = true } label: { Label("New document", systemImage: "plus") }
      .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 30, expands: false))
      .disabled(creating)
      .keyboardShortcut("n", modifiers: [.command, .shift])
  }

  public func reload() async { await load() }

  private func load() async {
    // Last known first (meet/docs/CACHING.md): the pane paints the subject's
    // last list before Docs answers, when the host keeps one.
    if !loaded, let cached = client.cachedDocuments(.about(subject)) {
      documents = cached
      loaded = true
    }
    if categories.isEmpty, let cached = client.cachedCategories() { categories = cached }
    do {
      documents = try await client.documents(about: subject)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    loaded = true
    // Labels and New's choices. A failure keeps the last list: the rows
    // still read, by readable id.
    if let fresh = try? await client.categories() { categories = fresh }
  }

  private func rename(_ document: DocsDocumentSummary, to title: String) async {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title != document.title else { return }
    do {
      try await DocsOpenEditors.shared.rename(document.id, to: title, client: client)
      await load()
    } catch {
      onToast(error.localizedDescription)
    }
  }

  private func archive(_ document: DocsDocumentSummary) async {
    do {
      try await DocsOpenEditors.shared.archive(document.id, client: client)
      documents.removeAll { $0.id == document.id }
    } catch {
      onToast(error.localizedDescription)
    }
  }

  private func create() async {
    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    creating = true
    defer { creating = false; newTitle = "" }
    do {
      let created = try await client.create(
        DocsCreateDocument(
          title: title,
          folderPath: "/work/\(subject.kind)/\(subjectSlug)",
          category: newCategory,
          subjects: [subject],
          message: "Created from Meet"))
      documents.insert(created.summary, at: 0)
      onOpen(created.summary)
    } catch {
      onToast(error.localizedDescription)
    }
  }
}

/// Title and category, then Create. A sheet rather than an alert so the
/// category picker has somewhere to be.
public struct NewDocumentSheet: View {
  @Binding var title: String
  @Binding var category: DocsCategory?
  let note: String
  let create: () -> Void
  @Environment(\.dismiss) private var dismiss

  public init(title: Binding<String>, category: Binding<DocsCategory?>, note: String, create: @escaping () -> Void) {
    _title = title
    _category = category
    self.note = note
    self.create = create
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New document").font(.headline)
      TextField("Title", text: $title)
        .coreField()
        .onSubmit { if canCreate { submit() } }
      HStack {
        Text("Category").foregroundStyle(.secondary)
        CategoryPicker(category: $category)
      }
      Text(note).font(.footnote).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { title = ""; dismiss() }
          .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 32, expands: false))
          .keyboardShortcut(.cancelAction)
        Button("Create") { submit() }
          .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 32, expands: false))
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(20)
    .frame(minWidth: 380)
  }

  private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

  private func submit() {
    create()
    dismiss()
  }
}

extension ISO8601DateFormatter {
  static let docs: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
