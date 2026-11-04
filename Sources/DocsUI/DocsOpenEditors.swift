import Combine
import DocsKit
import Foundation

/// Every document open in an editor, app-wide: one model per document id.
///
/// Docs refuses a save whose `content_hash` is stale, so two editors on one
/// document, each with its own hash, would conflict with each other all day.
/// Every `DocumentEditor` therefore takes its model from here: a second
/// editor on the same document shares the first one's model, its edits and
/// its hash. The model lives while any editor shows it, and flushes when the
/// last one goes.
///
/// It is also the one door for what a host does to a document from outside
/// the editor: a rename or an archive from a list goes through
/// `rename(_:to:client:)` and `archive(_:client:)`, so an open editor saves
/// first and then hears about it. Hosts listen for
/// `titleDidChangeNotification` and `archivedNotification`.
@MainActor
public final class DocsOpenEditors: ObservableObject {
  public static let shared = DocsOpenEditors()

  /// A document's saved title moved: an editor saved a new one, or a rename
  /// went through here. `userInfo["id"]` and `userInfo["title"]` are strings.
  public static let titleDidChangeNotification = Notification.Name("DocsUIDocumentTitleDidChange")
  /// A document was archived through here. `userInfo["id"]` is the document.
  /// Hosts close whatever shows it.
  public static let archivedNotification = Notification.Name("DocsUIDocumentArchived")

  /// Documents whose editor holds edits the server does not have yet.
  @Published public private(set) var unsaved: Set<String> = []

  private var models: [String: DocumentEditorModel] = [:]
  private var holds: [String: Int] = [:]

  private init() {}

  /// The model for a document: the open one, or a new one.
  func model(for documentID: String, client: DocsClient, drafts: DocsDraftStore) -> DocumentEditorModel {
    if let open = models[documentID] { return open }
    let model = DocumentEditorModel(documentID: documentID, client: client, drafts: drafts)
    models[documentID] = model
    return model
  }

  /// An editor started showing the model.
  func retain(_ model: DocumentEditorModel) {
    models[model.documentID] = model
    holds[model.documentID, default: 0] += 1
  }

  /// An editor stopped showing the model. The last one out saves it.
  func release(_ model: DocumentEditorModel) {
    let id = model.documentID
    let count = max(0, (holds[id] ?? 1) - 1)
    holds[id] = count
    Task { @MainActor in
      await model.flush()
      // Shown again while it saved: keep it.
      guard (self.holds[id] ?? 0) == 0, self.models[id] === model else { return }
      self.models[id] = nil
      self.holds[id] = nil
    }
  }

  /// Whether a document is shown by an editor right now.
  public func isOpen(_ documentID: String) -> Bool {
    (holds[documentID] ?? 0) > 0
  }

  /// Save one document's pending edits now. Returns when the save is done.
  public func flush(_ documentID: String) async {
    await models[documentID]?.flush()
  }

  /// Save every open document, within `timeout`. A save that does not land
  /// leaves its draft on disk; the next open restores it.
  public func flushAll(timeout: Duration = .seconds(4)) async {
    let open = Array(models.values)
    guard !open.isEmpty else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in
        await withTaskGroup(of: Void.self) { saves in
          for model in open { saves.addTask { @MainActor in await model.flush() } }
        }
      }
      group.addTask { try? await Task.sleep(for: timeout) }
      await group.next()
      group.cancelAll()
    }
  }

  /// Rename a document. An open editor takes the title and saves it with
  /// its own hash; otherwise the server is told directly.
  public func rename(_ documentID: String, to title: String, client: DocsClient) async throws {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    if let model = models[documentID], model.document != nil {
      model.title = title
      await model.flush()
      if case .failed(let message) = model.saveState { throw DocsOpenEditorsError.saveFailed(message) }
      return
    }
    let updated = try await client.update(id: documentID, DocsUpdateDocument(title: title))
    titleDidChange(documentID, updated.title)
  }

  /// Archive a document. An open editor saves first, then lets go, and
  /// hosts hear `archivedNotification`.
  public func archive(_ documentID: String, client: DocsClient) async throws {
    await models[documentID]?.flush()
    _ = try await client.archive(id: documentID)
    models[documentID]?.archived()
    NotificationCenter.default.post(name: Self.archivedNotification, object: self, userInfo: ["id": documentID])
  }

  // MARK: From the model

  func saveStateChanged(_ documentID: String, unsaved isUnsaved: Bool) {
    if isUnsaved {
      if !unsaved.contains(documentID) { unsaved.insert(documentID) }
    } else if unsaved.contains(documentID) {
      unsaved.remove(documentID)
    }
  }

  func titleDidChange(_ documentID: String, _ title: String) {
    NotificationCenter.default.post(
      name: Self.titleDidChangeNotification, object: self, userInfo: ["id": documentID, "title": title])
  }
}

public enum DocsOpenEditorsError: LocalizedError {
  case saveFailed(String)

  public var errorDescription: String? {
    switch self {
    case .saveFailed(let message): message
    }
  }
}
