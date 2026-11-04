import Foundation

/// One way to file documents (meet#377): into a folder, under a category
/// (nil clears it), or on and off a subject. A drag onto a rail row and the
/// File menu on a row both file through `DocsClient.file(_:_:)`.
public enum DocsFilingAct: Hashable, Sendable {
  case folder(String)
  case category(DocsCategory?)
  case addSubject(DocsSubject)
  case removeSubject(DocsSubject)
}

extension DocsDocumentSummary {
  /// The folder the document sits in: `/work/acme/brief` → `/work/acme`.
  public var folderPath: String {
    "/" + path.split(separator: "/").dropLast().joined(separator: "/")
  }

  /// Whether the document is about this subject, whatever system named it.
  public func isAbout(_ subject: DocsSubject) -> Bool {
    subjects.contains { $0.kind == subject.kind && $0.subjectId == subject.subjectId }
  }
}

extension DocsClient {
  /// Files every document Meet can change and answers how many changed. A
  /// document already filed so is left alone. Stops at the first failure;
  /// what was filed before it stays filed.
  public func file(_ documents: [DocsDocumentSummary], _ act: DocsFilingAct) async throws -> Int {
    var changed = 0
    for document in documents where document.editable {
      switch act {
      case .folder(let path):
        guard document.folderPath != path else { continue }
        _ = try await move(id: document.id, DocsMoveDocument(folderPath: path))
      case .category(let category):
        guard document.category != category else { continue }
        _ = try await update(id: document.id, DocsUpdateDocument(category: .some(category)))
      case .addSubject(let subject):
        guard !document.isAbout(subject) else { continue }
        _ = try await setSubjects(id: document.id, document.subjects + [subject])
      case .removeSubject(let subject):
        guard document.isAbout(subject) else { continue }
        let rest = document.subjects.filter { !($0.kind == subject.kind && $0.subjectId == subject.subjectId) }
        _ = try await setSubjects(id: document.id, rest)
      }
      changed += 1
    }
    return changed
  }
}
