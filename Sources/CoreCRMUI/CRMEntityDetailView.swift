import CoreKit
import EnvisioningUI
import SwiftUI

/// A display group derived from the registry's ordered field list. CRM usually
/// publishes explicit `section` markers; CMS also publishes flat fields and can
/// reference section names without a marker. Keeping that normalization here
/// gives detail and create one complete, registry-driven grouping model.
private struct EntityFieldGroup: Identifiable {
  let id: String
  let label: String
  var fields: [CRMFieldContract]
}

private func entityFieldGroups(for contract: CRMEntityContract) -> [EntityFieldGroup] {
  let overviewID = "__unsectioned_fields__"
  var groups: [EntityFieldGroup] = []
  var indexes: [String: Int] = [:]
  let sectionLabels = contract.fields.reduce(into: [String: String]()) { labels, field in
    if field.kind == "section" { labels[field.name] = field.label }
  }

  func fallbackLabel(for name: String) -> String {
    name
      .split(whereSeparator: { $0 == "_" || $0 == "-" })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  func ensureGroup(id: String, label: String) -> Int {
    if let index = indexes[id] { return index }
    let index = groups.count
    groups.append(EntityFieldGroup(id: id, label: label, fields: []))
    indexes[id] = index
    return index
  }

  for field in contract.fields {
    if field.kind == "section" {
      _ = ensureGroup(id: field.name, label: field.label)
      continue
    }
    let sectionID = field.section.flatMap { $0.isEmpty ? nil : $0 } ?? overviewID
    let label = sectionID == overviewID
      ? "Overview"
      : sectionLabels[sectionID] ?? fallbackLabel(for: sectionID)
    let index = ensureGroup(id: sectionID, label: label)
    groups[index].fields.append(field)
  }

  return groups.filter { !$0.fields.isEmpty }
}

/// The single page for one CRM record — the same surface for viewing and
/// editing, mirroring the web CRM's one-form model. Fields render as their real
/// controls at all times; edits stay in local `values` and only commit to the
/// server on Save (deferred commit is the accidental-edit protection). When the
/// entity isn't updatable the whole page renders read-only with no Save bar.
public struct EntityDetailView: View {
  @Environment(CRMFavoriteCenter.self) private var favorites: CRMFavoriteCenter?
  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let onToast: (String) -> Void
  let onChanged: () -> Void
  /// Slug of the research hub this record was opened under, when known —
  /// lets a technology's stats query use its exact public path instead of a
  /// wildcard. Optional so only the hub browse flow needs to pass it.
  let hubSlug: String?

  @Environment(\.dismiss) private var dismiss

  @State private var record: CRMRecord
  @State private var values: [String: JSONValue]
  @State private var originalValues: [String: JSONValue]
  @State private var originalPayload: [String: JSONValue]
  @State private var relationOptions: [String: [CRMRecord]] = [:]
  @State private var characteristicOptions: [CRMCharacteristicOption] = []
  @State private var memberOptions: [CRMMember] = []
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false
  @State private var showingDiscardConfirmation = false
  @State private var canMergeContacts = false
  @State private var shareURL: URL?
  /// The modally-presented surface, if any. One `.sheet(item:)` drives both the
  /// contact-merge flow and the Doc reader — stacking multiple `.sheet` modifiers
  /// on one view is unreliable (only one presents), so they route through here.
  @State private var activeSheet: DetailSheet?

  private enum DetailSheet: Identifiable {
    case contactMerge
    case reader
    var id: Int {
      switch self {
      case .contactMerge: return 0
      case .reader: return 1
      }
    }
  }
  /// Whether the related-records inspector is open (wide layouts only). Defaults
  /// open so related content sits beside the form, like the web's two-column
  /// editor; on iPhone the related sections render inline instead.
  @State private var showingRelatedInspector = true
  /// The related record the user asked to open (relation-field value or a
  /// related-section item), pushed onto this column's stack so the viewer
  /// becomes that page.
  @State private var openedRelated: CRMRelatedTarget?
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  public init(
    contract: CRMEntityContract,
    allContracts: [CRMEntityContract],
    record: CRMRecord,
    repository: CRMRepository,
    hubSlug: String? = nil,
    onToast: @escaping (String) -> Void,
    onChanged: @escaping () -> Void
  ) {
    self.contract = contract
    self.allContracts = allContracts
    self.repository = repository
    self.hubSlug = hubSlug
    self.onToast = onToast
    self.onChanged = onChanged
    let seeded = Self.seededValues(for: contract, from: record.fields)
    _record = State(initialValue: record)
    _values = State(initialValue: seeded)
    _originalValues = State(initialValue: seeded)
    _originalPayload = State(initialValue: Self.normalizedPayload(for: contract, from: seeded))
  }

  /// Public-website page for this record, or `nil` when the entity has no
  /// public page (CRM entities, unmapped CMS entities) or the record has no
  /// slug — the stats strip is hidden entirely then. Computed off `record`
  /// so a saved slug edit re-resolves.
  private var publicStatsPath: PublicPagePath? {
    PublicPermalinkMap().pagePath(entityID: contract.id, record: record, hubSlug: hubSlug)
  }

  private var hasRelatedSections: Bool { contract.related?.isEmpty == false }

  /// Wide enough for a side inspector: always on macOS (the Dock window), and
  /// only in regular width on iOS (iPad, not iPhone).
  private var isWideLayout: Bool {
    #if os(macOS)
      return true
    #else
      return horizontalSizeClass == .regular
    #endif
  }

  /// Related records go in a trailing inspector on wide screens; on iPhone they
  /// stay inline at the bottom of the form.
  private var showsRelatedInspector: Bool { hasRelatedSections && isWideLayout }

  private var relatedInspectorPresented: Binding<Bool> {
    Binding(
      get: { showsRelatedInspector && showingRelatedInspector },
      set: { showingRelatedInspector = $0 }
    )
  }

  /// The related-records sections (emits bare `Section`s — must live inside a
  /// `Form`/`List`). Shared by the inline (iPhone) and inspector (wide) mounts.
  private var relatedSections: some View {
    CRMRelatedSectionsView(
      sourceContract: contract,
      sourceRecordID: record.id,
      allContracts: allContracts,
      repository: repository,
      onToast: onToast,
      onChanged: onChanged
    )
  }

  /// The trailing inspector column on wide screens — the same related sections
  /// in their own grouped form, sized like a sidebar.
  private var relatedInspector: some View {
    EnvisioningForm {
      relatedSections
    }
    .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
  }

  public var body: some View {
    EnvisioningForm {
      if identity.usesHeroLayout {
        contentHeroHeader
      } else if usesCenteredHeader {
        centeredHeader
      } else if showsAvatar {
        HStack(spacing: 16) {
          CachedRemoteAvatar(
            url: record.avatarURL,
            name: title,
            size: 64,
            fallbackSymbol: contract.icon,
            shape: .resolve(entityID: contract.id)
          )
          Text(title)
            .font(.title2.weight(.semibold))
            .lineLimit(2)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
      }
      if let publicStatsPath {
        PlausibleStatsStrip(path: publicStatsPath)
      }
      if contract.id == "licenses" {
        LicenseOverviewSection(record: record)
      }
      if contract.id == "contacts",
        let outreachStatus = record["signals_outreach_status"]?.stringValue,
        !outreachStatus.isEmpty {
        SignalsOutreachSection(
          record: record, repository: repository, onToast: onToast, onChanged: onChanged)
      }
      if contract.id == "support_cases", let replyURL = supportCaseReplyURL {
        Section {
          Link(destination: replyURL) {
            Label("Reply to Customer", systemImage: "arrowshape.turn.up.left")
          }
        } footer: {
          Text("Opens Mail to \(supportCaseCustomerEmail ?? "the customer"), CC’d to \(Self.supportCaseCaptureAddress) so the reply is logged on this case.")
        }
      }
      ForEach(contextRelationFields) { field in
        RelationContextCard(
          field: field,
          sourceRecord: record,
          allContracts: allContracts,
          repository: repository,
          onToast: onToast,
          onChanged: onChanged
        )
      }
      ForEach(fieldGroups) { group in
        Section(group.label) {
          ForEach(group.fields) { field in
            fieldRow(field)
          }
        }
      }
      // On iPhone the related sections stay inline at the bottom; on wide
      // screens they move to the trailing inspector (below).
      if hasRelatedSections && !showsRelatedInspector {
        relatedSections
      }
      if contract.canUpdate && contract.canDelete {
        Section {
          Button("Delete \(contract.singularLabel)", role: .destructive) {
            showingDeleteConfirmation = true
          }
        }
      }
      if contract.id == "contacts" && canMergeContacts {
        Section {
          Button {
            activeSheet = .contactMerge
          } label: {
            Label("Merge Contact…", systemImage: "arrow.triangle.merge")
          }
          .disabled(isDirty)
        } footer: {
          if isDirty {
            Text("Save or revert your changes before merging.")
          } else {
            Text("Combine a duplicate contact, its email identities, and all linked records.")
          }
        }
      }
      RecordMetadataFooter(record: record, contract: contract)
    }
    // `EnvisioningForm` pins the grouped style. Without it, macOS `Form` falls
    // back to its default columns layout when this view isn't the direct root
    // of a navigation destination (e.g. reached via the ⌘K search → dashboard
    // loader path), which collapses labels onto their fields.
    .environment(\.crmOpenRelated, CRMOpenRelatedAction(handler: { openedRelated = $0 }))
    .navigationDestination(item: $openedRelated) { target in
      if let targetContract = allContracts.first(where: { $0.id == target.entityID }) {
        EntityRecordDetailLoader(
          contract: targetContract,
          allContracts: allContracts,
          recordID: target.recordID,
          title: target.title ?? targetContract.singularLabel,
          repository: repository,
          onToast: onToast,
          onChanged: onChanged
        )
      }
    }
    .inspector(isPresented: relatedInspectorPresented) {
      relatedInspector
    }
    .navigationTitle(usesCenteredHeader ? contract.singularLabel : title)
    .navigationBarTitleDisplayMode(.inline)
    .crmBackToolbar(
      destination: contract.pluralLabel,
      isDirty: isDirty,
      onBack: requestBack
    )
    .toolbar {
      if let target = favorites?.target(for: record, in: contract) {
        ToolbarItem(placement: .automatic) {
          CRMFavoriteToggleButton(target: target, onError: onToast)
        }
      }
      if showsRelatedInspector {
        ToolbarItem(placement: .automatic) {
          Button {
            showingRelatedInspector.toggle()
          } label: {
            Label("Related", systemImage: "sidebar.trailing")
          }
          .help("Show related records")
        }
      }
      if docReaderMarkdown != nil {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            activeSheet = .reader
          } label: {
            Label("Read", systemImage: "book")
          }
          .help("Read this Doc")
        }
      }
      if let shareURL {
        ToolbarItem(placement: .topBarTrailing) {
          // macOS: a direct "Copy Link" is the desktop idiom — the system share
          // picker doesn't cleanly offer copy. iOS: ShareLink's sheet already
          // surfaces Copy alongside the native share targets.
          #if os(macOS)
            Button {
              copyToPasteboard(shareURL.absoluteString)
              onToast("Link copied")
            } label: {
              Label("Copy Link", systemImage: "link")
            }
          #else
            ShareLink(item: shareURL) {
              Label("Share Link", systemImage: "square.and.arrow.up")
            }
          #endif
        }
      }
      if let publicURL = ServerConfig.publicShareURL(entityID: contract.id, recordID: record.id) {
        ToolbarItem(placement: .topBarTrailing) {
          // Copies the public www viewer link — a shareable, read-only URL to this
          // record, distinct from the auth-gated CRM permalink above.
          Button {
            copyToPasteboard(publicURL.absoluteString)
            onToast("Public link copied")
          } label: {
            Label("Copy Public Link", systemImage: "doc.on.doc")
          }
        }
      }
    }
    .disabled(isSaving)
    .safeAreaInset(edge: .bottom) {
      if contract.canUpdate && isDirty {
        commitBar
      }
    }
    .overlay { if isSaving { ProgressView().controlSize(.large) } }
    .task {
      await loadFullRecord()
      if let navigation = try? await repository.cachedNavigation() {
        shareURL = navigation.recordWebURL(entityId: contract.id, recordID: record.id)
      }
      if contract.id == "contacts" {
        canMergeContacts = await repository.canMergeContacts()
      }
      if contract.canUpdate {
        await loadRelationOptions()
        await loadCharacteristicOptions()
        await loadMemberOptions()
      }
    }
    // The page loads once per open, so a record left on screen goes stale — and
    // its Website strip already re-queries on activation. Safe against
    // in-progress edits: `loadFullRecord` bails while the record is dirty.
    .onAppActivation { Task { await loadFullRecord() } }
    .onRefreshRequest { Task { await loadFullRecord() } }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .contactMerge:
        ContactMergeSheet(
          contact: record,
          repository: repository
        ) { survivor in
          applyMergedContact(survivor)
        }
      case .reader:
        DocMarkdownReader(title: title, markdown: docReaderMarkdown ?? "")
      }
    }
    .confirmationDialog(
      "Delete this \(contract.singularLabel.lowercased())?",
      isPresented: $showingDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { Task { await deleteRecord() } }
    }
    .confirmationDialog(
      "Discard unsaved changes?",
      isPresented: $showingDiscardConfirmation,
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        values = originalValues
        dismiss()
      }
    } message: {
      Text("Your changes to this \(contract.singularLabel.lowercased()) have not been saved.")
    }
    .alert("Unable to Save", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
    // Successes reach the root as a toast, which carries its own `.success`.
    // Failures stop here in a local alert, so the matching `.error` has to be
    // raised here or a failed save is the only silent outcome in the app.
    .sensoryFeedback(.error, trigger: errorMessage)
    .preference(key: CRMUnsavedChangesPreferenceKey.self, value: isDirty)
    .background {
      Group {
        Button("Back to \(contract.pluralLabel)") {
          requestBack()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save \(contract.singularLabel)") { Task { await save() } }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!isDirty || isSaving || !requiredFieldsArePresent)

        Button("Save \(contract.singularLabel)") { Task { await save() } }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!isDirty || isSaving || !requiredFieldsArePresent)

        Button("Back to \(contract.pluralLabel)") { dismiss() }
          .keyboardShortcut("[", modifiers: .command)
          .disabled(isDirty)
      }
      .hidden()
    }
  }

  private func requestBack() {
    if isDirty {
      showingDiscardConfirmation = true
    } else {
      dismiss()
    }
  }

  // MARK: Commit bar
  //
  // A floating, centered Liquid Glass cluster — no bar background, so the form
  // scrolls under it. Save is the prominent glass action; Revert is a small
  // secondary glass icon (deferred commit needs an escape hatch).

  private var commitBar: some View {
    HStack {
      Spacer(minLength: 0)
      #if os(iOS)
        if #available(iOS 26.0, *) {
          GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
              Button { values = originalValues } label: {
                Image(systemName: "arrow.uturn.backward")
                  .font(.body.weight(.semibold))
                  .frame(width: 50, height: 50)
              }
              .crmGlassButtonStyle()
              .disabled(isSaving)
              .accessibilityLabel("Revert changes")

              Button { Task { await save() } } label: {
                Text(isSaving ? "Saving…" : "Save")
                  .font(.body.weight(.semibold))
                  // `.glassProminent` fills with the accent and labels it white by
                  // default. Both accent variants are light limes (#AACC00 light,
                  // #D6F249 dark), so white lands at 1.9:1 and 1.3:1 contrast —
                  // unreadable either way. Black is 11:1 and 17:1 against the same
                  // two fills, so it is correct in both schemes, not just dark.
                  .foregroundStyle(.black)
                  .padding(.horizontal, 28)
                  .frame(height: 50)
              }
              .buttonStyle(.glassProminent)
              .disabled(isSaving || !requiredFieldsArePresent)
            }
          }
        } else {
          plainCommitCluster
        }
      #else
        plainCommitCluster
      #endif
      Spacer(minLength: 0)
    }
    .padding(.bottom, 8)
  }
  /// Liquid Glass needs iOS 26 / macOS 26. Below that — every Mac we ship to,
  /// and iOS 17–18 — the commit bar is a plain material cluster with the same
  /// two actions.
  private var plainCommitCluster: some View {
    HStack(spacing: 10) {
      Button { values = originalValues } label: {
        Image(systemName: "arrow.uturn.backward")
          .font(.body.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(isSaving)
      .accessibilityLabel("Revert changes")

      Button { Task { await save() } } label: {
        Text(isSaving ? "Saving…" : "Save")
          .font(.body.weight(.semibold))
          // Same contrast reasoning as the glass variant: both accent limes
          // need a black label, not the automatic white.
          .foregroundStyle(.black)
          .padding(.horizontal, 20)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isSaving || !requiredFieldsArePresent)
    }
    .padding(10)
    .background(EnvisioningSurface.elevated, in: Capsule())
    .overlay(Capsule().strokeBorder(EnvisioningSurface.border))
  }


  // MARK: Field rows

  @ViewBuilder
  private func fieldRow(_ field: CRMFieldContract) -> some View {
    if field.name == "birthday_month" {
      if contract.canUpdate {
        ContactBirthdayEditor(
          month: binding(named: "birthday_month"),
          day: binding(named: "birthday_day"),
          year: binding(named: "birthday_year")
        )
      } else if let birthday = CRMContactBirthday(record: record) {
        LabeledContent("Birthday", value: birthday.formatted())
      }
    } else {
      EntityFieldRow(
        field: field,
        value: binding(for: field),
        record: record,
        isEditable: contract.canUpdate,
        relationOptions: relationOptions[field.relationEntity ?? ""] ?? [],
        characteristicOptions: characteristicOptions,
        memberOptions: memberOptions,
        entityID: contract.id
      )
    }
  }

  /// Every registry field appears in exactly one group. In editable mode empty
  /// fields remain visible; read-only pages omit empty values as before.
  private var fieldGroups: [EntityFieldGroup] {
    entityFieldGroups(for: contract).compactMap { group in
      let visibleFields = group.fields.filter(isFieldVisible)
      guard !visibleFields.isEmpty else { return nil }
      return EntityFieldGroup(id: group.id, label: group.label, fields: visibleFields)
    }
  }

  private func isFieldVisible(_ field: CRMFieldContract) -> Bool {
    guard field.hidden != true, !hiddenFieldNames.contains(field.name) else { return false }
    // The members picker (task `assigned_to`) only applies to team-owned work.
    // Mirror the web form, which hides "Assigned To" unless Responsible Party
    // is "Envisioning" (`responsible_party == "team"`). Reads the live edited
    // value so the row appears/disappears as the party changes.
    if field.optionsSource == "members",
      (values["responsible_party"]?.stringValue ?? "") != "team" {
      return false
    }
    if contract.canUpdate { return true }
    if field.name == "birthday_month" { return CRMContactBirthday(record: record) != nil }
    return !(crmDisplayValue(for: field, in: record) ?? "").isEmpty
  }

  // MARK: Header / identity

  private var title: String {
    if contract.id == "licenses",
      let organization = record["organization"]?.objectValue?["name"]?.stringValue,
      !organization.isEmpty {
      return "License – \(organization)"
    }
    return record.displayName(
      primaryField: contract.primaryField,
      fallback: contract.singularLabel
    )
  }

  private var identity: CRMEntityIdentity {
    CRMEntityIdentity.resolve(contract)
  }

  /// A Doc's Markdown body, for the read-only reader — the live edited value so
  /// unsaved edits preview too. `nil` for non-Doc entities or empty content, so
  /// the Read affordance stays hidden.
  private var docReaderMarkdown: String? {
    guard contract.id == "notes" else { return nil }
    let content = (values["content_md"] ?? record["content_md"])?.stringValue ?? ""
    return content.isEmpty ? nil : content
  }

  // MARK: Support-case reply
  //
  // Support cases carry no reply field server-side; the agent answers from Mail.
  // This opens a prefilled compose CC'd to the shared capture mailbox with the
  // case's [SIG-####] tag in the subject, so the inbound pipeline threads the
  // reply back onto this case as an interaction instead of it living only in a
  // Sent folder.

  static let supportCaseCaptureAddress = "cc@envisioning.com"

  private var supportCaseCustomerEmail: String? {
    let raw = (values["customer_email"]?.stringValue ?? record["customer_email"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }

  private var supportCaseReplyURL: URL? {
    guard let email = supportCaseCustomerEmail else { return nil }
    let shortID = (values["short_id"]?.stringValue ?? record["short_id"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = (values["subject"]?.stringValue ?? record["subject"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tag = shortID.isEmpty ? "" : "[\(shortID)] "
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = email
    components.queryItems = [
      URLQueryItem(name: "cc", value: Self.supportCaseCaptureAddress),
      URLQueryItem(name: "subject", value: "\(tag)Re: \(subject)"),
    ]
    return components.url
  }

  /// To-one `relation` fields worth a rich context banner at the top of the page:
  /// those whose target entity has an avatar identity (organizations, contacts,
  /// milestones). Identity-driven — nothing names "organization", so any such
  /// relation gets a banner automatically.
  private var contextRelationFields: [CRMFieldContract] {
    contract.fields.filter { field in
      guard field.kind == "relation", let entity = field.relationEntity,
        let target = allContracts.first(where: { $0.id == entity })
      else { return false }
      return CRMEntityIdentity.resolve(target).showsAvatar
    }
  }

  private var usesCenteredHeader: Bool {
    identity.usesCenteredHeader
  }

  private var showsAvatar: Bool {
    usesCenteredHeader || record.avatarURL != nil
  }

  /// Fields folded into another control (birthday parts) or already shown by the
  /// centered header. In editable mode we keep the header's primary/subtitle
  /// fields visible as rows so they remain editable (the name lives in the header
  /// *and* as a field, like Contacts) — only hide them on the read-only surface.
  private var hiddenFieldNames: Set<String> {
    var fields: Set<String> = ["birthday_day", "birthday_year"]
    if !contract.canUpdate && usesCenteredHeader {
      fields.insert(contract.primaryField)
      fields.formUnion(identity.subtitleFields)
      fields.formUnion(identity.imageFields)
      fields.formUnion(identity.svgFields)
    }
    // In read-only mode the context banner fully replaces the raw relation row.
    // When editable, keep the row's Picker so the relation stays reassignable.
    if !contract.canUpdate {
      fields.formUnion(contextRelationFields.map(\.name))
    }
    return fields
  }

  private var headerSubtitle: String? {
    for field in identity.subtitleFields {
      if let value = record[field]?.stringValue,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return nil
  }

  private var centeredHeader: some View {
    VStack(spacing: 8) {
      CachedRemoteAvatar(
        url: record.avatarURL,
        name: title,
        size: 96,
        fallbackSymbol: contract.icon,
        shape: .resolve(entityID: contract.id)
      )
      Text(title)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      if let headerSubtitle {
        Text(headerSubtitle)
          .font(.subheadline)
          .foregroundStyle(crmSecondaryText)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  /// Registry-driven content header. Raster and inline-SVG visuals share one
  /// presentation, so technologies, work, reports, and future CMS types don't
  /// need bespoke detail views.
  private var contentHeroHeader: some View {
    let draft = CRMRecord(fields: values)
    return VStack(spacing: 12) {
      Group {
        if let imageURL = draft.imageURL(for: contract) {
          CachedRemoteImage(url: imageURL, contentMode: .fill)
        } else if let svg = draft.svgMarkup(for: contract) {
          InlineSVGView(svg: svg)
            .padding(16)
            .background(Color.black)
        } else {
          ZStack {
            RoundedRectangle(cornerRadius: EnvisioningRadius.card).fill(EnvisioningSurface.field)
            Image(crmSymbol: contract.icon, fallback: "photo")
              .font(.largeTitle)
              .foregroundStyle(crmSecondaryText)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 220)
      .clipShape(.rect(cornerRadius: EnvisioningRadius.card))

      Text(draft.displayName(primaryField: contract.primaryField, fallback: title))
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      if let headerSubtitle {
        Text(headerSubtitle)
          .font(.subheadline)
          .foregroundStyle(crmSecondaryText)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  // MARK: Dirty tracking & bindings

  private var isDirty: Bool {
    Self.normalizedPayload(for: contract, from: values) != originalPayload
  }

  private var requiredFieldsArePresent: Bool {
    contract.fields.filter {
      $0.required == true && $0.hidden != true && $0.readOnly != true
    }.allSatisfy {
      !(values[$0.name]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func binding(for field: CRMFieldContract) -> Binding<JSONValue> {
    Binding(
      get: { values[field.name] ?? Self.defaultValue(for: field) },
      set: { values[field.name] = $0 }
    )
  }

  private func binding(named name: String) -> Binding<JSONValue> {
    Binding(
      get: { values[name] ?? .string("") },
      set: { values[name] = $0 }
    )
  }

  // MARK: Persistence

  /// List and search envelopes may intentionally be thin. Resolve the full
  /// record when the page opens so every CMS field and its visual are present;
  /// the passed record remains a useful offline fallback.
  private func loadFullRecord() async {
    guard !record.id.isEmpty else { return }
    guard let loaded = try? await repository.record(
      entity: contract.id,
      id: record.id,
      primaryField: contract.primaryField
    ).record, !isDirty else { return }
    apply(loaded)
  }

  private func apply(_ updatedRecord: CRMRecord) {
    let seeded = Self.seededValues(for: contract, from: updatedRecord.fields)
    record = updatedRecord
    values = seeded
    originalValues = seeded
    originalPayload = Self.normalizedPayload(for: contract, from: seeded)
  }

  private func loadRelationOptions() async {
    let entities = Set(contract.fields.compactMap(\.relationEntity))
    for entity in entities {
      let cached = try? await repository.cachedRecords(entity: entity)
      if let cached, !cached.records.isEmpty {
        relationOptions[entity] = cached.records
      }
      if let cached, repository.recordsAreFresh(fetchedAt: cached.fetchedAt) {
        continue
      }
      let primaryField = allContracts.first { $0.id == entity }?.primaryField ?? "name"
      if let records = try? await repository.refreshRecords(
        entity: entity,
        primaryField: primaryField
      ) {
        relationOptions[entity] = records
      }
    }
  }

  private func loadCharacteristicOptions() async {
    characteristicOptions = await Self.characteristicOptions(
      for: contract, repository: repository)
  }

  private func loadMemberOptions() async {
    memberOptions = await Self.memberOptions(
      for: contract, record: record, repository: repository)
  }

  /// The assignable-members list for any `optionsSource: "members"` field, with
  /// the record's current assignee merged in so the picker can label a selection
  /// even for someone no longer in the fetched directory. Empty when the entity
  /// has no members field. Shared by the detail page and the create form.
  static func memberOptions(
    for contract: CRMEntityContract,
    record: CRMRecord?,
    repository: CRMRepository
  ) async -> [CRMMember] {
    guard contract.fields.contains(where: { $0.optionsSource == "members" })
    else { return [] }
    var members = (try? await repository.members()) ?? []
    // Keep the currently-assigned member selectable/labelable even if the
    // server directory no longer lists them (e.g. a departed teammate).
    if let assignee = record?["assignee"]?.objectValue,
      let id = assignee["id"]?.stringValue, !id.isEmpty,
      !members.contains(where: { $0.id == id }) {
      members.insert(
        CRMMember(
          id: id,
          name: assignee["name"]?.stringValue,
          email: assignee["email"]?.stringValue),
        at: 0)
    }
    return members
  }

  /// The characteristics vocabulary for this entity — cached first, then
  /// refreshed. Empty when the entity has no editable `characteristics` field.
  /// Shared by the detail page and the create form.
  static func characteristicOptions(
    for contract: CRMEntityContract,
    repository: CRMRepository
  ) async -> [CRMCharacteristicOption] {
    guard contract.fields.contains(where: {
      $0.kind == "characteristics" && $0.readOnly != true
    }) else { return [] }
    var options: [CRMCharacteristicOption] = []
    if let cached = try? await repository.cachedCharacteristics(),
      let cachedOptions = cached[contract.id], !cachedOptions.isEmpty {
      options = cachedOptions
    }
    if let vocabulary = try? await repository.refreshCharacteristics(),
      let fresh = vocabulary[contract.id] {
      options = fresh
    }
    return options
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await repository.save(
        entity: contract.id,
        id: record.id,
        values: Self.normalizedPayload(for: contract, from: values),
        primaryField: contract.primaryField
      )
      apply(saved)
      onToast("\(contract.singularLabel) updated")
      onChanged()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteRecord() async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await repository.delete(
        entity: contract.id,
        id: record.id,
        primaryField: contract.primaryField
      )
      onToast("\(contract.singularLabel) deleted")
      onChanged()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyMergedContact(_ survivor: CRMRecord) {
    apply(survivor)
    onToast("Contacts merged")
    onChanged()
  }

  // MARK: Seeding & normalization (shared with the create form)

  /// Seed defaults for controls that need a concrete starting value, without
  /// overwriting any value the record already carries.
  static func seededValues(
    for contract: CRMEntityContract,
    from source: [String: JSONValue]
  ) -> [String: JSONValue] {
    var values = source
    for field in contract.fields where field.hidden != true {
      guard values[field.name] == nil else { continue }
      switch field.kind {
      case "toggle": values[field.name] = .bool(false)
      case "select": values[field.name] = .string(field.options?.first?.value ?? "")
      case "multiRelation": values[field.name] = .array([])
      case "characteristics": values[field.name] = .object([:])
      case "date" where field.required == true:
        values[field.name] = .string(dateString(from: Date()))
      case "datetime" where field.required == true:
        values[field.name] = .string(ISO8601DateFormatter().string(from: Date()))
      default: break
      }
    }
    return values
  }

  /// The server-bound payload: only editable, visible fields; empty optionals and
  /// cleared relations collapse to `.null`. Also the canonical shape for dirty
  /// comparison, so a no-op edit never reads as dirty.
  static func normalizedPayload(
    for contract: CRMEntityContract,
    from values: [String: JSONValue]
  ) -> [String: JSONValue] {
    Dictionary(uniqueKeysWithValues: contract.fields.compactMap { field in
      guard field.kind != "section", field.hidden != true, field.readOnly != true,
        let value = values[field.name]
      else { return nil }
      if field.kind == "relation", value.stringValue == "" {
        return (field.name, .null)
      }
      // Assignee only applies to team-owned tasks; clear it otherwise so a stale
      // pick made while "Envisioning" doesn't persist once the party changes —
      // matches the web form, which resets "Assigned To" off the team.
      if field.optionsSource == "members",
        (values["responsible_party"]?.stringValue ?? "") != "team" {
        return (field.name, .null)
      }
      if field.required != true, value.stringValue == "" {
        return (field.name, .null)
      }
      return (field.name, value)
    })
  }

  static func defaultValue(for field: CRMFieldContract) -> JSONValue {
    if field.kind == "toggle" { return .bool(false) }
    if field.kind == "select" { return .string(field.options?.first?.value ?? "") }
    if field.kind == "multiRelation" { return .array([]) }
    if field.kind == "characteristics" { return .object([:]) }
    return .string("")
  }

  static func dateString(from date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}

/// Gray system metadata shown at the very bottom of every entity detail page —
/// creation / last-updated timestamps and the record id. These live in the raw
/// record JSON even when they aren't declared as editable fields. Any key that
/// *is* a visible field on this entity is skipped to avoid duplicate rows.
private struct RecordMetadataFooter: View {
  let record: CRMRecord
  let contract: CRMEntityContract

  private static let timestampKeys: [(key: String, label: String)] = [
    ("created_at", "Created"),
    ("updated_at", "Updated"),
  ]

  private var declaredFieldNames: Set<String> {
    Set(contract.fields.filter { $0.hidden != true && $0.kind != "section" }.map(\.name))
  }

  private var rows: [(label: String, value: String)] {
    var result = Self.timestampKeys.compactMap { entry -> (String, String)? in
      guard !declaredFieldNames.contains(entry.key),
        let formatted = formattedTimestamp(for: entry.key)
      else { return nil }
      return (entry.label, formatted)
    }
    if !record.id.isEmpty {
      result.append(("ID", record.id))
    }
    return result
  }

  var body: some View {
    if !rows.isEmpty {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(rows, id: \.label) { row in
            HStack(spacing: 6) {
              Text(row.label)
              Text(row.value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .font(.caption)
        .foregroundStyle(crmSecondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .listRowBackground(Color.clear)
    }
  }

  private func formattedTimestamp(for key: String) -> String? {
    guard let raw = record[key]?.stringValue, !raw.isEmpty else { return nil }
    if let date = Self.parse(raw) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return raw
  }

  private static func parse(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: string) { return date }
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    return dateOnly.date(from: string)
  }
}

private struct LicenseOverviewSection: View {
  let record: CRMRecord

  var body: some View {
    Section("Overview") {
      HStack(spacing: 12) {
        overviewValue("ARR", value: formattedARR, symbol: "eurosign.circle")
        overviewValue("Seats", value: seats, symbol: "person.2")
      }
      LabeledContent("Status") {
        Label(isActive ? "Active" : "Inactive", systemImage: isActive ? "checkmark.circle.fill" : "pause.circle.fill")
          .foregroundStyle(isActive ? Color.green : crmSecondaryText)
      }
      if let renewal = record["renewal_date"]?.stringValue {
        LabeledContent("Renewal", value: renewal)
      }
    }
  }

  private func overviewValue(_ label: String, value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(label.uppercased(), systemImage: symbol)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(crmSecondaryText)
      Text(value).font(.title3.weight(.semibold)).contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(EnvisioningSurface.field, in: .rect(cornerRadius: EnvisioningRadius.field))
  }

  private var formattedARR: String {
    let amount: Double
    switch record["amount_eur"] {
    case .number(let value): amount = value
    case .string(let value): amount = Double(value) ?? 0
    default: amount = 0
    }
    return amount.formatted(.currency(code: "EUR").precision(.fractionLength(0)))
  }

  private var seats: String {
    record["seats"]?.stringValue?.replacingOccurrences(of: ".0", with: "") ?? "—"
  }

  private var isActive: Bool {
    record["is_active"]?.boolValue ?? false
  }
}

/// The record-creation modal. Create stays a sheet (conventional on iOS), but it
/// renders fields through the same `EntityFieldRow` as the detail page, so
/// create / edit / view are one renderer.
struct DynamicEntityFormView: View {
  @Environment(\.dismiss) private var dismiss

  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let record: CRMRecord?
  let onSaved: ((CRMRecord) async throws -> Void)?
  let onCompleted: (String) -> Void

  @State private var values: [String: JSONValue]
  @State private var preferredLanguageEdited = false
  @State private var relationOptions: [String: [CRMRecord]] = [:]
  @State private var characteristicOptions: [CRMCharacteristicOption] = []
  @State private var memberOptions: [CRMMember] = []
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false

  init(
    contract: CRMEntityContract,
    allContracts: [CRMEntityContract],
    repository: CRMRepository,
    record: CRMRecord? = nil,
    initialValues prefilledValues: [String: JSONValue] = [:],
    onSaved: ((CRMRecord) async throws -> Void)? = nil,
    onCompleted: @escaping (String) -> Void
  ) {
    self.contract = contract
    self.allContracts = allContracts
    self.repository = repository
    self.record = record
    self.onSaved = onSaved
    self.onCompleted = onCompleted
    _values = State(
      initialValue: EntityDetailView.seededValues(
        for: contract, from: record?.fields ?? prefilledValues))
  }

  private var fieldGroups: [EntityFieldGroup] {
    entityFieldGroups(for: contract).compactMap { group in
      let fields = group.fields.filter {
        $0.hidden != true
          && !["birthday_day", "birthday_year"].contains($0.name)
          // Assignee only applies to team-owned tasks — hide it until
          // Responsible Party is "Envisioning", mirroring the edit page.
          && !($0.optionsSource == "members"
            && (values["responsible_party"]?.stringValue ?? "") != "team")
      }
      guard !fields.isEmpty else { return nil }
      return EntityFieldGroup(id: group.id, label: group.label, fields: fields)
    }
  }

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        ForEach(fieldGroups) { group in
          Section(group.label) {
            ForEach(group.fields) { field in
              if field.name == "birthday_month" {
                ContactBirthdayEditor(
                  month: binding(named: "birthday_month"),
                  day: binding(named: "birthday_day"),
                  year: binding(named: "birthday_year")
                )
              } else {
                EntityFieldRow(
                  field: field,
                  value: binding(for: field),
                  record: CRMRecord(fields: values),
                  isEditable: true,
                  relationOptions: relationOptions[field.relationEntity ?? ""] ?? [],
                  characteristicOptions: characteristicOptions,
                  memberOptions: memberOptions,
                  entityID: contract.id
                )
              }
            }
          }
        }

        if record != nil && contract.canDelete {
          Section {
            Button("Delete \(contract.singularLabel)", role: .destructive) {
              showingDeleteConfirmation = true
            }
          }
        }
      }
      .navigationTitle(record == nil ? "New \(contract.singularLabel)" : contract.singularLabel)
      .navigationBarTitleDisplayMode(.inline)
      .disabled(isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(isSaving || !requiredFieldsArePresent)
        }
      }
      .overlay { if isSaving { ProgressView().controlSize(.large) } }
    }
    .task { await loadRelationOptions() }
    .task {
      characteristicOptions = await EntityDetailView.characteristicOptions(
        for: contract, repository: repository)
    }
    .task {
      memberOptions = await EntityDetailView.memberOptions(
        for: contract, record: record, repository: repository)
    }
    .confirmationDialog(
      "Delete this \(contract.singularLabel.lowercased())?",
      isPresented: $showingDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { Task { await deleteRecord() } }
    }
    .alert("Unable to Save", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
    .sensoryFeedback(.error, trigger: errorMessage)
    .crmFormSheetSizing()
  }

  private var requiredFieldsArePresent: Bool {
    contract.fields.filter {
      $0.required == true && $0.hidden != true && $0.readOnly != true
    }.allSatisfy {
      !(values[$0.name]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func binding(for field: CRMFieldContract) -> Binding<JSONValue> {
    Binding(
      get: { values[field.name] ?? EntityDetailView.defaultValue(for: field) },
      set: { newValue in
        values[field.name] = newValue
        // Track manual edits to the language field so the country-driven default
        // below stops steering it once the user has chosen deliberately.
        if field.name == "preferred_language" { preferredLanguageEdited = true }
        // Contacts in Brazil/Portugal default to Portuguese for Signals outreach.
        // The registry can't express a default that depends on another field, so
        // while the user hasn't touched the language field, it tracks the country.
        // Mirrored in the web app's UnifiedForm; keep the two in sync.
        if field.name == "country", record == nil, !preferredLanguageEdited,
          contract.fields.contains(where: { $0.name == "preferred_language" }) {
          let code = CountryCatalog.country(forStoredValue: newValue.stringValue ?? "")?.code
          values["preferred_language"] = .string(code == "BR" || code == "PT" ? "pt" : "en")
        }
      }
    )
  }

  private func binding(named name: String) -> Binding<JSONValue> {
    Binding(
      get: { values[name] ?? .string("") },
      set: { values[name] = $0 }
    )
  }

  private func loadRelationOptions() async {
    let entities = Set(contract.fields.compactMap(\.relationEntity))
    for entity in entities {
      let cached = try? await repository.cachedRecords(entity: entity)
      if let cached, !cached.records.isEmpty {
        relationOptions[entity] = cached.records
      }
      if let cached, repository.recordsAreFresh(fetchedAt: cached.fetchedAt) {
        continue
      }
      let primaryField = allContracts.first { $0.id == entity }?.primaryField ?? "name"
      if let records = try? await repository.refreshRecords(
        entity: entity,
        primaryField: primaryField
      ) {
        relationOptions[entity] = records
      }
    }
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await repository.save(
        entity: contract.id,
        id: record?.id,
        values: EntityDetailView.normalizedPayload(for: contract, from: values),
        primaryField: contract.primaryField
      )
      try await onSaved?(saved)
      onCompleted(
        record == nil
          ? "\(contract.singularLabel) created"
          : "\(contract.singularLabel) updated"
      )
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteRecord() async {
    guard let record else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      try await repository.delete(
        entity: contract.id,
        id: record.id,
        primaryField: contract.primaryField
      )
      onCompleted("\(contract.singularLabel) deleted")
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct ContactBirthdayEditor: View {
  @Binding var month: JSONValue
  @Binding var day: JSONValue
  @Binding var year: JSONValue

  var body: some View {
    Picker("Month", selection: monthBinding) {
      Text("Not set").tag(0)
      ForEach(1...12, id: \.self) { value in
        Text(monthName(value)).tag(value)
      }
    }

    Picker("Day", selection: dayBinding) {
      Text("Not set").tag(0)
      ForEach(1...maximumDay, id: \.self) { value in
        Text(String(value)).tag(value)
      }
    }
    .disabled(monthInteger == nil)

    TextField("Year (optional)", text: yearBinding)
      .keyboardType(.numberPad)
      .disabled(dayInteger == nil)

    if let birthday = formattedBirthday {
      LabeledContent("Saved as", value: birthday)
    }

    if monthInteger != nil {
      Button("Clear Birthday", role: .destructive) {
        month = .null
        day = .null
        year = .null
      }
    }
  }

  private var monthInteger: Int? { integer(month) }
  private var dayInteger: Int? { integer(day) }
  private var yearInteger: Int? { integer(year) }

  private var maximumDay: Int {
    guard let monthInteger else { return 31 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(
      from: DateComponents(year: yearInteger ?? 2000, month: monthInteger, day: 1)
    )!
    return calendar.range(of: .day, in: .month, for: date)?.count ?? 31
  }

  private var monthBinding: Binding<Int> {
    Binding(
      get: { monthInteger ?? 0 },
      set: { value in
        if value == 0 {
          month = .null
          day = .null
          year = .null
          return
        }
        month = .number(Double(value))
        if let dayInteger, dayInteger > maximumDay { day = .null }
      }
    )
  }

  private var dayBinding: Binding<Int> {
    Binding(
      get: { dayInteger ?? 0 },
      set: { day = $0 == 0 ? .null : .number(Double($0)) }
    )
  }

  private var yearBinding: Binding<String> {
    Binding(
      get: { yearInteger.map(String.init) ?? "" },
      set: { input in
        let digits = String(input.filter(\.isNumber).prefix(4))
        if digits.isEmpty {
          year = .null
          return
        }
        guard let value = Int(digits) else { return }
        year = .number(Double(value))
        if let dayInteger, dayInteger > maximumDay { day = .null }
      }
    )
  }

  private var formattedBirthday: String? {
    CRMContactBirthday(record: CRMRecord(fields: [
      "birthday_month": month,
      "birthday_day": day,
      "birthday_year": year,
    ]))?.formatted()
  }

  private func integer(_ value: JSONValue) -> Int? {
    switch value {
    case .number(let number) where number.rounded() == number: Int(number)
    case .string(let string): Int(string)
    default: nil
    }
  }

  private func monthName(_ month: Int) -> String {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.month = month
    components.day = 1
    components.year = 2000
    return components.date?.formatted(.dateTime.month(.wide)) ?? String(month)
  }
}

/// The single renderer for one field, for both viewing and editing. When
/// `isEditable` is false (or the field is `readOnly`) it renders the rich
/// read-only display via `crmDisplayValue`; otherwise it renders the field's
/// live control. This is the one code path per field kind — do not split it back
/// into separate read/edit renderers.
struct EntityFieldRow: View {
  let field: CRMFieldContract
  @Binding var value: JSONValue
  let record: CRMRecord
  let isEditable: Bool
  let relationOptions: [CRMRecord]
  var characteristicOptions: [CRMCharacteristicOption] = []
  var memberOptions: [CRMMember] = []
  /// Owning entity, for the few presentation rules that are entity-specific
  /// (see `imageBackdrop`). Defaulted so create/edit call sites that don't
  /// care stay unchanged.
  var entityID: String = ""

  /// SVG marks are light-on-transparent throughout this CMS, so they always
  /// sit on black — same as the web app. Not entity-specific.
  private let svgBackdrop = Color.black

  /// Raster art keeps the form background, except research hub logos, which
  /// are light-on-transparent like the SVG marks.
  private var imageBackdrop: Color { entityID == "research" ? .black : .clear }

  /// Markdown shows rendered until tapped. Kept separate from `markdownFocused`
  /// because the editor has to exist before it can take focus.
  @State private var isEditingMarkdown = false
  @FocusState private var markdownFocused: Bool
  @Environment(\.crmOpenRelated) private var openRelated

  var body: some View {
    if !isEditable || field.readOnly == true {
      readOnlyRow
    } else {
      editableField
    }
  }

  /// Navigable targets for a populated relation / multiRelation field: the
  /// linked record(s), so the row can offer an "open" affordance beside its
  /// (still-editable) picker. Empty when there's no value or no open handler.
  private var relationTargets: [CRMRelatedTarget] {
    guard openRelated.isEnabled, let entity = field.relationEntity else { return [] }
    switch field.kind {
    case "relation":
      guard let id = value.stringValue, !id.isEmpty else { return [] }
      return [CRMRelatedTarget(entityID: entity, recordID: id, title: crmDisplayValue(for: field, in: record))]
    case "multiRelation":
      let ids = value.arrayValue?.compactMap(\.stringValue) ?? []
      let relationKey = field.relationKey ?? (entity.hasSuffix("s") ? String(entity.dropLast()) : entity)
      let objects = record[relationKey]?.arrayValue?.compactMap(\.objectValue) ?? []
      return ids.map { id in
        let name = objects.first { $0["id"]?.stringValue == id }
          .flatMap { $0["name"]?.stringValue ?? $0["title"]?.stringValue }
        return CRMRelatedTarget(entityID: entity, recordID: id, title: name)
      }
    default:
      return []
    }
  }

  /// A trailing control that opens the linked record(s) — a button for one, a
  /// menu for several. Renders nothing when there's nothing to open.
  @ViewBuilder
  private var relationOpenControl: some View {
    let targets = relationTargets
    if targets.count == 1 {
      Button {
        openRelated(targets[0])
      } label: {
        Image(systemName: "arrow.up.forward.circle")
      }
      .buttonStyle(.borderless)
      .help("Open \(targets[0].title ?? "record")")
      .accessibilityLabel("Open \(targets[0].title ?? "linked record")")
    } else if targets.count > 1 {
      Menu {
        ForEach(targets) { target in
          Button(target.title ?? "Record") { openRelated(target) }
        }
      } label: {
        Image(systemName: "arrow.up.forward.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Open linked record")
    }
  }

  /// Display name for a stored member id (task `assigned_to`), resolved against
  /// the fetched directory and falling back to the record's embedded assignee.
  private var memberDisplayName: String? {
    let id = value.stringValue ?? ""
    guard !id.isEmpty else { return nil }
    if let match = memberOptions.first(where: { $0.id == id }) { return match.displayLabel }
    if let assignee = record["assignee"]?.objectValue,
      assignee["id"]?.stringValue == id {
      return assignee["name"]?.stringValue ?? assignee["email"]?.stringValue
    }
    return record["assignee_name"]?.stringValue
  }

  // MARK: Read-only rendering

  @ViewBuilder
  private var readOnlyRow: some View {
    let display = crmDisplayValue(for: field, in: record) ?? ""
    if field.optionsSource == "members" {
      // Stored value is a member id; show the resolved name, not the raw uuid.
      LabeledContent(field.label, value: memberDisplayName ?? "—")
    } else if field.kind == "url", !display.isEmpty, let url = URL(string: display) {
      LabeledContent(field.label) {
        Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }
      }
    } else if field.kind == "email", !display.isEmpty,
      let encoded = display.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "mailto:\(encoded)") {
      LabeledContent(field.label) { Link(display, destination: url) }
    } else if field.kind == "relation" || field.kind == "multiRelation", !relationTargets.isEmpty {
      // A read-only relation still opens to its target — value plus an open
      // affordance, no picker.
      LabeledContent(field.label) {
        HStack(spacing: 8) {
          Text(display.isEmpty ? "—" : display)
            .foregroundStyle(crmSecondaryText)
            .lineLimit(1)
          relationOpenControl
        }
      }
    } else if field.kind == "markdown", !display.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label).font(.caption).foregroundStyle(crmSecondaryText)
        MarkdownText(markdown: display)
          .textSelection(.enabled)
      }
      .padding(.vertical, 4)
    } else if field.kind == "textarea" || field.kind == "markdown" {
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label).font(.caption).foregroundStyle(crmSecondaryText)
        Text(display.isEmpty ? "—" : display)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 4)
    } else if field.kind == "characteristics" {
      let names = selectedCharacteristicNames
      VStack(alignment: .leading, spacing: 8) {
        Text(field.label).font(.caption).foregroundStyle(crmSecondaryText)
        if names.isEmpty {
          Text("—").foregroundStyle(crmSecondaryText)
        } else {
          TagChips(tags: names.map(characteristicDisplayName))
        }
      }
      .padding(.vertical, 4)
    } else if field.kind == "image", !display.isEmpty, let url = URL(string: display) {
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label).font(.caption).foregroundStyle(crmSecondaryText)
        CachedRemoteImage(url: url)
          .frame(maxWidth: .infinity, maxHeight: 160, alignment: .leading)
          .background(imageBackdrop)
          .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
      }
      .padding(.vertical, 4)
    } else if field.kind == "svg", !display.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(field.label).font(.caption).foregroundStyle(crmSecondaryText)
        InlineSVGView(svg: display)
          .frame(height: 120)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(svgBackdrop)
          .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
      }
      .padding(.vertical, 4)
    } else {
      LabeledContent(field.label, value: display.isEmpty ? "—" : display)
    }
  }

  /// Names of the "on" characteristics for a `{ name: Bool }` map value,
  /// alphabetized. Tolerates the legacy array-of-strings shape.
  private var selectedCharacteristicNames: [String] {
    switch value {
    case .object(let map):
      return map.compactMap { key, value in value.boolValue == true ? key : nil }.sorted()
    case .array(let items):
      return items.compactMap(\.stringValue).sorted()
    default:
      return []
    }
  }

  // MARK: Editable rendering
  //
  // Invariant: a field's `label` is rendered exactly once, by one of two
  // mechanisms — never by a raw control's title argument (which SwiftUI does
  // not draw for `TextField`/`TextEditor` on iOS). Every case below either:
  //   1. uses a SwiftUI control that natively lays out the label (Toggle,
  //      Picker, DatePicker) or a custom control that takes an explicit
  //      `label:`, or
  //   2. wraps a raw editor in `labeledRow` (compact, label leading — mirrors
  //      the read surface's `LabeledContent`) or `labeledStack` (multi-line,
  //      label above the editor).
  // The `default` branch already routes through `labeledRow`, so a new/unknown
  // field kind gets a visible label for free and this can't silently regress.

  /// Compact inputs: label leading, control trailing. Matches how the read
  /// surface renders the same field via `LabeledContent`, so edit and view stay
  /// visually aligned.
  private func labeledRow<Control: View>(
    @ViewBuilder _ control: () -> Control
  ) -> some View {
    LabeledContent(field.label) { control() }
  }

  /// Large multi-line editors: label above the editor.
  private func labeledStack<Control: View>(
    @ViewBuilder _ control: () -> Control
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(field.label).font(.subheadline).foregroundStyle(crmSecondaryText)
      control()
    }
  }

  /// The rendered face of an editable markdown field. Tapping anywhere on it —
  /// including the empty placeholder — reveals the source editor.
  @ViewBuilder
  private var markdownPreview: some View {
    let text = stringBinding.wrappedValue
    Group {
      if text.isEmpty {
        Text(field.placeholder ?? "Tap to edit").foregroundStyle(.tertiary)
      } else {
        MarkdownText(markdown: text)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .onTapGesture { isEditingMarkdown = true }
  }

  @ViewBuilder
  private var editableField: some View {
    switch field.kind {
    case "toggle":
      Toggle(field.label, isOn: boolBinding)
        .tint(.accentColor)
    case "select" where field.optionsSource == "members":
      // Members come from `/api/agent/members`, not inline options. "Unassigned"
      // is the empty tag so a team task can be team-owned yet unassigned.
      Picker(field.label, selection: stringBinding) {
        Text("Unassigned").tag("")
        ForEach(memberOptions) { member in
          Text(member.displayLabel).tag(member.id)
        }
      }
    case "select":
      Picker(field.label, selection: stringBinding) {
        ForEach(field.options ?? []) { option in
          Text(option.label).tag(option.value)
        }
      }
    case "country":
      CountryPickerField(label: field.label, value: $value, placeholder: field.placeholder)
    case "industry":
      // The registry ships no option list for industries (codes arrive as
      // `ent_<slug>`), so there's nothing to pick from client-side. Show the
      // humanized label as a picker when the server *does* publish options,
      // otherwise render the label read-only rather than exposing the raw code
      // in an editable text box.
      if let options = field.options, !options.isEmpty {
        Picker(field.label, selection: stringBinding) {
          Text("None").tag("")
          ForEach(options) { option in Text(option.label).tag(option.value) }
        }
      } else {
        LabeledContent(
          field.label,
          value: (value.stringValue?.isEmpty == false)
            ? CRMFieldContract.industryLabel(for: value.stringValue ?? "")
            : "—"
        )
      }
    case "relation":
      LabeledContent(field.label) {
        HStack(spacing: 8) {
          Picker(field.label, selection: stringBinding) {
            Text("None").tag("")
            ForEach(relationOptions) { record in
              Text(
                record["name"]?.stringValue
                  ?? record["title"]?.stringValue
                  ?? record.id
              ).tag(record.id)
            }
          }
          .labelsHidden()
          relationOpenControl
        }
      }
    case "multiRelation":
      HStack(spacing: 8) {
        MultiRelationPicker(
          label: field.label,
          value: $value,
          options: relationOptions
        )
        relationOpenControl
      }
    case "stringList":
      labeledStack {
        TextEditor(text: stringListBinding)
          .frame(minHeight: 90)
      }
    case "date":
      DatePicker(field.label, selection: dateBinding, displayedComponents: .date)
    case "datetime":
      DatePicker(
        field.label,
        selection: dateTimeBinding,
        displayedComponents: [.date, .hourAndMinute]
      )
    case "number":
      labeledRow {
        TextField("", text: stringBinding, prompt: Text(field.placeholder ?? ""))
          .keyboardType(.decimalPad)
          .crmFieldValueAlignment()
      }
    case "email":
      labeledRow {
        HStack(spacing: 8) {
          TextField("", text: stringBinding, prompt: Text(field.placeholder ?? ""))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .crmFieldValueAlignment()
          if let action = mailtoURL {
            Link(destination: action) { Image(systemName: "envelope") }
              .buttonStyle(.plain)
          }
        }
      }
    case "url":
      labeledRow {
        HStack(spacing: 8) {
          TextField("", text: stringBinding, prompt: Text(field.placeholder ?? ""))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .crmFieldValueAlignment()
          if let action = webURL {
            Link(destination: action) { Image(systemName: "arrow.up.right.square") }
              .buttonStyle(.plain)
          }
        }
      }
    case "markdown":
      // iOS: rendered until tapped, then the raw editor — the always-live
      // equivalent for a field whose formatting is the point of reading it
      // (deferred commit still applies; tapping only reveals the source).
      // macOS: the tap-to-reveal affordance is invisible with a pointer, so the
      // source editor is shown directly, like `textarea`.
      labeledStack {
        #if os(macOS)
          TextEditor(text: stringBinding)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 160)
        #else
          if isEditingMarkdown {
            TextEditor(text: stringBinding)
              .frame(minHeight: 120)
              .focused($markdownFocused)
              .onAppear { markdownFocused = true }
              .onChange(of: markdownFocused) { _, focused in
                if !focused { isEditingMarkdown = false }
              }
          } else {
            markdownPreview
          }
        #endif
      }
    case "textarea":
      labeledStack {
        TextEditor(text: stringBinding)
          .frame(minHeight: 120)
      }
    case "image":
      labeledStack {
        if let url = webURL {
          CachedRemoteImage(url: url)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(imageBackdrop)
            .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
        }
        TextField("", text: stringBinding, prompt: Text(field.placeholder ?? "Image URL"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
      }
    case "svg":
      labeledStack {
        if let svg = value.stringValue, !svg.isEmpty {
          InlineSVGView(svg: svg)
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(svgBackdrop)
            .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
        }
        TextEditor(text: stringBinding)
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 120)
      }
    case "characteristics":
      CharacteristicPillPicker(
        label: field.label,
        value: $value,
        options: characteristicOptions
      )
    case "readOnly":
      LabeledContent(field.label, value: value.stringValue ?? "—")
    default:
      labeledRow {
        TextField("", text: stringBinding, prompt: Text(field.placeholder ?? ""))
          .textInputAutocapitalization(field.kind == "email" || field.kind == "url" ? .never : .sentences)
          .autocorrectionDisabled(field.kind == "email" || field.kind == "url")
          .keyboardType(field.kind == "email" ? .emailAddress : field.kind == "url" ? .URL : .default)
          .crmFieldValueAlignment()
      }
    }
  }

  // MARK: Field action affordances

  private var mailtoURL: URL? {
    guard let raw = value.stringValue, !raw.isEmpty,
      let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { return nil }
    return URL(string: "mailto:\(encoded)")
  }

  private var webURL: URL? {
    guard let raw = value.stringValue, !raw.isEmpty else { return nil }
    return URL(string: raw)
  }

  // MARK: Bindings

  private var stringBinding: Binding<String> {
    Binding(
      get: { value.stringValue ?? "" },
      set: { newValue in
        value = .string(field.maxLength.map { String(newValue.prefix($0)) } ?? newValue)
      }
    )
  }

  private var stringListBinding: Binding<String> {
    Binding(
      get: { value.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? "" },
      set: { text in
        value = .array(
          text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { .string($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !($0.stringValue ?? "").isEmpty }
        )
      }
    )
  }

  private var boolBinding: Binding<Bool> {
    Binding(
      get: { value.boolValue ?? false },
      set: { value = .bool($0) }
    )
  }

  private var dateBinding: Binding<Date> {
    Binding(
      get: {
        let parts = (value.stringValue ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(
          from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        ) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        value = .string(String(
          format: "%04d-%02d-%02d",
          components.year ?? 0,
          components.month ?? 0,
          components.day ?? 0
        ))
      }
    )
  }

  private var dateTimeBinding: Binding<Date> {
    Binding(
      get: {
        guard let raw = value.stringValue else { return Date() }
        return ISO8601DateFormatter().date(from: raw) ?? Date()
      },
      set: { value = .string(ISO8601DateFormatter().string(from: $0)) }
    )
  }
}

private let crmDateOnlyFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

/// The formatted, human-facing string for a field's stored value — relation
/// names, option labels, country names, currency, and dates all resolve here.
/// Single source for read display, used by `EntityFieldRow` and for deciding
/// whether a read-only field is empty (and should be hidden).
func crmDisplayValue(for field: CRMFieldContract, in record: CRMRecord) -> String? {
  if (field.kind == "relation" || field.kind == "multiRelation"),
    let relationEntity = field.relationEntity {
    let relationKey = field.relationKey ?? (relationEntity.hasSuffix("s")
      ? String(relationEntity.dropLast())
      : relationEntity)
    if field.kind == "multiRelation" {
      let related = record[relationKey]?.arrayValue ?? []
      let labels = related.compactMap { item -> String? in
        let object = item.objectValue
        return object?["name"]?.stringValue ?? object?["title"]?.stringValue
      }
      if !labels.isEmpty { return labels.joined(separator: ", ") }
    } else if let relation = record[relationKey]?.objectValue {
      return relation["name"]?.stringValue ?? relation["title"]?.stringValue
    }
  }

  guard let value = record[field.name] else { return nil }
  switch value {
  case .bool(let enabled): return enabled ? "Yes" : "No"
  case .number(let number):
    if field.name == "amount_eur" {
      return number.formatted(.currency(code: "EUR"))
    }
    if field.name == "total_amount" {
      let currency = record["currency"]?.stringValue ?? "EUR"
      return number.formatted(.currency(code: currency))
    }
    return number.formatted()
  case .string(let string):
    if let option = field.options?.first(where: { $0.value == string }) {
      return option.label
    }
    if field.kind == "country", let country = CountryCatalog.country(forStoredValue: string) {
      return country.name
    }
    if field.kind == "industry" {
      return CRMFieldContract.industryLabel(for: string)
    }
    if field.kind == "date", let date = crmDateOnlyFormatter.date(from: string) {
      return date.formatted(date: .long, time: .omitted)
    }
    if field.kind == "datetime", let date = ISO8601DateFormatter().date(from: string) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return string
  case .array(let values):
    let strings = values.compactMap(\.stringValue)
    return strings.isEmpty ? nil : strings.joined(separator: ", ")
  default: return nil
  }
}

private struct MultiRelationPicker: View {
  let label: String
  @Binding var value: JSONValue
  let options: [CRMRecord]

  var body: some View {
    TypeaheadPicker(
      label: label,
      prompt: "Search",
      options: options.map {
        TypeaheadOption(
          id: $0.id, title: $0["name"]?.stringValue ?? $0["title"]?.stringValue ?? $0.id)
      },
      multiple: true,
      selection: Binding(
        get: { value.arrayValue?.compactMap(\.stringValue) ?? [] },
        set: { value = .array($0.map(JSONValue.string)) }
      )
    )
  }
}

/// Canonical ISO 3166 country list, resolved once from the current runtime.
/// Each entry carries both the alpha-2 `code` and the localized `name`, so the
/// stored-value format (name vs. code) is a one-line change in `CountryPickerField`.
enum CountryCatalog {
  struct Country: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
  }

  /// Alphabetized by localized name. Built from the runtime's ISO regions,
  /// filtered to two-letter codes (countries/territories, excluding the numeric
  /// macro-regions like "World" / continents).
  static let all: [Country] = {
    // Localize names in English to match the web `countries` source, which is
    // not user-locale dependent. Falls back to the raw code if a name is absent.
    let locale = Locale(identifier: "en_US")
    return Locale.Region.isoRegions
      .filter { $0.identifier.count == 2 }
      .map { Country(code: $0.identifier, name: locale.localizedString(forRegionCode: $0.identifier) ?? $0.identifier) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }()

  /// Look up a country by its stored value, matching either the display name or
  /// the alpha-2 code (case-insensitively), so display works regardless of which
  /// format existing records hold.
  static func country(forStoredValue value: String) -> Country? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
      ?? all.first { $0.code.caseInsensitiveCompare(trimmed) == .orderedSame }
  }

  /// Regional-indicator flag emoji for a stored country value, or `nil` if the
  /// value doesn't resolve to a known alpha-2 region.
  static func flag(forStoredValue value: String) -> String? {
    guard let code = country(forStoredValue: value)?.code else { return nil }
    let base: UInt32 = 127397  // 0x1F1E6 ('🇦') minus ASCII 'A'
    var scalars = String.UnicodeScalarView()
    for scalar in code.uppercased().unicodeScalars {
      guard let flagScalar = Unicode.Scalar(base + scalar.value) else { return nil }
      scalars.append(flagScalar)
    }
    return String(scalars)
  }
}

/// Country typeahead, used for every `country`-kind field across all
/// entities. Stores the ISO alpha-2 code as the value (what the web CRM
/// expects, since it derives the flag from the two characters); reads accept
/// either code or name via `CountryCatalog`, so a legacy freeform value still
/// shows and is replaced on the next pick.
private struct CountryPickerField: View {
  let label: String
  @Binding var value: JSONValue
  let placeholder: String?

  private static let options = CountryCatalog.all.map {
    TypeaheadOption(id: $0.code, title: $0.name)
  }

  var body: some View {
    TypeaheadPicker(
      label: label,
      prompt: placeholder ?? "Search countries",
      options: Self.options,
      multiple: false,
      selection: Binding(
        get: {
          let stored = value.stringValue ?? ""
          if let country = CountryCatalog.country(forStoredValue: stored) { return [country.code] }
          return stored.isEmpty ? [] : [stored]
        },
        set: { value = $0.first.map(JSONValue.string) ?? .string("") }
      )
    )
  }
}

/// A left-to-right wrapping layout used for tag/characteristic chips.
private struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widestRow: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      widestRow = max(widestRow, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxWidth == .infinity ? widestRow : maxWidth, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

/// Read-only display of a list of tags as capsule chips.
private struct TagChips: View {
  let tags: [String]

  var body: some View {
    if tags.isEmpty {
      Text("—").foregroundStyle(crmSecondaryText)
    } else {
      FlowLayout(spacing: 6) {
        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
          Text(tag)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(EnvisioningSurface.elevated, in: .capsule)
        }
      }
    }
  }
}

/// Underscore-aware, title-cased label for a raw characteristic name
/// (`event_timeline` → `Event Timeline`) — mirrors the web display.
func characteristicDisplayName(_ name: String) -> String {
  CRMCharacteristicOption.displayName(for: name)
}

/// Editable pill set for a configurable `characteristics` map
/// (`JSONValue.object` of `{ name: Bool }`). Tapping a pill toggles its name on
/// or off; the vocabulary comes from `/api/agent/meta/characteristics`. Any
/// selected name whose option was since removed from the config still appears
/// so it can be turned off.
private struct CharacteristicPillPicker: View {
  let label: String
  @Binding var value: JSONValue
  let options: [CRMCharacteristicOption]

  private var selection: [String: Bool] {
    value.objectValue?.compactMapValues(\.boolValue) ?? [:]
  }

  private var pillNames: [String] {
    var names = options.map(\.name)
    let known = Set(names)
    for name in selection.filter(\.value).keys.sorted() where !known.contains(name) {
      names.append(name)
    }
    return names
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.subheadline).foregroundStyle(crmSecondaryText)
      if pillNames.isEmpty {
        Text("No characteristics configured")
          .font(.callout)
          .foregroundStyle(crmSecondaryText)
      } else {
        FlowLayout(spacing: 6) {
          ForEach(pillNames, id: \.self) { name in
            let isOn = selection[name] == true
            Button {
              toggle(name)
            } label: {
              Text(characteristicDisplayName(name))
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                  isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(EnvisioningSurface.elevated),
                  in: .capsule
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func toggle(_ name: String) {
    var map = value.objectValue ?? [:]
    let isOn = map[name]?.boolValue == true
    map[name] = .bool(!isOn)
    value = .object(map)
  }
}
