import CoreCRMUI
import CryptoKit
import EnvisioningUI
import KeepKit
import SwiftUI

typealias CryptoKitP256PrivateKey = P256.KeyAgreement.PrivateKey

// Recovery, natively: the ceremony that makes the key and hands out the two
// shares, and the screen where a person holding both shares opens a vault
// nobody else can. Both live under Keep's settings.

/// The Recovery section of Keep's settings: status, the ceremony, and the
/// door to recovering a vault.
struct KeepRecoverySections: View {
  @ObservedObject var session: KeepSession
  @State private var ceremony = false
  @State private var recovering = false

  var body: some View {
    Section {
      if !session.recoveryLoaded {
        EnvisioningPlaceholderRows(count: 1)
      } else if let key = session.recoveryKey {
        Text("Held by \(key.holders.joined(separator: " and ")). Set by \(key.createdBy) on \(keepWhen(key.createdAt)).")
          .font(.footnote).foregroundStyle(crmSecondaryText)
        let uncovered = session.vaults.filter { !$0.recoveryWrapped }
        if uncovered.isEmpty {
          Text("Every vault you can open has a recovery copy.").font(.footnote).foregroundStyle(crmSecondaryText)
        } else {
          Text("\(uncovered.count) of your vaults have no recovery copy yet; they get one the next time they load.")
            .font(.footnote).foregroundStyle(crmSecondaryText)
        }
        Button { recovering = true } label: { Label("Recover a vault…", systemImage: "key.viewfinder") }
      } else {
        Text("No recovery key. A vault whose members all lose their keys is lost. Set one before the first vault that matters.")
          .font(.footnote).foregroundStyle(EnvisioningSemantics.danger)
        Button { ceremony = true } label: { Label("Create recovery key…", systemImage: "person.2.badge.key") }
      }
    } header: {
      Text("Recovery")
    } footer: {
      Text("Two people each hold one share of a key every vault is also sealed to. Both shares, or nothing.")
    }
    .task { if !session.recoveryLoaded { await session.loadRecoveryKey() } }
    .sheet(isPresented: $ceremony) { KeepRecoveryCeremony(session: session) }
    .sheet(isPresented: $recovering) { KeepRecoverVaultSheet(session: session) }
  }
}

/// Make the key, split it, show each share once, publish the public half.
/// The shares go to two people's own password managers and nowhere near
/// this system. The private key is gone when this sheet is.
struct KeepRecoveryCeremony: View {
  @ObservedObject var session: KeepSession
  @Environment(\.dismiss) private var dismiss
  @State private var directory: [KeepDirectoryEntry] = []
  @State private var holderA = ""
  @State private var holderB = ""
  @State private var shares: KeepSession.RecoveryShares?
  @State private var acknowledged = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        if let shares {
          Section {
            Text("Shown once. Put each share in its holder's own password manager now. Closing this loses them.")
              .font(.footnote).foregroundStyle(EnvisioningSemantics.danger)
          }
          shareSection("Share A", holder: holderA, value: shares.a)
          shareSection("Share B", holder: holderB, value: shares.b)
          Section {
            Toggle("Both shares are stored outside Keep, by their holders.", isOn: $acknowledged)
            Button("Done") { dismiss() }.disabled(!acknowledged)
          }
        } else {
          Section("Holders") {
            Picker("Holder A", selection: $holderA) {
              Text("Choose…").tag("")
              ForEach(directory) { Text($0.name).tag($0.email) }
            }
            Picker("Holder B", selection: $holderB) {
              Text("Choose…").tag("")
              ForEach(directory.filter { $0.email != holderA }) { Text($0.name).tag($0.email) }
            }
            Text("Two enrolled people. Vaults already made are covered the next time a member opens Keep.")
              .font(.footnote).foregroundStyle(crmSecondaryText)
          }
          if let error {
            Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
          }
          Section {
            KeepAsyncButton("Generate and publish", systemImage: "person.2.badge.key") { await generate() }
              .disabled(holderA.isEmpty || holderB.isEmpty || holderA == holderB)
          }
        }
      }
      .navigationTitle("Recovery key")
      .toolbar {
        if shares == nil {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
      }
      .interactiveDismissDisabled(shares != nil && !acknowledged)
      .task {
        directory = (try? await session.client.directory()) ?? []
        if holderA.isEmpty, let me = session.me?.email, directory.contains(where: { $0.email == me }) { holderA = me }
      }
    }
    #if os(macOS)
    .frame(minWidth: 520, minHeight: 460)
    #endif
  }

  @ViewBuilder
  private func shareSection(_ title: String, holder: String, value: String) -> some View {
    Section("\(title) — \(holder)") {
      Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
      Button {
        copyToPasteboard(value)
      } label: { Label("Copy \(title.lowercased())", systemImage: "doc.on.doc") }
    }
  }

  private func generate() async {
    error = nil
    do {
      shares = try await session.createRecoveryKey(holders: [holderA, holderB])
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Both shares in, the recovery key checked against the published public
/// key, then every covered vault — join the one that is needed. Each step
/// is written to the audit log by the server.
struct KeepRecoverVaultSheet: View {
  @ObservedObject var session: KeepSession
  @Environment(\.dismiss) private var dismiss
  @State private var shareA = ""
  @State private var shareB = ""
  @State private var recoveryKey: P256KeyBox?
  @State private var vaults: [KeepRecoveryVaultEntry] = []
  @State private var joined: Set<String> = []
  @State private var busy = false
  @State private var error: String?

  /// CryptoKit keys are not `Equatable`; a box keeps SwiftUI state simple.
  final class P256KeyBox {
    let key: CryptoKitP256PrivateKey
    init(_ key: CryptoKitP256PrivateKey) { self.key = key }
  }

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        if recoveryKey == nil {
          Section {
            Text("Paste both shares. The key they make is checked against the published one before anything is listed.")
              .font(.footnote).foregroundStyle(crmSecondaryText)
            KeepSecretField(title: "Share A", text: $shareA, contentType: .password)
            KeepSecretField(title: "Share B", text: $shareB, contentType: .password)
            KeepAsyncButton("Open the recovery key", systemImage: "key") { await open() }
              .disabled(shareA.isEmpty || shareB.isEmpty || busy)
          } header: {
            Text("Shares")
          } footer: {
            Text("Listing and joining are recorded under your name. Rotate the vault afterwards if a member should no longer hold it.")
          }
        } else {
          Section("Vaults with a recovery copy") {
            if vaults.isEmpty {
              Text("None.").foregroundStyle(crmSecondaryText)
            }
            ForEach(vaults) { entry in
              HStack {
                Image(systemName: KeepVaultIcon.symbol(entry.icon)).foregroundStyle(crmSecondaryText).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.name)
                  Text(entry.members.isEmpty ? "No members" : entry.members.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(crmSecondaryText)
                }
                Spacer()
                if joined.contains(entry.id) {
                  Label("Joined", systemImage: "checkmark").font(.footnote).foregroundStyle(crmSecondaryText)
                } else if entry.members.contains(session.me?.email ?? "") {
                  Text("Member").font(.footnote).foregroundStyle(crmSecondaryText)
                } else {
                  KeepAsyncButton("Join") { await join(entry) }.disabled(busy)
                }
              }
            }
          }
        }
        if let error {
          Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
        }
      }
      .navigationTitle("Recover a vault")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    #if os(macOS)
    .frame(minWidth: 520, minHeight: 460)
    #endif
  }

  private func open() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      let key = try await session.recoveryPrivateKey(shareA: shareA, shareB: shareB)
      recoveryKey = P256KeyBox(key)
      shareA = ""
      shareB = ""
      vaults = try await session.recoveryVaults()
    } catch KeepCryptoError.cannotOpen {
      self.error = "These shares do not make the published recovery key."
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func join(_ entry: KeepRecoveryVaultEntry) async {
    guard let recoveryKey else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await session.recover(entry, with: recoveryKey.key)
      joined.insert(entry.id)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
