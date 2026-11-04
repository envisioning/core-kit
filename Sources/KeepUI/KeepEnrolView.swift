import AuthenticationServices
#if os(macOS)
  import AppKit
#endif
import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// Enrolment: make a keypair on this device, wrap the private half, send
/// the public half and the wrapped blob. The server learns nothing it could
/// use to open anything. `replace` is the re-enrol path from Settings, and
/// it drops every vault membership because the old wraps are dead.
struct KeepEnrolView: View {
  @ObservedObject var session: KeepSession
  let me: KeepMe
  let anchor: @MainActor () -> ASPresentationAnchor
  let replace: Bool

  @State private var usePasskey = KeepPasskey.isAvailable
  @State private var passphrase = ""
  @State private var confirm = ""
  @State private var error: String?

  private let minimum = 12

  var body: some View {
    KeepGate(
      title: replace ? "Replace your key" : "Set up Keep",
      message: replace
        ? "A new key on this device. You leave every vault until a member adds you back."
        : "Keep makes a key on this device. The server stores a locked copy it cannot open."
    ) {
      VStack(spacing: 12) {
        if KeepPasskey.isAvailable {
          Picker("Unlock with", selection: $usePasskey) {
            Text("Passkey").tag(true)
            Text("Passphrase").tag(false)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        if usePasskey {
          Text("Touch ID, Face ID or a security key unlocks Keep. Nothing to remember.")
            .font(.footnote).foregroundStyle(crmSecondaryText).multilineTextAlignment(.center)
          KeepAsyncButton("Create passkey", systemImage: "person.badge.key") { await enrolPasskey() }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 44, expands: false))
        } else {
          KeepSecretField(title: "Passphrase", text: $passphrase).keepField()
          KeepSecretField(title: "Again", text: $confirm).keepField()
          Text("Forgetting it means losing your access. There is no reset, only the recovery key holders.")
            .font(.footnote).foregroundStyle(crmSecondaryText).multilineTextAlignment(.center)
          KeepAsyncButton("Set passphrase", systemImage: "lock") { await enrolPassphrase() }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 44, expands: false))
            .disabled(passphrase.count < minimum || passphrase != confirm)
        }
        KeepErrorText(message: error)
      }
    }
  }

  private func enrolPasskey() async {
    error = nil
    do {
      let passkey = KeepPasskey(relyingParty: await session.client.relyingPartyIdentifier, anchor: anchor)
      let enrolment = try await passkey.enrol(email: me.email, name: me.name)
      try await session.enrol(passkey: enrolment, replace: replace)
    } catch KeepPasskeyError.cancelled {
      // Nothing to say.
    } catch KeepPasskeyError.noPRF {
      error = KeepPasskeyError.noPRF.errorDescription
      usePasskey = false
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func enrolPassphrase() async {
    error = nil
    guard passphrase.count >= minimum else {
      error = "Use at least \(minimum) characters."
      return
    }
    guard passphrase == confirm else {
      error = "The two passphrases differ."
      return
    }
    do {
      try await session.enrol(passphrase: passphrase, replace: replace)
      passphrase = ""
      confirm = ""
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// The third gate: turn the wrapped private key into a live one, in memory.
/// Offers every way the key holds: the passkey when this app can use one,
/// the passphrase when the key has one. A passkey-only key on a client
/// without passkeys says where to add a passphrase.
struct KeepUnlockView: View {
  @ObservedObject var session: KeepSession
  let anchor: @MainActor () -> ASPresentationAnchor

  @State private var passphrase = ""
  @State private var error: String?
  @State private var askedOnce = false

  private var canPasskey: Bool { session.passkeyCredentialId != nil && KeepPasskey.isAvailable }
  private var hasPassphrase: Bool { session.hasPassphrase }

  private var message: String {
    if canPasskey && hasPassphrase { return "Use your passkey or your passphrase to open your vaults on this device." }
    if canPasskey { return "Use your passkey to open your vaults on this device." }
    if hasPassphrase { return "Enter your passphrase to open your vaults on this device." }
    return "Your key is unlocked by a passkey, which this app cannot use yet. On your phone or on the web, open Keep → Settings and add a passphrase; it works here."
  }

  var body: some View {
    KeepGate(title: "Unlock Keep", message: message) {
      VStack(spacing: 12) {
        if canPasskey {
          KeepAsyncButton("Unlock with passkey", systemImage: "faceid") { await unlockPasskey() }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 44, expands: false))
        }
        if hasPassphrase {
          KeepSecretField(title: "Passphrase", text: $passphrase, contentType: .password)
            .keepField()
            .onSubmit { Task { await unlockPassphrase() } }
          KeepAsyncButton("Unlock", systemImage: "lock.open") { await unlockPassphrase() }
            .buttonStyle(canPasskey ? AnyButtonStyle(EnvisioningBorderedButtonStyle(minHeight: 44, expands: false)) : AnyButtonStyle(EnvisioningFilledButtonStyle(minHeight: 44, expands: false)))
            .disabled(passphrase.isEmpty)
        }
        if !canPasskey, !hasPassphrase {
          KeepAsyncButton("Check again", systemImage: "arrow.clockwise") { await session.refresh() }
            .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 44, expands: false))
        }
        KeepErrorText(message: error)
        if canPasskey || hasPassphrase {
          Text("Keep locks after 15 minutes without activity.").font(.footnote).foregroundStyle(crmSecondaryText)
        }
      }
    }
    .task {
      // A passkey unlock is one tap; start it without asking, once.
      guard canPasskey, !askedOnce else { return }
      askedOnce = true
      await unlockPasskey()
    }
    #if os(macOS)
    // The window stays open while the passphrase is added elsewhere; ask
    // again each time it comes to the front.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await session.refresh() }
    }
    #endif
  }

  private func unlockPasskey() async {
    error = nil
    guard let credentialId = session.passkeyCredentialId else { return }
    do {
      let passkey = KeepPasskey(relyingParty: await session.client.relyingPartyIdentifier, anchor: anchor)
      let prf = try await passkey.unlock(credentialId: credentialId)
      try await session.unlock(prfOutput: prf)
    } catch KeepPasskeyError.cancelled {
      // Nothing to say.
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func unlockPassphrase() async {
    error = nil
    do {
      try await session.unlock(passphrase: passphrase)
      passphrase = ""
    } catch {
      self.error = "Wrong passphrase."
    }
  }
}

/// Type erasure for choosing a button style at runtime.
struct AnyButtonStyle: ButtonStyle {
  private let make: (Configuration) -> AnyView
  init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Keep's settings inside the app: the ways this key unlocks. The key is
/// open here, so it can be sealed again under a passphrase or a passkey.
struct KeepSettingsView: View {
  @ObservedObject var session: KeepSession
  let anchor: @MainActor () -> ASPresentationAnchor

  var body: some View {
    EnvisioningForm {
      KeepUnlockMethodsSections(session: session, anchor: anchor)
      if session.isUnlocked {
        KeepRecoverySections(session: session)
      }
    }
    .navigationTitle("Keep settings")
    .onAppear { session.touch() }
  }
}

/// Everything Keep puts in a host's Settings form: the unlock methods and,
/// with the key open, recovery.
public struct KeepSettingsSections: View {
  @ObservedObject private var session: KeepSession
  private let anchor: @MainActor () -> ASPresentationAnchor

  public init(session: KeepSession, anchor: @escaping @MainActor () -> ASPresentationAnchor) {
    self.session = session
    self.anchor = anchor
  }

  public var body: some View {
    KeepUnlockMethodsSections(session: session, anchor: anchor)
    if session.isUnlocked {
      KeepRecoverySections(session: session)
    }
  }
}

/// The unlock-method rows, as `Section`s so a host can put them inside its
/// own settings form. Needs the key open; shows why when it is not.
public struct KeepUnlockMethodsSections: View {
  @ObservedObject private var session: KeepSession
  private let anchor: @MainActor () -> ASPresentationAnchor
  @State private var passphrase = ""
  @State private var confirm = ""
  @State private var generated: String?
  @State private var error: String?
  @State private var done: String?

  public init(session: KeepSession, anchor: @escaping @MainActor () -> ASPresentationAnchor) {
    self.session = session
    self.anchor = anchor
  }

  private var hasPassphrase: Bool { session.hasPassphrase }
  private var hasPasskey: Bool { session.passkeyCredentialId != nil }

  private var passphraseProblem: String? {
    if passphrase.isEmpty { return nil }
    if passphrase.count < 12 { return "12 characters minimum." }
    if confirm != passphrase { return confirm.isEmpty ? "Type it again below." : "The two do not match." }
    return nil
  }

  public var body: some View {
    if !session.isUnlocked {
      Section {
        Text(session.me == nil ? "Connect Keep to change how it unlocks." : "Unlock Keep to change how it unlocks.")
          .font(.footnote).foregroundStyle(crmSecondaryText)
      }
    } else {
      Section("Unlocks with") {
        LabeledContent("Passkey", value: hasPasskey ? "Yes" : "No")
        LabeledContent("Passphrase", value: hasPassphrase ? "Yes" : "No")
        Text("The Meet app on the Mac needs a passphrase.").font(.footnote).foregroundStyle(crmSecondaryText)
      }
      Section {
        KeepSecretField(title: "Passphrase", text: $passphrase)
        KeepSecretField(title: "Again", text: $confirm)
        if let generated {
          HStack {
            Text(generated).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
              copyToPasteboard(generated)
              done = "Copied. Store it in your own password manager."
            } label: { Image(systemName: "doc.on.doc") }
              .buttonStyle(.borderless)
          }
        }
        if let problem = passphraseProblem {
          Text(problem).font(.footnote).foregroundStyle(crmSecondaryText)
        }
        Button("Generate one") {
          let value = KeepPassphrase.generate()
          generated = value
          passphrase = value
          confirm = value
          done = nil
        }
        .buttonStyle(.borderless)
        KeepAsyncButton(hasPassphrase ? "Change passphrase" : "Save passphrase", systemImage: "lock") { await addPassphrase() }
          .disabled(passphrase.isEmpty || passphraseProblem != nil)
      } header: {
        Text(hasPassphrase ? "Change passphrase" : "Add a passphrase")
      } footer: {
        Text("Twelve characters or more. There is no reset; keep it in your own password manager.")
      }
      if KeepPasskey.isAvailable {
        Section {
          KeepAsyncButton(hasPasskey ? "Replace passkey" : "Add passkey", systemImage: "person.badge.key") { await addPasskey() }
        } header: {
          Text("Passkey")
        } footer: {
          Text("Face ID or Touch ID on this device. Replacing it does not add a passphrase.")
        }
      }
      if let done {
        Section { Text(done).font(.footnote).foregroundStyle(crmSecondaryText) }
      }
      if let error {
        Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
      }
    }
  }

  private func addPassphrase() async {
    error = nil
    done = nil
    do {
      try await session.addPassphrase(passphrase)
      passphrase = ""
      confirm = ""
      done = "Passphrase saved. It unlocks Keep on every device."
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func addPasskey() async {
    error = nil
    done = nil
    guard let me = session.me else { return }
    do {
      let passkey = KeepPasskey(relyingParty: await session.client.relyingPartyIdentifier, anchor: anchor)
      let enrolment = try await passkey.enrol(email: me.email, name: me.name)
      try await session.addPasskey(enrolment)
      done = "Passkey saved."
    } catch KeepPasskeyError.cancelled {
      // Nothing to say.
    } catch {
      self.error = error.localizedDescription
    }
  }
}
