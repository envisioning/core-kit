import CoreKit
import Foundation
import EnvisioningUI
import SwiftUI

struct ContactMergeSheet: View {
  private struct MergeConflict: Identifiable {
    let label: String
    let kept: String
    var id: String { label }
  }

  let contact: CRMRecord
  let repository: CRMRepository
  let onMerged: (CRMRecord) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var candidates: [CRMRecord] = []
  @State private var selectedID: String?
  @State private var searchText = ""
  @State private var isLoading = true
  @State private var isMerging = false
  @State private var showingConfirmation = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      EnvisioningList {
        Section("Current Contact") {
          contactRow(contact, selected: false)
        }

        if let selectedContact {
          Section("Merge Preview") {
            LabeledContent("Surviving contact", value: displayName(survivor(contact, selectedContact)))
            LabeledContent("Email identities", value: String(retainedEmails.count))
            if !retainedEmails.isEmpty {
              Text(retainedEmails.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(crmSecondaryText)
            }
            if conflicts.isEmpty {
              Label("No conflicting populated identity fields", systemImage: "checkmark.circle")
                .foregroundStyle(crmSecondaryText)
            } else {
              ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                  Text(conflict.label).font(.subheadline.weight(.medium))
                  Text("Keeping “\(conflict.kept)”; the other value remains in the audit history.")
                    .font(.footnote)
                    .foregroundStyle(crmSecondaryText)
                }
              }
            }
          }
        }

        Section("Choose Duplicate") {
          if isLoading && candidates.isEmpty {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else if filteredCandidates.isEmpty {
            ContentUnavailableView.search(text: searchText)
          } else {
            ForEach(filteredCandidates) { candidate in
              Button {
                selectedID = candidate.id
              } label: {
                contactRow(candidate, selected: selectedID == candidate.id)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .navigationTitle("Merge Contact")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Name, email, or organization")
      .disabled(isMerging)
      .overlay { if isMerging { ProgressView().controlSize(.large) } }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Merge", role: .destructive) {
            showingConfirmation = true
          }
          .disabled(selectedContact == nil || isMerging)
        }
      }
      .task { await loadCandidates() }
      .confirmationDialog(
        "Merge these contacts?",
        isPresented: $showingConfirmation,
        titleVisibility: .visible
      ) {
        Button("Merge Contacts", role: .destructive) {
          Task { await merge() }
        }
      } message: {
        Text("The oldest contact remains. All emails and linked records will move to it.")
      }
      .alert("Unable to Merge", isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Unknown error")
      }
    }
  }

  private var selectedContact: CRMRecord? {
    candidates.first { $0.id == selectedID }
  }

  private var filteredCandidates: [CRMRecord] {
    guard !searchText.isEmpty else { return candidates }
    return candidates.filter {
      $0.fields.values
        .map(\.searchableText)
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(searchText)
    }
  }

  private var retainedEmails: [String] {
    guard let selectedContact else { return [] }
    var seen = Set<String>()
    var result: [String] = []
    for record in [contact, selectedContact] {
      let aliases = record["email_aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
      for email in [record["email"]?.stringValue, record["corporate_email"]?.stringValue]
        .compactMap({ $0 }) + aliases
      {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && seen.insert(trimmed.lowercased()).inserted {
          result.append(trimmed)
        }
      }
    }
    return result
  }

  private var conflicts: [MergeConflict] {
    guard let selectedContact else { return [] }
    let surviving = survivor(contact, selectedContact)
    let duplicate = surviving.id == contact.id ? selectedContact : contact
    let fields = [
      ("Name", "name"),
      ("Organization", "organization_id"),
      ("Phone", "phone"),
      ("LinkedIn", "linkedin_url"),
    ]
    return fields.compactMap { label, field -> MergeConflict? in
      let kept = surviving[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let other = duplicate[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !kept.isEmpty, !other.isEmpty, kept.caseInsensitiveCompare(other) != .orderedSame
      else { return nil }
      return MergeConflict(label: label, kept: kept)
    }
  }

  @ViewBuilder
  private func contactRow(_ record: CRMRecord, selected: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "person.crop.circle")
        .font(.title2)
        .foregroundStyle(crmSecondaryText)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName(record)).foregroundStyle(.primary)
        if let email = record["email"]?.stringValue, !email.isEmpty {
          Text(email).font(.footnote).foregroundStyle(crmSecondaryText)
        }
      }
      Spacer()
      if selected {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
      }
    }
    .contentShape(Rectangle())
  }

  private func displayName(_ record: CRMRecord) -> String {
    record["name"]?.stringValue ?? record["email"]?.stringValue ?? "Unnamed Contact"
  }

  private func survivor(_ first: CRMRecord, _ second: CRMRecord) -> CRMRecord {
    let firstCreated = first["created_at"]?.stringValue ?? ""
    let secondCreated = second["created_at"]?.stringValue ?? ""
    if firstCreated == secondCreated { return first.id < second.id ? first : second }
    return firstCreated < secondCreated ? first : second
  }

  private func loadCandidates() async {
    if let cached = try? await repository.cachedRecords(entity: "contacts") {
      candidates = sortedCandidates(cached.records)
    }
    do {
      let fresh = try await repository.refreshRecords(entity: "contacts", primaryField: "name")
      candidates = sortedCandidates(fresh)
    } catch {
      if candidates.isEmpty { errorMessage = error.localizedDescription }
    }
    isLoading = false
  }

  private func sortedCandidates(_ records: [CRMRecord]) -> [CRMRecord] {
    records
      .filter { $0.id != contact.id }
      .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
  }

  private func merge() async {
    guard let selectedContact else { return }
    isMerging = true
    defer { isMerging = false }
    do {
      let merged = try await repository.mergeContacts([contact.id, selectedContact.id])
      onMerged(merged)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
