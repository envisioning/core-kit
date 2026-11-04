import CoreKit
import SwiftUI

/// A rich, tappable banner for a to-one relation, shown at the top of a record's
/// detail page — e.g. the organization a contact belongs to. Renders a mini
/// profile of the related entity (logo, name, a subtitle from its secondary
/// fields, relationship flags, and a labeled row for every other populated
/// field), then navigates to that entity's full detail page on tap.
///
/// Registry/identity-driven and generic: nothing here names "organization". Every
/// value comes from the *target* entity's own contract via `crmDisplayValue`, so
/// any to-one relation to an avatar-identity entity lights up for free. Fails
/// closed — no read access renders a non-navigable banner; an unset relation
/// renders nothing.
struct RelationContextCard: View {
  let field: CRMFieldContract
  let sourceRecord: CRMRecord
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let onToast: (String) -> Void
  let onChanged: () -> Void

  @Environment(\.crmOpenRelated) private var crmOpenRelated

  /// The fully-fetched target record, once loaded. Until then the card renders
  /// from the embedded relation object (or a bare id), then hydrates.
  @State private var resolved: CRMRecord?

  var body: some View {
    if let target = targetContract, let recordID, let display = displayRecord {
      Section {
        Group {
          if crmOpenRelated.isEnabled && target.hasReadAccess {
            Button {
              crmOpenRelated(CRMRelatedTarget(
                entityID: target.id, recordID: recordID, title: name(display, target)))
            } label: {
              card(target: target, record: display)
            }
            .buttonStyle(.plain)
          } else {
            card(target: target, record: display)
          }
        }
        .task(id: recordID) {
          if target.hasReadAccess { await load(target: target, id: recordID) }
        }
      } header: {
        Text(field.label)
      }
    }
  }

  // MARK: Card content

  @ViewBuilder
  private func card(target: CRMEntityContract, record: CRMRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 14) {
        CachedRemoteAvatar(
          url: record.avatarURL,
          name: name(record, target),
          size: 52,
          fallbackSymbol: target.icon,
          shape: .resolve(entityID: target.id)
        )
        VStack(alignment: .leading, spacing: 3) {
          Text(name(record, target))
            .font(.headline)
            .lineLimit(1)
          if let subtitle = subtitle(target: target, record: record) {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(crmSecondaryText)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }

      let flags = relationshipFlags(target: target, record: record)
      if !flags.isEmpty {
        HStack(spacing: 14) {
          ForEach(flags, id: \.self) { flag in
            Label(flag, systemImage: "checkmark.seal.fill")
              .font(.caption)
              .foregroundStyle(Color.primary)
          }
        }
      }

      let rows = detailRows(target: target, record: record)
      if !rows.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          ForEach(rows) { row in
            if row.isBlock {
              VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.caption).foregroundStyle(crmSecondaryText)
                Text(row.value).font(.subheadline).lineLimit(3)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label).font(.subheadline).foregroundStyle(crmSecondaryText)
                Spacer(minLength: 12)
                Text(row.value)
                  .font(.subheadline)
                  .multilineTextAlignment(.trailing)
                  .lineLimit(2)
              }
            }
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: Field selection & formatting

  private struct DetailRow: Identifiable {
    let id: String
    let label: String
    let value: String
    /// Multi-line fields (notes, long text) render stacked; the rest key/value.
    let isBlock: Bool
  }

  /// The one-line subtitle under the name, built from the target's
  /// `secondaryFields` (e.g. "Software · 🇩🇪 Germany").
  private func subtitle(target: CRMEntityContract, record: CRMRecord) -> String? {
    let parts = target.secondaryFields.compactMap { name -> String? in
      target.fields.first { $0.name == name }.flatMap { formatted($0, in: record) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Relationship `toggle` fields that are set, as clean labels — `is_partner`
  /// with label "Is Partner" reads better as "Partner".
  private func relationshipFlags(target: CRMEntityContract, record: CRMRecord) -> [String] {
    target.fields
      .filter { $0.kind == "toggle" && record[$0.name]?.boolValue == true }
      .map { $0.label.hasPrefix("Is ") ? String($0.label.dropFirst(3)) : $0.label }
  }

  /// Every remaining populated field, in registry order — everything the card
  /// doesn't already show in the header, subtitle, or flag line, and skipping
  /// structural/image fields. This is the "all useful info" body of the card.
  private func detailRows(target: CRMEntityContract, record: CRMRecord) -> [DetailRow] {
    let shown = Set([target.primaryField] + target.secondaryFields + CRMEntityIdentity.allImageFields)
    return target.fields.compactMap { field in
      guard field.kind != "section", field.kind != "toggle", field.hidden != true,
        !shown.contains(field.name),
        let value = formatted(field, in: record)
      else { return nil }
      let isBlock = ["textarea", "markdown", "stringList"].contains(field.kind)
      return DetailRow(id: field.name, label: field.label, value: value, isBlock: isBlock)
    }
  }

  /// `crmDisplayValue` for a field, with a flag prefix for country values.
  private func formatted(_ field: CRMFieldContract, in record: CRMRecord) -> String? {
    guard let display = crmDisplayValue(for: field, in: record), !display.isEmpty else { return nil }
    if field.kind == "country",
      let flag = CountryCatalog.flag(forStoredValue: record[field.name]?.stringValue ?? "") {
      return "\(flag) \(display)"
    }
    return display
  }

  // MARK: Relation resolution

  private var targetContract: CRMEntityContract? {
    field.relationEntity.flatMap { entity in allContracts.first { $0.id == entity } }
  }

  /// The embedded relation object lives under the singularized relation key —
  /// `organizations` → `organization` — matching `crmDisplayValue`.
  private var relationKey: String {
    if let key = field.relationKey { return key }
    guard let entity = field.relationEntity else { return field.name }
    return entity.hasSuffix("s") ? String(entity.dropLast()) : entity
  }

  private var embedded: CRMRecord? {
    sourceRecord[relationKey]?.objectValue.map(CRMRecord.init(fields:))
  }

  private var recordID: String? {
    if let id = sourceRecord[field.name]?.stringValue, !id.isEmpty { return id }
    if let id = embedded?.id, !id.isEmpty { return id }
    return nil
  }

  /// Best record available to render right now: the fetched one, else the
  /// embedded object, else a bare id placeholder that the fetch will replace.
  private var displayRecord: CRMRecord? {
    if let resolved { return resolved }
    if let embedded { return embedded }
    if let recordID { return CRMRecord(fields: ["id": .string(recordID)]) }
    return nil
  }

  private func name(_ record: CRMRecord, _ target: CRMEntityContract) -> String {
    record.displayName(primaryField: target.primaryField, fallback: target.singularLabel)
  }

  private func load(target: CRMEntityContract, id: String) async {
    guard target.hasReadAccess else { return }
    if let fetched = try? await repository.record(
      entity: target.id,
      id: id,
      primaryField: target.primaryField
    ).record {
      resolved = fetched
    }
  }
}

/// Loads a single record fresh, then shows its `EntityDetailView`. The shared nav
/// destination for any surface that holds an entity id but not the full record —
/// related-section rows and relation context cards both route through here.
struct EntityRecordDetailLoader: View {
  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let recordID: String
  let title: String
  let repository: CRMRepository
  let onToast: (String) -> Void
  let onChanged: () -> Void

  @State private var record: CRMRecord?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let record {
        EntityDetailView(
          contract: contract,
          allContracts: allContracts,
          record: record,
          repository: repository,
          onToast: onToast,
          onChanged: onChanged
        )
      } else if let errorMessage {
        ContentUnavailableView(
          "Unable to Load",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
      } else {
        ProgressView()
      }
    }
    .navigationTitle(title)
    .task {
      do {
        record = try await repository.record(
          entity: contract.id,
          id: recordID,
          primaryField: contract.primaryField
        ).record
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
