#if os(macOS)
  import AppKit
  import AuthenticationServices
  import CoreCRMUI
  import EnvisioningUI
  import KeepKit
  import SwiftUI

  /// Keep on the Mac: three columns, the way a password manager reads on a
  /// wide screen. Vaults on the rail, the chosen vault's items in the middle,
  /// the chosen item on the right. No pushes, no page titles — the columns
  /// are the navigation, and the toolbar holds only what acts on what is
  /// selected.
  struct KeepSplitView: View {
    @ObservedObject var session: KeepSession
    let anchor: @MainActor () -> ASPresentationAnchor
    var landing: KeepLanding = .vaults

    @State private var selectedVaultId: String?
    /// One field for the window: it narrows the vault rail and the item
    /// column together.
    @State private var filter = ""
    @State private var landingError: String?
    @State private var selectedItemId: String?
    @State private var vault: KeepVaultDetail?
    @State private var vaultError: String?
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
      case newVault, newItem, members, activity, settings
      var id: Int { hashValue }
    }

    var body: some View {
      NavigationSplitView {
        sidebar
      } content: {
        items
      } detail: {
        detail
      }
      .navigationSplitViewStyle(.balanced)
      .searchable(text: $filter, placement: .toolbar, prompt: "Search")
      .sheet(item: $sheet) { which in
        switch which {
        case .newVault:
          KeepNewVaultSheet(session: session) { created in
            sheet = nil
            selectedVaultId = created.id
          }
        case .newItem:
          if let vault {
            KeepItemEditor(session: session, vault: vault, item: nil, initial: KeepItemBody()) {
              sheet = nil
              await loadVault()
            }
          }
        case .members:
          if let vault {
            KeepMembersSheet(session: session, vault: vault, onChanged: { await loadVault() }, onDeleted: {
              sheet = nil
              selectedVaultId = nil
            })
          }
        case .activity:
          if let vault { KeepActivitySheet(session: session, vaultId: vault.id) }
        case .settings:
          NavigationStack {
            KeepSettingsView(session: session, anchor: anchor)
              .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
          }
          .frame(minWidth: 460, minHeight: 480)
        }
      }
      .task {
        await session.loadVaults()
        if case .project(let id, let name) = landing {
          do {
            selectedVaultId = try await session.ensureVault(forProject: id, named: name)
          } catch {
            landingError = error.localizedDescription
          }
        }
      }
      .task(id: selectedVaultId) {
        selectedItemId = nil
        await loadVault()
      }
      // A host asked for a vault (Work › a project › Keep) while the window
      // was already open.
      .onChange(of: session.requestedVaultId) { _, requested in
        guard let requested else { return }
        selectedVaultId = requested
        session.requestedVaultId = nil
      }
      .onAppear { session.touch() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        Task { await session.loadVaults() }
      }
    }

    // MARK: Columns

    private var filteredVaults: [KeepVaultSummary] {
      let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
      return needle.isEmpty ? session.vaults : session.vaults.filter { $0.name.lowercased().contains(needle) }
    }

    private var filteredItems: [KeepItemSummary] {
      let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
      let items = vault?.items ?? []
      return needle.isEmpty ? items : items.filter { $0.name.lowercased().contains(needle) || $0.kind.label.lowercased().contains(needle) }
    }

    private var sidebar: some View {
      List(selection: $selectedVaultId) {
        if let landingError {
          Text(landingError).foregroundStyle(EnvisioningSemantics.danger).envisioningListRows()
        }
        if let error = session.vaultsError {
          Text(error).foregroundStyle(EnvisioningSemantics.danger).envisioningListRows()
        } else if !session.vaultsLoaded {
          EnvisioningPlaceholderRows().envisioningListRows()
        } else if session.vaults.isEmpty {
          Text("No vaults yet.").foregroundStyle(crmSecondaryText).envisioningListRows()
        }
        Section("Vaults") {
          ForEach(filteredVaults) { entry in
            Label {
              Text(entry.name)
            } icon: {
              Image(systemName: KeepVaultIcon.symbol(entry.icon))
            }
            .badge(entry.itemCount)
            .tag(entry.id)
            .envisioningListRows()
          }
        }
      }
      .listStyle(.sidebar)
      .envisioningListSurface()
      .navigationTitle("Keep")
      .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { sheet = .newVault } label: { Label("New vault", systemImage: "plus") }
            .help("New vault")
        }
        ToolbarItemGroup(placement: .automatic) {
          Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }.help("Keep settings")
          Button { session.lock() } label: { Label("Lock", systemImage: "lock") }.help("Lock Keep")
        }
      }
    }

    @ViewBuilder
    private var items: some View {
      if selectedVaultId == nil {
        placeholder("Choose a vault")
          .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
      } else {
        List(selection: $selectedItemId) {
          if let vault {
            if vault.items.isEmpty {
              Text("Nothing here yet.").foregroundStyle(crmSecondaryText).envisioningListRows()
            }
            ForEach(filteredItems) { item in
              HStack(spacing: 10) {
                Image(systemName: item.kind.symbolName).foregroundStyle(crmSecondaryText).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.name)
                  Text(item.kind.label).font(.footnote).foregroundStyle(crmSecondaryText)
                }
              }
              .tag(item.id)
              .envisioningListRows()
            }
          } else if let vaultError {
            Text(vaultError).foregroundStyle(EnvisioningSemantics.danger).envisioningListRows()
          } else {
            EnvisioningPlaceholderRows().envisioningListRows()
          }
        }
        .listStyle(.inset)
        .envisioningListSurface()
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .navigationTitle(vault?.name ?? "Vault")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button { sheet = .newItem } label: { Label("New item", systemImage: "plus") }
              .disabled(vault == nil)
              .help("New item")
          }
          ToolbarItemGroup(placement: .automatic) {
            Button { sheet = .members } label: { Label("Vault settings", systemImage: "slider.horizontal.3") }.disabled(vault == nil).help("Name, icon, members")
            Button { sheet = .activity } label: { Label("Activity", systemImage: "list.bullet.rectangle") }.disabled(vault == nil).help("Activity")
          }
        }
      }
    }

    @ViewBuilder
    private var detail: some View {
      if let vault, let itemId = selectedItemId, let item = vault.items.first(where: { $0.id == itemId }) {
        KeepItemView(session: session, vault: vault, item: item) { await loadVault() }
          .id(item.id)
      } else {
        placeholder(vault == nil ? "" : "Choose an item")
          .navigationTitle("")
      }
    }

    private func placeholder(_ text: String) -> some View {
      Text(text)
        .foregroundStyle(crmSecondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(crmGroupedBackground)
    }

    private func loadVault() async {
      guard let selectedVaultId else {
        vault = nil
        return
      }
      do {
        let loaded = try await session.client.vault(selectedVaultId)
        vault = loaded
        vaultError = nil
        if let selectedItemId, !loaded.items.contains(where: { $0.id == selectedItemId }) {
          self.selectedItemId = nil
        }
      } catch {
        vault = nil
        vaultError = error.localizedDescription
      }
    }
  }
#endif
