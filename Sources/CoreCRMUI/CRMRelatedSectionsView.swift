import CoreKit
import SwiftUI

@MainActor
private final class CRMRelatedSectionsModel: ObservableObject {
  struct State {
    var items: [CRMRelatedItem] = []
    var createDefaults: [String: String] = [:]
    var isLoading = true
    var errorMessage: String?
    /// Set once per section from the contract plus the server's operation
    /// access, so rows don't re-probe the client on every redraw.
    var canUnlink = false
  }

  @Published private(set) var states: [String: State] = [:]

  /// Detach a related record. On success the section's refreshed items land in
  /// `states`; on failure the section keeps its rows and surfaces the error.
  func unlink(
    entity: String,
    id: String,
    section: CRMRelatedSectionContract,
    relatedID: String,
    repository: CRMRepository
  ) async throws {
    let refreshed = try await repository.unlinkRelated(
      entity: entity,
      recordID: id,
      relation: section.id,
      relatedID: relatedID
    )
    states[section.id]?.items = refreshed.items
    states[section.id]?.createDefaults = refreshed.createDefaults ?? [:]
  }

  func load(
    entity: String,
    id: String,
    sections: [CRMRelatedSectionContract],
    repository: CRMRepository
  ) async {
    for section in sections where states[section.id] == nil {
      let cached = try? await repository.cachedRelated(
        entity: entity,
        recordID: id,
        relation: section.id
      )
      // Checked in two steps rather than one `&&` chain: `&&` takes its right
      // operand as an autoclosure, which cannot carry the `await`. The contract
      // gates the probe, so the client is only asked when unlink is plausible.
      var canUnlink = false
      if section.allowsUnlink == true, section.access?.canWrite != false {
        canUnlink = await repository.canUnlink(entity: entity, relation: section.id)
      }
      states[section.id] = State(
        items: cached?.items ?? [],
        createDefaults: cached?.createDefaults ?? [:],
        isLoading: cached == nil,
        canUnlink: canUnlink
      )
    }

    // Refresh sequentially with plain `await`, NOT a `withTaskGroup`. Each child
    // task awaits the SwiftData-backed cache actor (`refreshRelated` → cache
    // write); on the iOS 27 runtime, completing those future-bearing child tasks
    // crashes in `swift::AsyncTask::completeFuture` (`__cxa_pure_virtual`) — a
    // release-only trap the debug runtime hides. Direct `await`s use
    // continuations, not child-task futures, so they avoid that path entirely.
    // The related sections are few, so the lost parallelism is acceptable.
    for section in sections {
      do {
        let data = try await repository.refreshRelated(
          entity: entity,
          recordID: id,
          relation: section.id
        )
        states[section.id]?.items = data.items
        states[section.id]?.createDefaults = data.createDefaults ?? [:]
        states[section.id]?.isLoading = false
        states[section.id]?.errorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        if states[section.id]?.items.isEmpty == false {
          states[section.id]?.isLoading = false
        } else {
          states[section.id]?.items = []
          states[section.id]?.isLoading = false
          states[section.id]?.errorMessage = error.localizedDescription
        }
      }
    }
  }
}

struct CRMRelatedSectionsView: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.crmOpenRelated) private var openRelated

  let sourceContract: CRMEntityContract
  let sourceRecordID: String
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let onToast: (String) -> Void
  let onChanged: () -> Void

  @StateObject private var model = CRMRelatedSectionsModel()
  @State private var creatingSection: CRMRelatedSectionContract?
  @State private var unlinkError: String?

  private var sections: [CRMRelatedSectionContract] {
    sourceContract.related ?? []
  }

  var body: some View {
    // The presentation/lifecycle modifiers below MUST hang off a single stable
    // anchor (this `Group`), never the bare `ForEach`. On a `ForEach`, `.task`
    // fires once PER section, so `model.load()` runs N times concurrently and N
    // tasks stampede the same `@Published states` — reentrant SwiftUI graph
    // updates that crash release builds with `libc++abi: Pure virtual function
    // called!` (an AttributeGraph reentrancy trap the debug optimizer hides).
    // The Group fires `.task` once and gives `.sheet`/`.alert` one host.
    Group {
      ForEach(sections) { section in
        Section {
          let state = model.states[section.id]
          if section.access?.canRead == false {
            Label(
              "No access",
              systemImage: "lock.fill"
            )
            .font(.footnote)
            .foregroundStyle(crmSecondaryText)
            .accessibilityHint(
              "Requires \(section.access?.missingScopes.joined(separator: ", ") ?? "additional access")"
            )
          } else if state?.isLoading != false {
            ProgressView().frame(maxWidth: .infinity)
          } else if let errorMessage = state?.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(crmSecondaryText)
          } else if state?.items.isEmpty != false {
            Text(section.emptyMessage)
              .foregroundStyle(crmSecondaryText)
          } else {
            // Index-keyed, not `id`-keyed: the server's related-item `id`s can be
            // empty or repeat (e.g. interactions), and a `ForEach` keyed on a
            // colliding/empty id realizes to undefined behavior when the section
            // scrolls into view. The array position is always unique.
            ForEach(Array((state?.items ?? []).enumerated()), id: \.offset) { _, item in
              Group {
                // Related content can render inside an `.inspector` (outside the
                // column's NavigationStack), so items open through the environment
                // action rather than a `NavigationLink` — the detail view pushes
                // the target onto the main column so the viewer becomes that page.
                if item.navigable != false, openRelated.isEnabled,
                  allContracts.contains(where: { $0.id == section.entity }) {
                  Button {
                    openRelated(CRMRelatedTarget(
                      entityID: section.entity, recordID: item.id, title: item.name))
                  } label: {
                    CRMRelatedItemPresentation(item: item, section: section)
                      .contentShape(.rect)
                  }
                  .buttonStyle(.plain)
                } else {
                  CRMRelatedItemPresentation(item: item, section: section)
                }
              }
              .swipeActions(edge: .trailing) {
                if state?.canUnlink == true {
                  // "Remove", not "Delete" — the server clears the relation's
                  // foreign key and the record itself survives.
                  Button("Remove", role: .destructive) {
                    unlink(item, from: section)
                  }
                }
              }
            }
          }
        } header: {
          HStack {
            Text(section.label)
            Spacer()
            if creation(for: section) != nil {
              Button {
                beginCreation(in: section)
              } label: {
                Image(systemName: "plus")
              }
              .buttonStyle(.plain)
              .accessibilityLabel(createLabel(for: section))
            }
          }
        }
      }
    }
    .task(id: sourceRecordID) {
      await model.load(
        entity: sourceContract.id,
        id: sourceRecordID,
        sections: sections.filter { $0.access?.canRead != false },
        repository: repository
      )
    }
    .sheet(item: $creatingSection) { section in
      if let creation = creation(for: section),
        let targetContract = creation.targetContract {
        DynamicEntityFormView(
          contract: targetContract,
          allContracts: allContracts,
          repository: repository,
          initialValues: creation.initialValues,
          onSaved: { savedRecord in
            guard let sourceLinkField = creation.sourceLinkField else { return }
            _ = try await repository.save(
              entity: sourceContract.id,
              id: sourceRecordID,
              values: [sourceLinkField: .string(savedRecord.id)],
              primaryField: sourceContract.primaryField
            )
          },
          onCompleted: { message in
            onToast(message)
            onChanged()
            Task {
              await model.load(
                entity: sourceContract.id,
                id: sourceRecordID,
                sections: [section],
                repository: repository
              )
            }
          }
        )
      }
    }
    .alert("Unable to Remove", isPresented: Binding(
      get: { unlinkError != nil },
      set: { if !$0 { unlinkError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(unlinkError ?? "Unknown error")
    }
    .sensoryFeedback(.error, trigger: unlinkError)
  }

  private func unlink(_ item: CRMRelatedItem, from section: CRMRelatedSectionContract) {
    Task {
      do {
        try await model.unlink(
          entity: sourceContract.id,
          id: sourceRecordID,
          section: section,
          relatedID: item.id,
          repository: repository
        )
        onToast("Removed \(item.name) from \(sourceContract.singularLabel.lowercased())")
        onChanged()
      } catch {
        // Not a toast: the toast is a success surface (fixed checkmark glyph,
        // and the root fires `.success` on every one), so routing a failure
        // through it would both look and feel like the remove worked.
        unlinkError = error.localizedDescription
      }
    }
  }

  private struct RelatedCreation {
    let targetContract: CRMEntityContract?
    let initialValues: [String: JSONValue]
    let sourceLinkField: String?
    let webURL: URL?
  }

  private func creation(for section: CRMRelatedSectionContract) -> RelatedCreation? {
    guard section.access?.canWrite != false else { return nil }

    guard let targetContract = allContracts.first(where: { $0.id == section.entity }) else {
      guard let webURL = webCreateURL(for: section) else { return nil }
      return RelatedCreation(
        targetContract: nil,
        initialValues: [:],
        sourceLinkField: nil,
        webURL: webURL
      )
    }
    guard targetContract.canCreate else { return nil }

    let targetRelationField = targetContract.fields.first { field in
      if field.name == section.create?.prefillField { return true }
      return field.relationEntity == sourceContract.id
        && (field.kind == "relation" || field.kind == "multiRelation")
    }
    let sourceLinkField = sourceContract.fields.first {
      $0.relationEntity == targetContract.id && $0.kind == "relation"
    }?.name

    var values: [String: JSONValue] = [:]
    for (name, rawValue) in model.states[section.id]?.createDefaults ?? [:] {
      guard let field = targetContract.fields.first(where: { $0.name == name }) else { continue }
      values[name] = relationValue(rawValue, for: field)
    }
    if let targetRelationField {
      values[targetRelationField.name] = relationValue(sourceRecordID, for: targetRelationField)
    }

    if values.isEmpty, sourceLinkField == nil {
      guard let webURL = webCreateURL(for: section) else { return nil }
      return RelatedCreation(
        targetContract: nil,
        initialValues: [:],
        sourceLinkField: nil,
        webURL: webURL
      )
    }

    return RelatedCreation(
      targetContract: targetContract,
      initialValues: values,
      sourceLinkField: sourceLinkField,
      webURL: nil
    )
  }

  private func beginCreation(in section: CRMRelatedSectionContract) {
    guard let creation = creation(for: section) else { return }
    if let webURL = creation.webURL {
      openURL(webURL)
    } else {
      creatingSection = section
    }
  }

  private func relationValue(_ id: String, for field: CRMFieldContract) -> JSONValue {
    field.kind == "multiRelation" ? .array([.string(id)]) : .string(id)
  }

  private func createLabel(for section: CRMRelatedSectionContract) -> String {
    section.create?.label
      ?? "Add \(allContracts.first(where: { $0.id == section.entity })?.singularLabel ?? section.label)"
  }

  private func webCreateURL(for section: CRMRelatedSectionContract) -> URL? {
    guard let create = section.create else { return nil }
    guard
      var components = URLComponents(
        url: ServerConfig.baseURL.appending(path: create.webPath),
        resolvingAgainstBaseURL: false
      )
    else { return nil }

    var defaults = model.states[section.id]?.createDefaults ?? [:]
    if let prefillField = create.prefillField {
      defaults[prefillField] = sourceRecordID
    }
    components.queryItems = defaults.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    return components.url
  }
}

private struct CRMRelatedItemPresentation: View {
  let item: CRMRelatedItem
  let section: CRMRelatedSectionContract

  @ViewBuilder
  var body: some View {
    switch section.presentation ?? .list {
    case .list:
      CRMRelatedItemRow(item: item, icon: section.icon)
    case .compact:
      CRMRelatedCompactItemRow(item: item, icon: section.icon)
    case .timeline:
      CRMRelatedTimelineItemRow(item: item)
    case .cards:
      CRMRelatedCardItemRow(item: item, icon: section.icon)
    @unknown default:
      CRMRelatedItemRow(item: item, icon: section.icon)
    }
  }
}

private struct CRMRelatedItemRow: View {
  let item: CRMRelatedItem
  let icon: String

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).lineLimit(1)
        if let detail = item.tag ?? item.subtitle, !detail.isEmpty {
          Text(detail).font(.caption).foregroundStyle(crmSecondaryText).lineLimit(1)
        }
      }
    } icon: {
      Image(crmSymbol: icon, fallback: "circle").foregroundStyle(crmSecondaryText)
    }
  }
}

private struct CRMRelatedCompactItemRow: View {
  let item: CRMRelatedItem
  let icon: String

  var body: some View {
    Label {
      Text(item.name)
    } icon: {
      Image(crmSymbol: icon, fallback: "circle")
    }
    .lineLimit(1)
  }
}

/// Maps an interaction's `type` — carried by the server in a related item's
/// `tag` (`note`, `email`, `call`, `meeting`, `web`) — to an SF Symbol.
/// Returns nil for tags that aren't a known interaction type, so other
/// timeline sections (e.g. milestones, which carry no tag) keep the plain
/// bullet and unrecognized tags degrade to their text label.
private func interactionTypeSymbol(_ tag: String?) -> String? {
  switch tag?.lowercased() {
  case "note": return "note.text"
  case "email": return "envelope"
  case "call": return "phone"
  case "meeting": return "person.2"
  case "web": return "globe"
  default: return nil
  }
}

private struct CRMRelatedTimelineItemRow: View {
  let item: CRMRelatedItem

  var body: some View {
    HStack(alignment: .top, spacing: CRMListRow.iconSpacing) {
      Group {
        if let symbol = interactionTypeSymbol(item.tag) {
          Image(systemName: symbol).imageScale(.small)
        } else {
          Circle().fill(.secondary).frame(width: 8, height: 8)
        }
      }
      .foregroundStyle(crmSecondaryText)
      .frame(width: 16, alignment: .center)
      .padding(.top, 3)
      VStack(alignment: .leading, spacing: CRMListRow.indicatorSpacing) {
        Text(item.name).lineLimit(1)
        // Index-keyed: two detail lines can be identical strings (e.g. type ==
        // date), and `id: \.self` over a colliding value is undefined.
        ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption).foregroundStyle(crmSecondaryText).lineLimit(1)
        }
      }
    }
  }

  /// Type and date as separate lines when the tag is a known interaction type,
  /// so the row surfaces both without cramming them onto one. Falls back to the
  /// old `subtitle ?? tag` for sections whose tag isn't a type.
  private var detailLines: [String] {
    let typeLabel = interactionTypeSymbol(item.tag) != nil ? item.tag?.capitalized : nil
    switch (typeLabel, item.subtitle) {
    case let (type?, date?): return [type, date]
    case let (type?, nil): return [type]
    case let (nil, date?): return [date]
    case (nil, nil): return [item.tag].compactMap { $0 }
    }
  }
}

private struct CRMRelatedCardItemRow: View {
  let item: CRMRelatedItem
  let icon: String

  var body: some View {
    HStack(alignment: .top, spacing: CRMListRow.iconSpacing) {
      Image(crmSymbol: icon, fallback: "circle")
        .foregroundStyle(crmSecondaryText)
      VStack(alignment: .leading, spacing: CRMListRow.indicatorSpacing) {
        HStack {
          Text(item.name).fontWeight(.medium).lineLimit(2)
          Spacer(minLength: 8)
          if let tag = item.tag, !tag.isEmpty {
            Text(tag)
              .font(.caption2)
              .foregroundStyle(crmSecondaryText)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
        }
        if let subtitle = item.subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.caption).foregroundStyle(crmSecondaryText).lineLimit(2)
        }
      }
    }
    .padding(.vertical, 5)
  }
}

