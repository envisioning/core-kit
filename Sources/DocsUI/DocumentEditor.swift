import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI

/// One document: read first, rendered, with Edit for the markdown — the
/// whole authoring surface, on purpose: what people at Envisioning write is
/// markdown, and a rich editor would only get in the way of the vault
/// round-trip.
///
/// Saving is nobody's job. Every edit lands in the draft store at once and on
/// the server after a short quiet period, carrying the hash that was read. If
/// the server says the body moved, both versions are shown and the person
/// chooses; nothing is ever overwritten by accident.
public struct DocumentEditor: View {
  @StateObject private var model: DocumentEditorModel
  /// Reading is the default; Edit is a mode, the way the web has it.
  @State private var editing = false
  @State private var sharing = false
  @State private var signing = false
  /// The access log, for "Opened by". Empty until read, and when unreadable.
  @State private var accessEvents: [DocsAccessEvent] = []
  @FocusState private var bodyFocused: Bool
  /// The reader's top block, by its first source line.
  @State private var readerTopLine: Int?
  /// Where the source opens on Edit.
  @State private var editStartLine = 0
  #if os(macOS)
  @State private var editorController = MarkdownEditorController()
  #endif
  @Environment(\.openURL) private var openURL

  /// Who knows the CRM, for the subject chips. Nil hides the chips' controls.
  private let directory: SubjectDirectory?

  /// Read a link save's page again, through the host's page reader (Meet's
  /// Worker). Nil hides Read again.
  private let linkRefetch: ((String) async throws -> DocsDocumentDetail)?

  /// A short confirmation the host shows its own way ("Link copied").
  /// Errors never go here: they show red, with Copy, where they happened.
  private let onToast: (String) -> Void

  /// Open another document by id and title: a wikilink's target, through
  /// the host's own routing. Nil leaves wikilinks as words.
  private let onOpenDocument: ((_ id: String, _ title: String) -> Void)?

  @State private var barWidth: CGFloat = 0

  public init(
    documentID: String,
    client: DocsClient,
    directory: SubjectDirectory? = nil,
    drafts: DocsDraftStore = DocsDraftStore(),
    linkRefetch: ((String) async throws -> DocsDocumentDetail)? = nil,
    onToast: @escaping (String) -> Void = { _ in },
    onOpenDocument: ((_ id: String, _ title: String) -> Void)? = nil
  ) {
    self.directory = directory
    self.linkRefetch = linkRefetch
    self.onToast = onToast
    self.onOpenDocument = onOpenDocument
    // One model per document, app-wide (`DocsOpenEditors`): a second editor
    // on the same document shares this one's edits and hash.
    _model = StateObject(
      wrappedValue: DocsOpenEditors.shared.model(for: documentID, client: client, drafts: drafts))
  }

  public var body: some View {
    Group {
      if let conflict = model.conflict {
        ConflictView(
          mine: model.conflictMine ?? DocsDraftFields(title: model.title, body: model.body, category: model.category),
          theirs: conflict, categories: model.categories
        ) { choice in
          Task { await model.resolve(choice) }
        }
      } else if model.isArchived {
        EnvisioningEmptyState("Archived", systemImage: "archivebox")
      } else if let document = model.document {
        editor(document)
      } else if let errorMessage = model.loadError {
        EnvisioningRetryState("Couldn’t open the document", message: errorMessage) {
          Task { await model.load() }
        }
      } else {
        EnvisioningLoadingState("Opening…")
      }
    }
    .task(id: model.documentID) { await model.load() }
    .onAppear { DocsOpenEditors.shared.retain(model) }
    // The last editor out saves (`DocsOpenEditors.release`).
    .onDisappear { DocsOpenEditors.shared.release(model) }
  }

  /// The page reads first, the way the web does (meet#175 decision 5):
  /// Share, Edit and ⋯ in one bar; the title, then one quiet meta line;
  /// the rendered body at reading width. Edit swaps the body for the
  /// markdown, at the same width, and Done (or Escape) goes back.
  @ViewBuilder
  private func editor(_ document: DocsDocumentDetail) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Controls sit in the view, not a `.toolbar`: hosted in a column of an
      // AppKit window there is no toolbar for them to land in.
      bar(document)
      Divider()
      if editing {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
          header(document)
            .padding(.bottom, 12)
            .frame(maxWidth: Self.readingWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .frame(maxWidth: .infinity)
          // The source, styled as it is typed, in the reader's column.
          MarkdownEditor(
            text: $model.body, readingWidth: Self.readingWidth, controller: editorController,
            startLine: editStartLine,
            onDone: { finishEditing() },
            onSave: { Task { await model.flush() } },
            onImage: { data, caption, placeholder in
              model.upload(image: data, caption: caption, placeholder: placeholder) { placeholder, text in
                editorController.replace(placeholder, with: text)
              }
            },
            linkTitles: { model.linkTitles })
          .task(id: document.id) { await model.loadLinkTitles() }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
          header(document)
            .padding(.bottom, 12)
          TextEditor(text: $model.body)
            .font(.body)
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .focused($bodyFocused)
            .onKeyPress(.escape) {
              finishEditing()
              return .handled
            }
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
        #endif
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            header(document)
            MarkdownText(markdown: model.body, anchored: true)
              .textSelection(.enabled)
              .environment(\.markdownDocumentLinks, documentLinks(document))
              .environment(\.openURL, OpenURLAction { url in
                guard let target = DocsWikilinkURL.parse(url) else { return .systemAction }
                onOpenDocument?(target.id, target.title)
                return .handled
              })
            // Comments read under the text (meet#175 slice 3). A comment is
            // made on the rendered page, never beside the markdown.
            Divider()
            CommentsPane(documentID: document.id, client: model.client)
          }
          .frame(maxWidth: Self.readingWidth, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity)
        }
        // The block on top, by its first source line: Edit opens the source
        // there, and Done comes back to it.
        .scrollPosition(id: $readerTopLine, anchor: .top)
      }
    }
    .onAppear {
      // A new, empty document has nothing to read: it opens to write.
      if document.editable, model.body.isEmpty { startEditing() }
    }
    .onChange(of: model.body) { _, _ in model.edited() }
    .onChange(of: model.title) { _, _ in model.edited() }
    .onChange(of: model.category) { _, _ in model.edited() }
    .sheet(isPresented: $sharing) {
      ShareSheet(
        documentID: document.id, documentTitle: model.title, visibility: document.visibility, client: model.client,
        onToast: onToast, onVisibilityChange: { model.apply(shared: $0) })
    }
    .sheet(isPresented: $signing) {
      SignatureSheet(documentID: document.id, documentTitle: model.title, client: model.client)
    }
  }

  /// Text this wide reads; wider only makes the eye travel.
  static let readingWidth: CGFloat = 720

  private func startEditing() {
    editStartLine = readerTopLine ?? 0
    editing = true
    bodyFocused = true
  }

  private func finishEditing() {
    #if os(macOS)
    // Back to the block that holds the line the editor had on top.
    let line = editorController.topLine
    readerTopLine = line > 0 ? MarkdownText.blockLines(model.body).last { $0 <= line } : nil
    #endif
    editing = false
    Task { await model.flush() }
  }

  /// What the reader draws through the host: images the document holds, and
  /// wikilinks resolved by Docs (`document.links`, the same resolution the
  /// graph draws its edges from).
  private func documentLinks(_ document: DocsDocumentDetail) -> MarkdownDocumentLinks {
    let client = model.client
    let documentID = document.id
    let links = document.links
    return MarkdownDocumentLinks(
      image: { id, alt in
        AnyView(DocsBodyImage(documentID: documentID, imageID: id, alt: alt, client: client))
      },
      wikilink: onOpenDocument == nil ? nil : { target in
        let wanted = DocsWikilinkURL.normalized(target)
        guard let id = links.first(where: { DocsWikilinkURL.normalized($0.target) == wanted && $0.toId != nil })?.toId
        else { return nil }
        return DocsWikilinkURL.make(id: id, title: target)
      })
  }

  /// Wide enough for Outline beside Share and Edit; narrower, it moves into ⋯.
  private var barIsWide: Bool { barWidth >= 440 }

  /// Save state on the left, then Outline, Share, Edit or Done, and ⋯ — the
  /// web's bar.
  private func bar(_ document: DocsDocumentDetail) -> some View {
    HStack(spacing: 8) {
      saveStatus(document)
      Spacer(minLength: 8)
      if barIsWide, !outline.isEmpty {
        Menu {
          outlineItems
        } label: {
          Image(systemName: "list.bullet.indent")
            .frame(width: 28, height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Outline")
      }
      Button("Share") { sharing = true }
        .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 28, expands: false))
      if document.editable {
        if editing {
          Button("Done") { finishEditing() }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 28, expands: false))
            .keyboardShortcut("e", modifiers: .command)
            .help("Done (⌘E or Esc)")
        } else {
          Button("Edit") { startEditing() }
            .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 28, expands: false))
            .keyboardShortcut("e", modifiers: .command)
            .help("Edit (⌘E)")
        }
      } else if let source = document.sourceUrl, let url = URL(string: source) {
        Button("Open in \(document.sourceSystem.capitalized)") { openURL(url) }
          .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 28, expands: false))
      }
      moreMenu(document)
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { barWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { _, width in barWidth = width }
      }
    }
  }

  /// The document's headings, outside code.
  private var outline: [DocsOutline.Heading] { DocsOutline.headings(model.body) }

  /// One row per heading, indented by level; a click scrolls to it.
  @ViewBuilder
  private var outlineItems: some View {
    ForEach(outline) { heading in
      Button(String(repeating: "    ", count: max(0, heading.level - 1)) + heading.title) {
        reveal(line: heading.line)
      }
    }
  }

  private func reveal(line: Int) {
    #if os(macOS)
    if editing {
      editorController.scroll(toLine: line)
      return
    }
    #endif
    readerTopLine = line
  }

  /// What is not used every visit: signature, the browser, the path, and
  /// the outline when the bar is narrow.
  private func moreMenu(_ document: DocsDocumentDetail) -> some View {
    Menu {
      if !barIsWide, !outline.isEmpty {
        Section("Outline") { outlineItems }
      }
      Section(document.path) {
        if !document.isLinkSave, document.editable {
          Button { signing = true } label: { Label("Send for Signature…", systemImage: "signature") }
        }
        if let url = URL(string: DocsClient.publicLink(path: document.path)) {
          Link(destination: url) { Label("Open in Browser", systemImage: "safari") }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 28, height: 28)
        .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More")
  }

  /// Quiet while all is well: nothing in reading, "Saved" while writing,
  /// "Saving…" while an edit waits for the server. Only a failure is red,
  /// with Retry and Copy, in either mode.
  @ViewBuilder
  private func saveStatus(_ document: DocsDocumentDetail) -> some View {
    Group {
      if case .failed(let message) = model.saveState {
        EnvisioningErrorNotice(message, lineLimit: 1) { Task { await model.flush() } }
      } else if let imageError = model.imageError {
        EnvisioningErrorNotice(imageError, lineLimit: 1)
      } else if model.restoredDraft {
        Text("Restored unsaved changes.").foregroundStyle(EnvisioningSurface.secondaryText)
      } else if model.saveState != .clean {
        Text(editing ? "Saving… · \(wordCount)" : "Saving…").foregroundStyle(EnvisioningSurface.secondaryText)
      } else if editing {
        Text("Saved · \(wordCount)").foregroundStyle(EnvisioningSurface.secondaryText)
      }
    }
    .font(.footnote)
    .lineLimit(1)
  }

  /// "1 word", "312 words": what is written, markup aside.
  private var wordCount: String {
    let count = DocsOutline.wordCount(model.body)
    return count == 1 ? "1 word" : "\(count.formatted()) words"
  }

  /// The title, one meta line (category · who · when), then what a save or
  /// a subject adds. The same in both modes, so Edit moves nothing.
  @ViewBuilder
  private func header(_ document: DocsDocumentDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if editing {
        TextField("Title", text: $model.title)
          .font(.title.weight(.semibold))
          .textFieldStyle(.plain)
          .onSubmit {
            #if os(macOS)
            editorController.focus()
            #else
            bodyFocused = true
            #endif
          }
      } else {
        Text(model.title.isEmpty ? "Untitled" : model.title)
          .font(.title.weight(.semibold))
          .foregroundStyle(model.title.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
      }
      meta(document)

      if document.isLinkSave {
        LinkHeader(document: document, client: model.client, refetch: linkRefetch) { model.apply(shared: $0) }
        DocumentImagesStrip(
          documentID: document.id, images: document.images ?? [], client: model.client, editable: document.editable
        ) {
          // Images are not part of the edit cycle (no hash, no draft): only
          // the detail is replaced, the way the Share sheet does it.
          Task { if let updated = try? await model.client.document(id: document.id) { model.apply(shared: updated) } }
        }
      }

      if let directory {
        SubjectEditor(documentID: document.id, client: model.client, directory: directory, subjects: $model.subjects)
      } else if !model.subjects.isEmpty {
        SubjectChips(subjects: model.subjects)
      }
    }
  }

  /// "Research · rosa@example.com · 10:35". A mirrored body says where it
  /// comes from and when it synced; the bar has the way there.
  private func meta(_ document: DocsDocumentDetail) -> some View {
    let pickable = editing && document.editable && !document.isLinkSave
    let category = model.category.map { model.categories.label(for: $0) }
    let source = document.editable ? nil : document.sourceSystem.capitalized
    let by = document.updatedBy.flatMap { $0.isEmpty ? nil : $0 }
    let when = Self.updatedLabel(document.updatedAt).map { document.editable ? $0 : "Synced \($0)" }
    let leads = pickable || category != nil
    return HStack(spacing: 6) {
      if pickable {
        categoryMenu
      } else if let category {
        Text(category)
      }
      if let source {
        if leads { Text("·") }
        Image(systemName: "lock").imageScale(.small)
        Text(source)
      }
      if let by {
        if leads || source != nil { Text("·") }
        Text(by).lineLimit(1).truncationMode(.middle)
      }
      if let when {
        if leads || source != nil || by != nil { Text("·") }
        Text(when)
      }
      if let opened = DocsGuestViews(accessEvents) {
        if leads || source != nil || by != nil || when != nil { Text("·") }
        openedBy(opened)
      }
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    // Guests who opened it (envisioning/starlings#1045). Only a writer reads
    // the log; a failed read leaves the line out, and Share says why.
    .task(id: document.id) {
      guard document.editable, !document.isLinkSave else { return }
      accessEvents = (try? await model.client.accessEvents(for: document.id)) ?? []
    }
  }

  /// "Opened by 3 · Kapil Raghuraman (EY), 2 hours ago": opens Share, where
  /// Activity lists every view and click.
  private func openedBy(_ opened: DocsGuestViews) -> some View {
    let head = Text("Opened by \(opened.people) · \(opened.latest.who)")
    let label = opened.latest.date.map { head + Text(", ") + Text($0, format: .relative(presentation: .named)) } ?? head
    return Button { sharing = true } label: {
      label
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.primary)
        .underline(color: Color.secondary.opacity(0.5))
    }
    .buttonStyle(.borderless)
    .help("Show activity")
  }

  /// The category, as text that opens a menu — never a bordered control.
  private var categoryMenu: some View {
    CategoryPicker(category: $model.category, choices: model.categories, emptyLabel: "Add category")
      .help("Category")
  }

  /// "14:02" today, "12 Sep" this year, "12 Sep 2025" otherwise.
  static func updatedLabel(_ iso: String, now: Date = Date()) -> String? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
  }
}

// MARK: - Model

/// The three fields an edit changes, side by side for a conflict.
public struct DocsDraftFields: Equatable, Sendable {
  public var title: String
  public var body: String
  public var category: DocsCategory?
}

@MainActor
public final class DocumentEditorModel: ObservableObject {
  public enum SaveState: Equatable {
    case clean
    case dirty
    case saving
    case failed(String)
  }

  public enum ConflictChoice {
    /// Take the server's version. A title or category only I changed, on a
    /// version where they left it alone, comes along and saves on theirs.
    case takeTheirs
    /// Write my edits over theirs, deliberately, with their hash.
    case keepMine
  }

  public let documentID: String
  let client: DocsClient
  private let drafts: DocsDraftStore

  @Published public private(set) var document: DocsDocumentDetail?
  @Published public var title = ""
  @Published public var body = ""
  @Published public var category: DocsCategory?
  /// The workspace's categories in rail order: the picker's choices.
  @Published public private(set) var categories: [DocsCategoryInfo] = []
  @Published public var subjects: [DocsSubject] = []
  @Published public private(set) var version = 0
  @Published public private(set) var saveState: SaveState = .clean {
    didSet { DocsOpenEditors.shared.saveStateChanged(documentID, unsaved: saveState != .clean) }
  }
  @Published public private(set) var loadError: String?
  /// The server's current detail when a save was refused for `hash_mismatch`.
  @Published public private(set) var conflict: DocsDocumentDetail?
  /// My side of that conflict, as it was when the server refused it.
  @Published public private(set) var conflictMine: DocsDraftFields?
  /// A draft from an earlier session replaced the server's text on open.
  @Published public private(set) var restoredDraft = false
  /// Archived from outside the editor; hosts close it.
  @Published public private(set) var isArchived = false
  /// The last image paste or drop that did not upload.
  @Published public private(set) var imageError: String?
  /// Document titles for `[[` completion, most recent first.
  @Published public private(set) var linkTitles: [String] = []
  /// Uploads on the wire. Autosave waits for them, so a placeholder is not
  /// what the server keeps.
  private var uploads = 0

  private var contentHash = ""
  private var savedTitle = ""
  private var savedBody = ""
  private var savedCategory: DocsCategory?
  private var autosave: Task<Void, Never>?
  private var inFlight: Task<Void, Never>?
  private var restoredNotice: Task<Void, Never>?
  /// Quiet time before an edit goes to the server. Drafts hit disk at once.
  public var autosaveDelay: Duration = .milliseconds(1500)

  public init(documentID: String, client: DocsClient, drafts: DocsDraftStore) {
    self.documentID = documentID
    self.client = client
    self.drafts = drafts
  }

  public func load() async {
    if categories.isEmpty, let cached = client.cachedCategories() { categories = cached }
    // A second editor on a model that holds edits must not read over them.
    if document != nil, saveState != .clean || conflict != nil {
      if let fresh = try? await client.categories() { categories = fresh }
      return
    }
    do {
      let detail = try await client.document(id: documentID)
      apply(detail)
      restoreDraft(over: detail)
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
    // A failure keeps the last list; the picker still shows this document's own.
    if let fresh = try? await client.categories() { categories = fresh }
  }

  /// A draft that survived a crash outranks the server's text — that is the
  /// whole reason it exists — but only when it differs. It saves against
  /// the hash it was written on, so a save someone made since shows as a
  /// conflict rather than being overwritten.
  private func restoreDraft(over detail: DocsDocumentDetail) {
    guard let draft = drafts.readDraft(documentID) else { return }
    let draftTitle = draft.title ?? detail.title
    let draftCategory = draft.hasCategory ? draft.category : detail.category
    guard draft.body != (detail.bodyMd ?? "") || draftTitle != detail.title || draftCategory != detail.category else {
      drafts.clear(documentID)
      return
    }
    if let base = draft.baseHash { contentHash = base }
    title = draftTitle
    body = draft.body
    category = draftCategory
    saveState = .dirty
    restoredDraft = true
    restoredNotice?.cancel()
    restoredNotice = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled else { return }
      self?.restoredDraft = false
    }
    schedule()
  }

  func edited() {
    guard document != nil, conflict == nil, !isArchived else { return }
    guard title != savedTitle || body != savedBody || category != savedCategory else {
      if saveState == .dirty { saveState = .clean }
      return
    }
    writeDraft()
    if saveState != .saving { saveState = .dirty }
    schedule()
  }

  private func writeDraft() {
    drafts.write(
      documentID,
      DocsDraft(baseHash: contentHash, title: title, body: body, category: category, hasCategory: true))
  }

  /// The Share sheet flipped the www switch. Visibility is not part of the
  /// edit cycle (no hash, no draft), so only the detail is replaced.
  func apply(shared updated: DocsDocumentDetail) {
    guard updated.id == documentID else { return }
    document = updated
  }

  /// Save now, if there is anything to save. Called when the last editor
  /// goes, on Done, on Retry, before a quit and before a hand-off.
  public func flush() async {
    autosave?.cancel()
    await save()
  }

  /// Archived through `DocsOpenEditors`: nothing more to save.
  func archived() {
    autosave?.cancel()
    drafts.clear(documentID)
    saveState = .clean
    isArchived = true
  }

  public func resolve(_ choice: ConflictChoice) async {
    guard let theirs = conflict else { return }
    let mine = conflictMine ?? DocsDraftFields(title: title, body: body, category: category)
    let baseTitle = savedTitle
    let baseCategory = savedCategory
    switch choice {
    case .takeTheirs:
      apply(theirs)
      drafts.clear(documentID)
      conflict = nil
      conflictMine = nil
      // A title or category only I changed is not part of the clash: keep it
      // and save it on their version.
      let myTitle = mine.title.trimmingCharacters(in: .whitespacesAndNewlines)
      if myTitle != baseTitle, theirs.title == baseTitle { title = myTitle }
      if mine.category != baseCategory, theirs.category == baseCategory { category = mine.category }
      edited()
    case .keepMine:
      contentHash = theirs.contentHash
      conflict = nil
      conflictMine = nil
      await save()
    }
  }

  private func schedule() {
    autosave?.cancel()
    autosave = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: autosaveDelay)
      guard !Task.isCancelled else { return }
      if uploads > 0 {
        schedule()
        return
      }
      await save()
    }
  }

  /// The workspace's recent titles, for `[[` completion: the cached list at
  /// once, then a fresh one.
  func loadLinkTitles() async {
    let read = DocsListRead.recent(limit: 200)
    if linkTitles.isEmpty, let cached = client.cachedDocuments(read) { linkTitles = Self.titles(cached) }
    if let fresh = try? await client.documents(read) { linkTitles = Self.titles(fresh) }
  }

  private static func titles(_ documents: [DocsDocumentSummary]) -> [String] {
    var seen = Set<String>()
    return documents.map(\.title).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  /// Upload a pasted or dropped image and put `![caption](docs-image:<id>)`
  /// where its placeholder stands. `replace` swaps the placeholder in the
  /// open text view (one undo step, the caret stays); when the editor has
  /// closed, the body string is changed instead. A failure takes the
  /// placeholder out and says why.
  func upload(image data: Data, caption: String, placeholder: String, replace: @escaping (String, String) -> Bool) {
    guard let document else { return }
    uploads += 1
    imageError = nil
    Task { [weak self] in
      guard let self else { return }
      let text: String
      do {
        let prepared = try DocsImagePrep.prepare(data)
        let image = try await client.uploadImage(
          documentID: document.id, data: prepared.data, contentType: prepared.contentType, caption: caption)
        text = "![\(caption)](\(MarkdownDocumentLinks.imageScheme):\(image.id))"
      } catch {
        imageError = error.localizedDescription
        text = ""
      }
      uploads -= 1
      if !replace(placeholder, text) {
        body = body.replacingOccurrences(of: text.isEmpty ? placeholder + "\n" : placeholder, with: text)
        body = body.replacingOccurrences(of: placeholder, with: text)
      }
    }
  }

  /// One save on the wire at a time: a second one would carry the same
  /// hash and come back as a conflict with itself. A save asked for while
  /// one runs waits for it, then sends what is left.
  private func save() async {
    while let running = inFlight { await running.value }
    let task = Task<Void, Never> { @MainActor [weak self] in
      guard let self else { return }
      await self.send()
    }
    inFlight = task
    await task.value
    if inFlight == task { inFlight = nil }
  }

  private func send() async {
    guard let document, document.editable, conflict == nil, !isArchived else { return }
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = body
    let category = category
    guard title != savedTitle || body != savedBody || category != savedCategory else {
      saveState = .clean
      return
    }
    saveState = .saving
    do {
      let updated = try await client.update(
        id: documentID,
        DocsUpdateDocument(
          title: title != savedTitle ? title : nil,
          bodyMd: body != savedBody ? body : nil,
          category: category != savedCategory ? .some(category) : nil,
          ifContentHash: contentHash))
      let titleMoved = updated.title != savedTitle
      contentHash = updated.contentHash
      version = updated.version
      savedTitle = title
      savedBody = body
      savedCategory = category
      self.document = updated
      if titleMoved { DocsOpenEditors.shared.titleDidChange(documentID, updated.title) }
      // Edits that landed while the request was in flight go on the next tick.
      let pending = self.title.trimmingCharacters(in: .whitespacesAndNewlines) != savedTitle
        || self.body != savedBody || self.category != savedCategory
      if pending {
        // The draft now stands on the hash just saved.
        writeDraft()
        saveState = .dirty
        schedule()
      } else {
        drafts.clear(documentID)
        saveState = .clean
      }
    } catch DocsClientError.hashMismatch {
      if let theirs = try? await client.document(id: documentID) {
        conflictMine = DocsDraftFields(title: self.title, body: self.body, category: self.category)
        conflict = theirs
        saveState = .dirty
      } else {
        saveState = .failed("This document changed elsewhere; couldn’t fetch the latest.")
      }
    } catch {
      saveState = .failed(error.localizedDescription)
    }
  }

  private func apply(_ detail: DocsDocumentDetail) {
    document = detail
    title = detail.title
    body = detail.bodyMd ?? ""
    category = detail.category
    subjects = detail.subjects
    version = detail.version
    contentHash = detail.contentHash
    savedTitle = detail.title
    savedBody = detail.bodyMd ?? ""
    savedCategory = detail.category
    saveState = .clean
  }
}

// MARK: - Conflict

/// The server said the document moved. Both versions are shown whole —
/// title, category and body — and the person picks.
struct ConflictView: View {
  let mine: DocsDraftFields
  let theirs: DocsDocumentDetail
  let categories: [DocsCategoryInfo]
  let choose: (DocumentEditorModel.ConflictChoice) -> Void
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Label("Changed elsewhere", systemImage: "arrow.triangle.branch").font(.headline)
        Text("\(theirs.updatedBy ?? "Someone") saved version \(theirs.version) while you were editing. Pick the version to keep.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16).padding(.top, 14)

      HStack(spacing: 0) {
        column(
          "Mine", fields: mine,
          action: AnyView(
            Button(copied ? "Copied" : "Copy") {
              EnvisioningPasteboard.copy(Self.plain(mine))
              copied = true
            }
            .buttonStyle(.borderless)
            .font(.caption)))
        Divider()
        column(
          "Theirs · v\(theirs.version)",
          fields: DocsDraftFields(title: theirs.title, body: theirs.bodyMd ?? "", category: theirs.category),
          action: nil)
      }

      Divider()
      HStack {
        Spacer()
        Button("Use theirs") { choose(.takeTheirs) }
          .buttonStyle(EnvisioningBorderedButtonStyle(expands: false))
        Button("Keep mine") { choose(.keepMine) }
          .buttonStyle(EnvisioningFilledButtonStyle(expands: false))
      }
      .padding(.horizontal, 16).padding(.bottom, 12)
    }
  }

  /// Mine as one block of text, for the clipboard: the title as a heading.
  static func plain(_ fields: DocsDraftFields) -> String {
    let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? fields.body : "# \(title)\n\n\(fields.body)"
  }

  private func column(_ heading: String, fields: DocsDraftFields, action: AnyView?) -> some View {
    let differs = (title: fields.title != (fields == mine ? theirs.title : mine.title),
                   category: fields.category != (fields == mine ? theirs.category : mine.category))
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if let action { action }
      }
      .padding(.horizontal, 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(fields.title.isEmpty ? "Untitled" : fields.title)
          .font(.headline)
          .foregroundStyle(differs.title ? .primary : .secondary)
        Text(fields.category.map { categories.label(for: $0) } ?? "No category")
          .font(.caption)
          .foregroundStyle(differs.category ? EnvisioningSurface.primaryText : EnvisioningSurface.secondaryText)
      }
      .textSelection(.enabled)
      .padding(.horizontal, 16)
      ScrollView {
        Text(fields.body).font(.body.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity)
  }
}
