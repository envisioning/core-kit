import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// One vault: its items, and the doors to members, activity and a new
/// item. Reveal is a push; edit is a sheet.
struct KeepVaultView: View {
  @ObservedObject var session: KeepSession
  let vaultId: String
  @Environment(\.dismiss) private var dismiss

  @State private var vault: KeepVaultDetail?
  @State private var error: String?
  @State private var sheet: Sheet?
  @State private var filter = ""

  enum Sheet: Identifiable {
    case newItem, members, activity
    var id: Int { hashValue }
  }

  private func filtered(_ items: [KeepItemSummary]) -> [KeepItemSummary] {
    let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return needle.isEmpty ? items : items.filter { $0.name.lowercased().contains(needle) || $0.kind.label.lowercased().contains(needle) }
  }

  var body: some View {
    Group {
      if let vault {
        List {
          if vault.items.isEmpty {
            Text("Nothing here yet.").foregroundStyle(crmSecondaryText).envisioningListRows()
          }
          ForEach(filtered(vault.items)) { item in
            NavigationLink {
              KeepItemView(session: session, vault: vault, item: item) { await load() }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: item.kind.symbolName).foregroundStyle(crmSecondaryText).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.name)
                  Text(item.kind.label).font(.footnote).foregroundStyle(crmSecondaryText)
                }
                Spacer()
                Text(keepWhen(item.updatedAt)).font(.caption).foregroundStyle(crmSecondaryText)
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
      } else {
        // The same list, waiting for its rows — the answer lands in place.
        List {
          if let error {
            Text(error).foregroundStyle(EnvisioningSemantics.danger).envisioningListRows()
          } else {
            EnvisioningPlaceholderRows().envisioningListRows()
          }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .envisioningListSurface()
      }
    }
    .navigationTitle(vault?.name ?? "Vault")
    .searchable(text: $filter, prompt: "Items")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { sheet = .newItem } label: { Label("New item", systemImage: "plus") }.disabled(vault == nil)
      }
      // Secondary actions, no menu of our own: iOS folds this group into
      // the system's … itself, and a Menu inside it was a menu in a menu.
      ToolbarItemGroup(placement: .secondaryAction) {
        Button { sheet = .members } label: { Label("Vault settings", systemImage: "slider.horizontal.3") }
        Button { sheet = .activity } label: { Label("Activity", systemImage: "list.bullet.rectangle") }
        if let vault, let projectId = vault.projectId, let me = session.me,
          let url = URL(string: "\(me.coreWebOrigin)/dashboard/projects/\(projectId)")
        {
          Link(destination: url) { Label("Open in Core", systemImage: "safari") }
        }
      }
    }
    .sheet(item: $sheet) { which in
      if let vault {
        switch which {
        case .newItem:
          KeepItemEditor(session: session, vault: vault, item: nil, initial: KeepItemBody()) { sheet = nil; await load() }
        case .members:
          KeepMembersSheet(session: session, vault: vault, onChanged: { await load() }, onDeleted: { sheet = nil; dismiss() })
        case .activity:
          KeepActivitySheet(session: session, vaultId: vault.id)
        }
      }
    }
    .task(id: vaultId) { await load() }
    .onAppear { session.touch() }
  }

  private func load() async {
    do {
      vault = try await session.client.vault(vaultId)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Reveal: one fetch (audited), opened in `KeepSession`, shown until the
/// view goes away. Plaintext lives in `@State` and nowhere else.
struct KeepItemView: View {
  @ObservedObject var session: KeepSession
  let vault: KeepVaultDetail
  let item: KeepItemSummary
  let onChanged: () async -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var body_: KeepItemBody?
  @State private var error: String?
  @State private var showPassword = false
  @State private var editing = false
  @State private var confirmDelete = false
  @State private var copied: String?

  var body: some View {
    EnvisioningForm {
      if let body = body_ {
        Section {
          if !body.username.isEmpty { field("Username", body.username) }
          if !body.password.isEmpty { field(item.kind == .apiKey ? "Key" : "Password", body.password, masked: !showPassword, toggle: { showPassword.toggle() }) }
          if !body.url.isEmpty { field("URL", body.url) }
          if !body.totp.isEmpty {
            if let totp = KeepTOTP(body.totp) {
              KeepTOTPRow(totp: totp) { value in
                copyToPasteboard(value)
                copied = "Code copied"
                Task {
                  try? await Task.sleep(for: .seconds(1.8))
                  copied = nil
                }
              }
            } else {
              field("One-time code", body.totp, masked: true)
            }
          }
          if !body.notes.isEmpty { field("Notes", body.notes) }
        }
        Section {
          Text("\(item.kind.label) · added by \(item.createdBy) · \(keepWhen(item.createdAt))")
            .font(.footnote).foregroundStyle(crmSecondaryText)
        }
      } else if let error {
        Section { Text(error).foregroundStyle(EnvisioningSemantics.danger) }
      } else {
        Section { EnvisioningPlaceholderRows(count: 2) }
      }
    }
    .navigationTitle(item.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }.disabled(body_ == nil)
      }
      ToolbarItem(placement: .destructiveAction) {
        Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash").foregroundStyle(EnvisioningSemantics.danger) }
      }
    }
    .confirmationDialog("Delete “\(item.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        Task {
          do {
            try await session.deleteItem(item, in: vault)
            await onChanged()
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
      }
    } message: {
      Text("The activity log keeps its name.")
    }
    .sheet(isPresented: $editing) {
      if let body = body_ {
        KeepItemEditor(session: session, vault: vault, item: item, initial: body) {
          editing = false
          await onChanged()
          dismiss()
        }
      }
    }
    .overlay(alignment: .bottom) {
      if let copied {
        Text(copied)
          .font(.footnote)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(crmTileBackground, in: Capsule())
          .padding(.bottom, 12)
          .transition(.opacity)
      }
    }
    .task {
      do {
        body_ = try await session.open(item, in: vault)
      } catch {
        self.error = error.localizedDescription
      }
    }
    .onDisappear { body_ = nil }
  }

  @ViewBuilder
  private func field(_ label: String, _ value: String, masked: Bool = false, toggle: (() -> Void)? = nil) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(crmSecondaryText).textCase(.uppercase)
      HStack(alignment: .top) {
        Text(masked ? String(repeating: "•", count: min(value.count, 24)) : value)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let toggle {
          Button(masked ? "Show" : "Hide", action: toggle).buttonStyle(.borderless)
        }
        Button {
          copyToPasteboard(value)
          copied = "\(label) copied"
          Task {
            try? await Task.sleep(for: .seconds(1.8))
            copied = nil
          }
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
      }
    }
  }
}

/// Create or edit. Seals in `KeepSession`; the server receives ciphertext
/// and a name. Secret fields are secure fields; nothing is autocorrected.
struct KeepItemEditor: View {
  @ObservedObject var session: KeepSession
  let vault: KeepVaultDetail
  let item: KeepItemSummary?
  let initial: KeepItemBody
  let onSaved: () async -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var kind: KeepItemKind
  @State private var body_: KeepItemBody
  @State private var error: String?
  @State private var qrNotice: String?
  #if os(iOS)
    @State private var scanning = false
    @State private var choosingImage = false
  #endif

  init(session: KeepSession, vault: KeepVaultDetail, item: KeepItemSummary?, initial: KeepItemBody, onSaved: @escaping () async -> Void) {
    self.session = session
    self.vault = vault
    self.item = item
    self.initial = initial
    self.onSaved = onSaved
    _name = State(initialValue: item?.name ?? "")
    _kind = State(initialValue: item?.kind ?? .login)
    _body_ = State(initialValue: initial)
  }

  var body: some View {
    NavigationStack {
      EnvisioningForm {
        Section {
          TextField("Name", text: $name)
          Picker("Kind", selection: $kind) {
            ForEach(KeepItemKind.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        }
        Section {
          TextField("Username", text: $body_.username).autocorrectionDisabled()
          KeepSecretField(title: kind == .apiKey ? "Key" : "Password", text: $body_.password)
          Menu {
            ForEach(KeepPasswordPreset.all) { preset in
              Button(preset.title) { body_.password = KeepPasswordGenerator.generate(preset.options) }
            }
          } label: {
            Label("Generate", systemImage: "wand.and.stars")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          TextField("URL", text: $body_.url).autocorrectionDisabled()
          KeepSecretField(title: "One-time code secret or otpauth:// link", text: $body_.totp)
          if !body_.totp.isEmpty, KeepTOTP(body_.totp) == nil {
            Text("Not a one-time code secret. Paste the otpauth link or the base32 key.").font(.footnote).foregroundStyle(EnvisioningSemantics.danger)
          }
          HStack(spacing: 16) {
            #if os(iOS)
              if KeepQRCameraScanner.isAvailable {
                Button { scanning = true } label: { Label("Scan QR", systemImage: "qrcode.viewfinder") }.buttonStyle(.borderless)
              }
              Button { choosingImage = true } label: { Label("From photo", systemImage: "photo") }.buttonStyle(.borderless)
            #else
              Button {
                switch keepPickQRImage() {
                case .none: break
                case .some(.none): qrNotice = "No QR code in that picture."
                case .some(.some(let text)): took(qr: text)
                }
              } label: { Label("QR from picture…", systemImage: "qrcode.viewfinder") }.buttonStyle(.borderless)
              Button {
                if let text = keepReadQRFromPasteboard() { took(qr: text) } else { qrNotice = "No QR code on the clipboard. Screenshot it with ⌃⇧⌘4 first." }
              } label: { Label("QR from clipboard", systemImage: "doc.on.clipboard") }.buttonStyle(.borderless)
            #endif
          }
          if let qrNotice {
            Text(qrNotice).font(.footnote).foregroundStyle(crmSecondaryText)
          }
        }
        Section("Notes") {
          TextEditor(text: $body_.notes).frame(minHeight: 80).autocorrectionDisabled()
        }
        if let error {
          Section { Text(error).foregroundStyle(EnvisioningSemantics.danger).font(.footnote) }
        }
      }
      #if os(iOS)
      .textInputAutocapitalization(.never)
      #endif
      .navigationTitle(item == nil ? "New item" : "Edit item")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          KeepAsyncButton("Save") { await save() }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      #if os(iOS)
        .sheet(isPresented: $scanning) {
          NavigationStack {
            KeepQRCameraScanner { text in took(qr: text) }
              .ignoresSafeArea()
              .navigationTitle("Scan the QR code")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
          }
        }
        .sheet(isPresented: $choosingImage) {
          KeepQRImagePicker { text in
            choosingImage = false
            if let text { took(qr: text) } else { qrNotice = "No QR code in that photo." }
          }
          .ignoresSafeArea()
        }
      #endif
    }
    #if os(macOS)
    .frame(minWidth: 460, minHeight: 480)
    #endif
  }

  /// A scanned QR: an otpauth link fills the code field; anything else is
  /// said so, not guessed at.
  private func took(qr text: String) {
    if let totp = KeepTOTP(text) {
      body_.totp = totp.uri
      qrNotice = "One-time code added" + (totp.issuer.map { " for \($0)" } ?? "") + "."
      if name.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = totp.issuer { name = issuer }
      if body_.username.isEmpty, let account = totp.account { body_.username = account }
    } else {
      qrNotice = "That QR code is not a one-time code setup."
    }
  }

  private func save() async {
    error = nil
    // Whatever was pasted, store the canonical otpauth URI.
    if !body_.totp.isEmpty {
      guard let totp = KeepTOTP(body_.totp) else {
        error = "The one-time code secret is not valid."
        return
      }
      body_.totp = totp.uri
    }
    do {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      if let item {
        _ = try await session.updateItem(item, name: trimmed, kind: kind, body: body_, in: vault)
      } else {
        _ = try await session.createItem(name: trimmed, kind: kind, body: body_, in: vault)
      }
      await onSaved()
    } catch {
      self.error = error.localizedDescription
    }
  }
}


/// The current code, large, with the seconds left and a copy. Ticks once a
/// second; the secret never leaves the `KeepTOTP` it was parsed into.
struct KeepTOTPRow: View {
  let totp: KeepTOTP
  let onCopy: (String) -> Void
  @State private var now = Date()
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var code: String { totp.code(at: now) }
  private var remaining: Int { totp.secondsRemaining(at: now) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("One-time code").font(.caption).foregroundStyle(crmSecondaryText).textCase(.uppercase)
      HStack(spacing: 12) {
        Text(spaced(code))
          .font(.system(.title2, design: .monospaced).weight(.medium))
          .textSelection(.enabled)
        ZStack {
          Circle().stroke(EnvisioningSurface.border, lineWidth: 3)
          Circle()
            .trim(from: 0, to: CGFloat(remaining) / CGFloat(totp.period))
            .stroke(remaining <= 5 ? EnvisioningSemantics.danger : EnvisioningAccent.foreground, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Text("\(remaining)").font(.caption2).monospacedDigit().foregroundStyle(crmSecondaryText)
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel("\(remaining) seconds left")
        Spacer()
        Button { onCopy(code) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
      }
      if let issuer = totp.issuer ?? totp.account {
        Text(issuer).font(.footnote).foregroundStyle(crmSecondaryText)
      }
    }
    .onReceive(timer) { now = $0 }
  }

  private func spaced(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return String(code.prefix(3)) + " " + String(code.suffix(3))
  }
}
