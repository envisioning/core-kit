import CoreCRMUI
import CoreKit
import DocsKit
import EnvisioningUI
import SwiftUI

/// Who knows the CRM: names for subjects a document already has, and search
/// for ones to add. The host supplies it; without one the editor shows its
/// subjects by kind and offers no way to change them.
public protocol SubjectDirectory: Sendable {
  func name(for subject: DocsSubject) async -> String?
  func search(_ query: String) async throws -> [(subject: DocsSubject, name: String)]
}

/// The directory over Core's registry: search across the five subject
/// kinds, names by the entity's primary field.
public struct CoreSubjectDirectory: SubjectDirectory {
  private let repository: CRMRepository
  private let contracts: [CRMEntityContract]

  public init(repository: CRMRepository, contracts: [CRMEntityContract]) {
    self.repository = repository
    self.contracts = contracts
  }

  /// `organizations` ↔ `organization`: the registry pluralises, Docs does not.
  static let entityByKind: [String: String] = [
    "organization": "organizations", "contact": "contacts", "offer": "offers", "lead": "leads", "project": "projects",
  ]
  static let kindByEntity: [String: String] = Dictionary(uniqueKeysWithValues: entityByKind.map { ($1, $0) })

  public func name(for subject: DocsSubject) async -> String? {
    guard let entity = Self.entityByKind[subject.kind],
          let contract = contracts.first(where: { $0.id == entity })
    else { return nil }
    guard let record = try? await repository.record(entity: entity, id: subject.subjectId, primaryField: contract.primaryField) else { return nil }
    if case .string(let name)? = record.record.fields[contract.primaryField] { return name }
    return nil
  }

  public func search(_ query: String) async throws -> [(subject: DocsSubject, name: String)] {
    let envelope = try await repository.search(query, limit: 12)
    return envelope.data.compactMap { result in
      guard let kind = Self.kindByEntity[result.entity] else { return nil }
      return (DocsSubject(kind: kind, subjectId: result.id), result.name)
    }
  }
}

/// A document's subjects as chips with a way to add and remove. Writes go
/// straight to the server (replace-all) — this is a relation, not text, so
/// it does not ride the autosave.
public struct SubjectEditor: View {
  public let documentID: String
  public let client: DocsClient
  public let directory: SubjectDirectory
  @Binding public var subjects: [DocsSubject]
  public let onToast: (String) -> Void

  @State private var names: [String: String] = [:]
  @State private var adding = false
  @State private var query = ""
  @State private var results: [(subject: DocsSubject, name: String)] = []

  public init(documentID: String, client: DocsClient, directory: SubjectDirectory, subjects: Binding<[DocsSubject]>, onToast: @escaping (String) -> Void = { _ in }) {
    self.documentID = documentID
    self.client = client
    self.directory = directory
    _subjects = subjects
    self.onToast = onToast
  }

  public var body: some View {
    HStack(spacing: 6) {
      ForEach(subjects, id: \.ref) { subject in
        HStack(spacing: 3) {
          Text(names[subject.ref] ?? subject.kind.capitalized)
          Button { Task { await remove(subject) } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.14), in: Capsule())
      }
      Button { adding = true } label: { Label("Subject", systemImage: "plus").font(.caption) }
        .buttonStyle(.borderless)
        .popover(isPresented: $adding) { picker }
      Spacer(minLength: 0)
    }
    .task(id: subjects.map(\.ref).joined()) { await resolveNames() }
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Organization, contact, project…", text: $query)
        .coreField()
        .task(id: query) {
          try? await Task.sleep(for: .milliseconds(200))
          guard !Task.isCancelled else { return }
          await search()
        }
      if results.isEmpty {
        Text(query.isEmpty ? "Type to search Core." : "Nothing in Core matches.").font(.footnote).foregroundStyle(.secondary)
      } else {
        ForEach(results, id: \.subject.ref) { hit in
          Button {
            Task { await add(hit.subject, name: hit.name) }
          } label: {
            HStack {
              Text(hit.name)
              Spacer()
              Text(hit.subject.kind.capitalized).foregroundStyle(.secondary).font(.caption)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(subjects.contains(hit.subject))
        }
      }
    }
    .padding(12)
    .frame(width: 320)
  }

  private func resolveNames() async {
    for subject in subjects where names[subject.ref] == nil {
      if let name = await directory.name(for: subject) { names[subject.ref] = name }
    }
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard q.count >= 2 else { results = []; return }
    results = (try? await directory.search(q)) ?? []
  }

  private func add(_ subject: DocsSubject, name: String) async {
    names[subject.ref] = name
    await write(subjects + [subject])
    adding = false
    query = ""
  }

  private func remove(_ subject: DocsSubject) async {
    await write(subjects.filter { $0 != subject })
  }

  private func write(_ next: [DocsSubject]) async {
    let before = subjects
    subjects = next
    do {
      let detail = try await client.setSubjects(id: documentID, next)
      subjects = detail.subjects
    } catch {
      subjects = before
      onToast(error.localizedDescription)
    }
  }
}
