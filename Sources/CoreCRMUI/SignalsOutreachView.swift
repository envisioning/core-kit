import CoreKit
import EnvisioningUI
import SwiftUI

/// How the worklist is filtered: the whole funnel, or one stage at a time.
private enum OutreachFilter: Hashable {
  case all
  case status(String)
}

/// Signals prospecting worklist: contacts grouped by `signals_outreach_status`.
///
/// This screen is a **triage list**. It shows who is in the funnel and the
/// variables that shape the sendout (language, org type). A row opens the
/// contact detail, where `SignalsOutreachSection` moves the status.
public struct SignalsOutreachView: View {
  let contract: CRMEntityContract
  let allContracts: [CRMEntityContract]
  let repository: CRMRepository
  let onToast: (String) -> Void

  @State private var records: [CRMRecord] = []
  @State private var isLoading = false
  @State private var failed = false
  @State private var filter: OutreachFilter = .all

  /// The contacts contract, when this account may list contacts and the
  /// server publishes the outreach status field. Hosts show the worklist's
  /// entry only when this is non-nil, so an unconfigured server shows nothing.
  public static func contactsContract(in contracts: [CRMEntityContract]) -> CRMEntityContract? {
    contracts.first {
      $0.id == "contacts" && $0.canList
        && $0.fields.contains { $0.name == "signals_outreach_status" }
    }
  }

  public init(
    contract: CRMEntityContract,
    allContracts: [CRMEntityContract],
    repository: CRMRepository,
    onToast: @escaping (String) -> Void
  ) {
    self.contract = contract
    self.allContracts = allContracts
    self.repository = repository
    self.onToast = onToast
  }

  private func status(_ record: CRMRecord) -> String {
    record["signals_outreach_status"]?.stringValue ?? ""
  }

  private func group(_ bucket: String) -> [CRMRecord] {
    records.filter { status($0) == bucket }
  }

  private var actionableCount: Int {
    records.filter { SignalsOutreach.actionableStatuses.contains(status($0)) }.count
  }

  /// The funnel stages shown: all of them, or the selected one.
  private var visibleBuckets: [String] {
    switch filter {
    case .all: SignalsOutreach.actionableStatuses
    case .status(let bucket): [bucket]
    }
  }

  private var visibleCount: Int {
    visibleBuckets.reduce(0) { $0 + group($1).count }
  }

  private var filterLabel: String {
    switch filter {
    case .all: "All"
    case .status(let bucket): SignalsOutreach.statusLabel(bucket)
    }
  }

  @ViewBuilder
  private var content: some View {
    if isLoading && records.isEmpty {
      EntityListLoadingView()
    } else if failed && records.isEmpty {
      ContentUnavailableView("Couldn’t load contacts", systemImage: "exclamationmark.triangle")
    } else if visibleCount == 0 {
      ContentUnavailableView(
        filter == .all ? "No outreach in progress" : "No contacts in this stage",
        systemImage: "paperplane")
    } else {
      EnvisioningList {
        ForEach(visibleBuckets, id: \.self) { bucket in
          let members = group(bucket)
          if !members.isEmpty {
            Section("\(SignalsOutreach.statusLabel(bucket)) (\(members.count))") {
              ForEach(members) { record in
                NavigationLink(value: record) {
                  OutreachRow(record: record, primaryField: contract.primaryField)
                }
              }
            }
          }
        }
      }
      .refreshable { await load(forceRefresh: true) }
    }
  }

  public var body: some View {
    content
      .navigationTitle("Signals Outreach")
      .listCountSubtitle(isLoading && records.isEmpty ? nil : visibleCount)
      .toolbar {
        ToolbarItem(placement: .secondaryAction) {
          Menu {
            Picker("Stage", selection: $filter) {
              Text("All (\(actionableCount))").tag(OutreachFilter.all)
              ForEach(SignalsOutreach.actionableStatuses, id: \.self) { bucket in
                Text("\(SignalsOutreach.statusLabel(bucket)) (\(group(bucket).count))")
                  .tag(OutreachFilter.status(bucket))
              }
            }
          } label: {
            Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
          }
        }
      }
      .navigationDestination(for: CRMRecord.self) { record in
        EntityDetailView(
          contract: contract,
          allContracts: allContracts,
          record: record,
          repository: repository,
          onToast: onToast,
          onChanged: { Task { await load(forceRefresh: true) } })
      }
      .task { await load() }
      // macOS has no pull gesture, so ⌘R is this screen's way back to the network.
      .onRefreshRequest { Task { await load(forceRefresh: true) } }
  }

  private func load(forceRefresh: Bool = false) async {
    isLoading = true
    defer { isLoading = false }
    if !forceRefresh, records.isEmpty,
      let cached = try? await repository.cachedRecords(entity: contract.id)
    {
      records = cached.records
    }
    do {
      records = try await repository.refreshRecords(
        entity: contract.id, primaryField: contract.primaryField)
      failed = false
    } catch {
      failed = true
    }
  }
}

/// One triage row: avatar, name, organization, and the "approach" chips that
/// decide how the outreach email reads.
private struct OutreachRow: View {
  let record: CRMRecord
  let primaryField: String

  private var organization: [String: JSONValue]? { record["organization"]?.objectValue }

  private var name: String {
    record[primaryField]?.stringValue ?? "Unnamed contact"
  }

  private var audience: SignalsAudience {
    SignalsOutreach.audience(
      isExistingClient: organization?["is_existing_client"]?.boolValue ?? false,
      isPartner: organization?["is_partner"]?.boolValue ?? false)
  }

  var body: some View {
    HStack(spacing: CRMListRow.iconSpacing) {
      CachedRemoteAvatar(
        url: record.avatarURL, name: name, fallbackSymbol: "person.crop.circle")
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
        if let org = organization?["name"]?.stringValue, !org.isEmpty {
          Text(org)
            .font(.subheadline)
            .foregroundStyle(crmSecondaryText)
            .lineLimit(1)
        }
        HStack(spacing: 6) {
          OutreachChip(text: (record["preferred_language"]?.stringValue ?? "en").uppercased())
          OutreachChip(text: SignalsOutreach.audienceLabel(audience))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
  }
}
