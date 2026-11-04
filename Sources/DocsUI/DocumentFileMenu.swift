import DocsKit
import SwiftUI

/// What a host can file into: its move targets and the subjects it can
/// name. The host loads them; the menu only draws them.
public struct DocsFilingChoices: Sendable {
  public struct Subject: Hashable, Identifiable, Sendable {
    public let subject: DocsSubject
    public let title: String
    public var id: String { subject.ref }

    public init(subject: DocsSubject, title: String) {
      self.subject = subject
      self.title = title
    }
  }

  public var folders: [DocsFolder]
  /// The workspace's categories in rail order. Empty offers "No category" only.
  public var categories: [DocsCategoryInfo]
  public var projects: [Subject]
  public var leads: [Subject]
  /// A partner is filed as its organization: the host maps each to the
  /// organization subject, so the tick reads the same document link.
  public var partners: [Subject]

  public init(
    folders: [DocsFolder] = [], categories: [DocsCategoryInfo] = [], projects: [Subject] = [], leads: [Subject] = [],
    partners: [Subject] = []
  ) {
    self.folders = folders
    self.categories = categories
    self.projects = projects
    self.leads = leads
    self.partners = partners
  }
}

/// The File submenu on a document row (meet#377): Folder, Category, Project,
/// Lead and Partner, for one document or many. A tick means every document is filed
/// so; choosing a ticked subject takes it off. The host runs the act,
/// usually through `DocsClient.file(_:_:)`.
public struct DocumentFileMenu: View {
  public let documents: [DocsDocumentSummary]
  public let choices: DocsFilingChoices
  public let onFile: (DocsFilingAct) -> Void

  public init(documents: [DocsDocumentSummary], choices: DocsFilingChoices, onFile: @escaping (DocsFilingAct) -> Void) {
    self.documents = documents.filter(\.editable)
    self.choices = choices
    self.onFile = onFile
  }

  public var body: some View {
    if !documents.isEmpty {
      Menu {
        if !choices.folders.isEmpty {
          Menu("Folder") { folderItems(under: nil) }
        }
        Menu("Category") {
          tick("No category", on: documents.allSatisfy { $0.category == nil }) { onFile(.category(nil)) }
          if !choices.categories.isEmpty {
            Divider()
            ForEach(choices.categories) { category in
              tick(category.label, on: documents.allSatisfy { $0.category == category.id }) { onFile(.category(category.id)) }
            }
          }
        }
        subjectMenu("Project", choices.projects)
        subjectMenu("Lead", choices.leads)
        subjectMenu("Partner", choices.partners)
      } label: {
        Label(documents.count > 1 ? "File \(documents.count)" : "File", systemImage: "folder")
      }
    }
  }

  // MARK: Folders, as the tree they are

  private var folderIDs: Set<String> { Set(choices.folders.map(\.id)) }

  /// The folders under `parent`; nil is the top: every folder whose parent
  /// is not itself a choice (a mirrored parent is not one).
  private func children(of parent: String?) -> [DocsFolder] {
    choices.folders
      .filter { parent == nil ? !($0.parentId.map(folderIDs.contains) ?? false) : $0.parentId == parent }
      .sorted { $0.path < $1.path }
  }

  private func folderItems(under parent: String?) -> AnyView {
    AnyView(ForEach(children(of: parent)) { folder in
      let here = tick(folder.title, on: documents.allSatisfy { $0.folderPath == folder.path }) { onFile(.folder(folder.path)) }
      if children(of: folder.id).isEmpty {
        here
      } else {
        Menu(folder.title) {
          here
          Divider()
          folderItems(under: folder.id)
        }
      }
    })
  }

  // MARK: Subjects

  @ViewBuilder
  private func subjectMenu(_ title: LocalizedStringKey, _ subjects: [DocsFilingChoices.Subject]) -> some View {
    if !subjects.isEmpty {
      Menu(title) {
        ForEach(subjects) { choice in
          let about = documents.allSatisfy { $0.isAbout(choice.subject) }
          tick(choice.title, on: about) { onFile(about ? .removeSubject(choice.subject) : .addSubject(choice.subject)) }
        }
      }
    }
  }

  /// A menu item with the platform's own tick.
  private func tick(_ title: String, on: Bool, act: @escaping () -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { on }, set: { _ in act() }))
  }
}
