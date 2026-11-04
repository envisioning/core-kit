import Foundation

/// Unsaved editor state, kept on disk per document so a crash or a force-quit
/// does not eat a proposal. The outbox idea from Meet's transcripts, at
/// document scale: write on every keystroke that misses the autosave window,
/// clear the moment the server acknowledges the same bytes.
///
/// A draft keeps the title, the body and the category, and the content hash
/// the edits were made on (`baseHash`). Restoring saves against that hash, so
/// a save someone else made in between surfaces as a conflict instead of
/// being overwritten.
///
/// Drafts are keyed by document id, or by a caller-chosen key for a document
/// that does not exist yet (`new:<subject-ref>`).
public struct DocsDraftStore: Sendable {
  private let directory: URL

  public init(directory: URL? = nil) {
    let base = directory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "DocsKit/drafts", directoryHint: .isDirectory)
    self.directory = base
  }

  /// The draft's body, from either format.
  public func read(_ key: String) -> String? {
    readDraft(key)?.body
  }

  /// The whole draft. A draft written before drafts kept more than the body
  /// comes back with only `body` set.
  public func readDraft(_ key: String) -> DocsDraft? {
    if let data = try? Data(contentsOf: url(for: key, ext: "json")),
      let draft = try? JSONDecoder().decode(DocsDraft.self, from: data)
    {
      return draft
    }
    guard let data = try? Data(contentsOf: url(for: key, ext: "md")) else { return nil }
    return DocsDraft(body: String(decoding: data, as: UTF8.self))
  }

  public func write(_ key: String, body: String) {
    write(key, DocsDraft(body: body))
  }

  public func write(_ key: String, _ draft: DocsDraft) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(draft) else { return }
    try? data.write(to: url(for: key, ext: "json"), options: .atomic)
    // One format on disk per key: the old body-only file would outlive this one.
    try? FileManager.default.removeItem(at: url(for: key, ext: "md"))
  }

  public func clear(_ key: String) {
    try? FileManager.default.removeItem(at: url(for: key, ext: "json"))
    try? FileManager.default.removeItem(at: url(for: key, ext: "md"))
  }

  private func url(for key: String, ext: String) -> URL {
    let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
    return directory.appending(path: String(safe) + "." + ext)
  }
}

/// What an editor had not saved yet. `title` is nil in a draft from before
/// it was kept; `hasCategory` tells "no category" apart from "not kept".
public struct DocsDraft: Codable, Equatable, Sendable {
  /// The content hash the edits were made on. Nil for an old draft.
  public var baseHash: String?
  public var title: String?
  public var body: String
  public var category: DocsCategory?
  public var hasCategory: Bool

  public init(
    baseHash: String? = nil, title: String? = nil, body: String, category: DocsCategory? = nil, hasCategory: Bool = false
  ) {
    self.baseHash = baseHash
    self.title = title
    self.body = body
    self.category = category
    self.hasCategory = hasCategory
  }
}
