import AuthenticationServices
import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// The vault list, with the lock and the way to a new vault. Pushes a
/// vault onto the host's `NavigationStack` — it has none of its own, because
/// a stack inside a pushed screen pops the host's (iOS). The Mac window
/// wraps `KeepRootView` in one (`KeepStandaloneView`).
///
/// Rows are destination links, not value links: a `navigationDestination(for:)`
/// declared inside a screen the host reached through
/// `navigationDestination(isPresented:)` is not always registered, and a
/// value link with no destination renders disabled — the row would not tap.
struct KeepVaultsView: View {
  @ObservedObject var session: KeepSession
  let anchor: @MainActor () -> ASPresentationAnchor
  @State private var creating = false
  @State private var filter = ""

  private var filtered: [KeepVaultSummary] {
    let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return needle.isEmpty ? session.vaults : session.vaults.filter { $0.name.lowercased().contains(needle) }
  }

  var body: some View {
      List {
        if let error = session.vaultsError {
          Text(error).foregroundStyle(EnvisioningSemantics.danger).envisioningListRows()
        } else if !session.vaultsLoaded {
          EnvisioningPlaceholderRows().envisioningListRows()
        } else if session.vaults.isEmpty {
          Text("No vaults yet. Make one, or ask a colleague to add you.")
            .foregroundStyle(crmSecondaryText)
            .envisioningListRows()
        }
        ForEach(filtered) { vault in
          NavigationLink {
            KeepVaultView(session: session, vaultId: vault.id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: KeepVaultIcon.symbol(vault.icon)).foregroundStyle(crmSecondaryText).frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                Text("\(vault.itemCount) \(vault.itemCount == 1 ? "item" : "items") · \(vault.memberCount) \(vault.memberCount == 1 ? "member" : "members")")
                  .font(.footnote).foregroundStyle(crmSecondaryText)
              }
            }
          }
          .envisioningListRows()
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #else
      .listStyle(.inset)
      #endif
      .envisioningListSurface()
      .searchable(text: $filter, prompt: "Vaults")
      .navigationTitle("Keep")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { creating = true } label: { Label("New vault", systemImage: "plus") }
        }
        ToolbarItemGroup(placement: .secondaryAction) {
          NavigationLink { KeepSettingsView(session: session, anchor: anchor) } label: { Label("Settings", systemImage: "gearshape") }
          Button { session.lock() } label: { Label("Lock", systemImage: "lock") }
        }
      }
      .sheet(isPresented: $creating) {
        KeepNewVaultSheet(session: session) { _ in
          creating = false
        }
      }
      .refreshable { await session.loadVaults() }
      // Every appearance re-reads the list: coming back from a vault, and
      // the first open after an unlock that raced the fetch.
      .task { session.touch(); await session.loadVaults() }
  }
}

/// A fresh vault key, wrapped to me and each chosen colleague and to the
/// recovery key. The key bytes never leave `KeepSession`.
struct KeepNewVaultSheet: View {
  @ObservedObject var session: KeepSession
  let onCreated: (KeepVaultDetail) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var icon: String?
  @State private var projectId = ""
  @State private var directory: [KeepDirectoryEntry] = []
  @State private var chosen: Set<String> = []
  @State private var hasRecovery: Bool?
  @State private var error: String?

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        Section {
          TextField("Name", text: $name)
          TextField("Core project id (optional)", text: $projectId)
            .autocorrectionDisabled()
        }
        Section("Icon") {
          KeepIconPicker(icon: $icon)
        }
        Section("Members") {
          if directory.isEmpty {
            Text("Nobody else is enrolled yet.").foregroundStyle(crmSecondaryText)
          }
          ForEach(directory) { entry in
            Toggle(isOn: Binding(
              get: { chosen.contains(entry.email) },
              set: { on in if on { chosen.insert(entry.email) } else { chosen.remove(entry.email) } }
            )) {
              VStack(alignment: .leading) {
                Text(entry.name)
                Text(entry.email).font(.footnote).foregroundStyle(crmSecondaryText)
              }
            }
          }
        }
        if hasRecovery == false {
          Section {
            Label("No recovery key is set. If every member loses their key, this vault is gone. Set one on the web.", systemImage: "exclamationmark.triangle")
              .font(.footnote)
          }
        }
        if let error {
          Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
        }
      }
      .navigationTitle("New vault")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          KeepAsyncButton("Create") { await create() }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || hasRecovery == nil)
        }
      }
      .task {
        let me = session.me?.email
        directory = ((try? await session.client.directory()) ?? []).filter { $0.email != me }
        hasRecovery = (try? await session.client.recoveryKey()) != nil
      }
    }
    #if os(macOS)
    .frame(minWidth: 440, minHeight: 420)
    #endif
  }

  private func create() async {
    error = nil
    do {
      let members = directory.filter { chosen.contains($0.email) }
      let trimmed = projectId.trimmingCharacters(in: .whitespaces)
      let vault = try await session.createVault(name: name.trimmingCharacters(in: .whitespaces), icon: icon, projectId: trimmed.isEmpty ? nil : trimmed, members: members)
      onCreated(vault)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
