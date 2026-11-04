import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// Members: adding wraps the vault key to them; removing re-seals every
/// item under a new key. Only others can be removed — the server requires
/// the caller among the new wraps, so leaving is something a remaining
/// member does for you.
struct KeepMembersSheet: View {
  @ObservedObject var session: KeepSession
  let vault: KeepVaultDetail
  let onChanged: () async -> Void
  let onDeleted: () -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var current: KeepVaultDetail
  @State private var name: String
  @State private var icon: String?
  @State private var directory: [KeepDirectoryEntry] = []
  @State private var adding: String = ""
  @State private var busy = false
  @State private var error: String?
  @State private var removing: KeepVaultMember?
  @State private var confirmDeleteVault = false

  init(session: KeepSession, vault: KeepVaultDetail, onChanged: @escaping () async -> Void, onDeleted: @escaping () -> Void) {
    self.session = session
    self.vault = vault
    self.onChanged = onChanged
    self.onDeleted = onDeleted
    _current = State(initialValue: vault)
    _name = State(initialValue: vault.name)
    _icon = State(initialValue: vault.icon)
  }

  private var detailsChanged: Bool {
    name.trimmingCharacters(in: .whitespaces) != current.name || icon != current.icon
  }

  private var candidates: [KeepDirectoryEntry] {
    let members = Set(current.members.map(\.email))
    return directory.filter { !members.contains($0.email) }
  }

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        Section("Vault") {
          TextField("Name", text: $name)
          KeepIconPicker(icon: $icon)
          if detailsChanged {
            KeepAsyncButton("Save", systemImage: "checkmark") { await saveDetails() }
              .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
          }
        }
        Section("Members") {
          ForEach(current.members) { member in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                Text("\(member.email) · added by \(member.grantedBy)").font(.footnote).foregroundStyle(crmSecondaryText)
              }
              Spacer()
              if member.email != session.me?.email, current.members.count > 1 {
                Button("Remove") { removing = member }.buttonStyle(.borderless).disabled(busy)
              }
            }
          }
        }
        Section("Add") {
          if candidates.isEmpty {
            Text("Everyone enrolled is already a member.").foregroundStyle(crmSecondaryText)
          } else {
            Picker("Person", selection: $adding) {
              Text("Choose…").tag("")
              ForEach(candidates) { Text("\($0.name) (\($0.email))").tag($0.email) }
            }
            KeepAsyncButton("Add", systemImage: "person.badge.plus") { await grant() }
              .disabled(adding.isEmpty || busy)
          }
          Text("Adding wraps the vault key to them. Removing re-seals everything under a new key.")
            .font(.footnote).foregroundStyle(crmSecondaryText)
        }
        Section {
          Text("Key version \(current.keyVersion)\(current.recoveryWrapped ? " · recoverable" : " · no recovery copy")")
            .font(.footnote).foregroundStyle(crmSecondaryText)
          // The row wears the house danger, not the system's destructive red;
          // the confirmation dialog below keeps the role for the platform.
          Button { confirmDeleteVault = true } label: { Text("Delete vault…").foregroundStyle(EnvisioningSemantics.danger) }
            .disabled(busy)
        }
        if let error {
          Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
        }
      }
      .navigationTitle(current.name)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .task { directory = (try? await session.client.directory()) ?? [] }
      .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
        Button("Remove and rotate", role: .destructive) {
          if let member = removing { Task { await revoke(member) } }
        }
      } message: {
        Text("Every item is re-sealed under a new key they will not hold.")
      }
      .confirmationDialog("Delete “\(current.name)” and its \(current.items.count) items?", isPresented: $confirmDeleteVault, titleVisibility: .visible) {
        Button("Delete vault", role: .destructive) { Task { await deleteVault() } }
      } message: {
        Text("The activity log stays.")
      }
    }
    #if os(macOS)
    .frame(minWidth: 460, minHeight: 420)
    #endif
  }

  private func saveDetails() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      current = try await session.updateVault(current, name: name.trimmingCharacters(in: .whitespaces), icon: icon, projectId: current.projectId)
      await onChanged()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func grant() async {
    guard let entry = directory.first(where: { $0.email == adding }) else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      current = try await session.grant(current, to: entry)
      adding = ""
      await onChanged()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func revoke(_ member: KeepVaultMember) async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      current = try await session.revoke(current, email: member.email, directory: directory)
      await onChanged()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func deleteVault() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await session.deleteVault(current)
      onDeleted()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Every reveal, grant, rotation and change on this vault, newest first.
struct KeepActivitySheet: View {
  @ObservedObject var session: KeepSession
  let vaultId: String
  @Environment(\.dismiss) private var dismiss
  @State private var events: [KeepAuditEvent]?

  var body: some View {
    NavigationStack {
      List {
        if let events {
          if events.isEmpty { Text("Nothing yet.").foregroundStyle(crmSecondaryText).envisioningListRows() }
          ForEach(events) { event in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(event.kind).font(.system(.footnote, design: .monospaced))
                if let name = event.itemName { Text(name) }
              }
              Text("\(event.actor) · \(keepWhen(event.createdAt))").font(.footnote).foregroundStyle(crmSecondaryText)
            }
            .envisioningListRows()
          }
        } else {
          EnvisioningPlaceholderRows().envisioningListRows()
        }
      }
      .envisioningListSurface()
      .navigationTitle("Activity")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task { events = (try? await session.client.audit(vault: vaultId)) ?? [] }
    }
    #if os(macOS)
    .frame(minWidth: 460, minHeight: 420)
    #endif
  }
}
