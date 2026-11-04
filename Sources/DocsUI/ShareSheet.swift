import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Two doors out of Docs. The www page: one switch, one link, an email gate
/// on the other side, every visit logged to the CRM. Grants: a revocable
/// link, optionally bound to an address — Docs has had the model since the
/// start; this is the first client to show it.
public struct ShareSheet: View {
  public let documentID: String
  public let documentTitle: String
  public let client: DocsClient
  public let onToast: (String) -> Void
  /// The detail Docs returned after the www switch moved, so the host's copy
  /// of the document agrees with the sheet.
  public let onVisibilityChange: (DocsDocumentDetail) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var visibility: String
  @State private var switching = false
  @State private var grants: [DocsGrant] = []
  @State private var loaded = false
  @State private var errorMessage: String?
  /// The last switch, link or revoke that failed: red, with Copy, in the sheet.
  @State private var actionError: String?
  @State private var role: DocsGrantRole = .viewer
  @State private var email = ""
  @State private var working = false
  /// The access log, newest first (envisioning/starlings#1045). Nil until read.
  @State private var events: [DocsAccessEvent]?
  @State private var eventsError: String?

  public init(
    documentID: String, documentTitle: String, visibility: String = DocsVisibility.internalOnly, client: DocsClient,
    onToast: @escaping (String) -> Void = { _ in }, onVisibilityChange: @escaping (DocsDocumentDetail) -> Void = { _ in }
  ) {
    self.documentID = documentID
    self.documentTitle = documentTitle
    self.client = client
    self.onToast = onToast
    self.onVisibilityChange = onVisibilityChange
    _visibility = State(initialValue: visibility)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Share").font(.headline)
        Text(documentTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
      }

      wwwSection

      Divider()

      HStack(spacing: 8) {
        DocsMenuPicker(
          selection: $role,
          options: [.init(value: .viewer, label: "Can view"), .init(value: .commenter, label: "Can comment")]
        ) {
          Text(role == .viewer ? "Can view" : "Can comment")
        }
        .help("Role")
        TextField("Anyone with the link, or an address", text: $email)
          .coreField()
        Button("Create link") { Task { await create() } }
          .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 30, expands: false))
          .disabled(working)
      }
      Text(email.isEmpty ? "Anyone holding the link can open it." : "Only \(email) can open it; they prove the address with a mailed code.")
        .font(.footnote).foregroundStyle(.secondary)

      if let actionError {
        EnvisioningErrorNotice(actionError).font(.footnote)
      }

      Divider()

      if let errorMessage {
        EnvisioningErrorNotice(errorMessage) { Task { await load() } }.font(.footnote)
      } else if !loaded {
        EnvisioningPlaceholderRows(count: 1)
      } else if live.isEmpty {
        Text("No links yet.").font(.footnote).foregroundStyle(.secondary)
      } else {
        ForEach(live) { grant in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(grant.email ?? "Anyone with the link").font(.body).lineLimit(1)
              Text("\(grant.role.rawValue.capitalized) · used \(grant.useCount)×").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button { copy(grant.url) } label: { Image(systemName: "doc.on.doc") }
              .buttonStyle(.borderless).help("Copy link")
            Button { Task { await revoke(grant) } } label: { Image(systemName: "xmark.circle") }
              .buttonStyle(.borderless).help("Revoke")
          }
        }
      }

      Divider()

      activitySection

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 32, expands: false))
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 440)
    .task { await load() }
  }

  private var live: [DocsGrant] { grants.filter { $0.revokedAt == nil } }
  private var shared: Bool { DocsVisibility.isShared(visibility) }
  private var wwwLink: String { DocsShareLink.www(documentID: documentID).absoluteString }

  /// The www switch. `public` counts as on and is left alone when toggled
  /// off — off always means `internal`.
  private var wwwSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: Binding(get: { shared }, set: { on in Task { await setShared(on) } })) {
        Text("Share on envisioning.com")
      }
      .toggleStyle(.envisioningSwitch)
      .disabled(switching)
      if shared {
        HStack(spacing: 8) {
          Text(wwwLink)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Spacer(minLength: 0)
          Button { copy(wwwLink) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy link")
        }
        Text("Anyone with the link can read it after entering their email. Each visit is logged to the CRM.")
          .font(.footnote).foregroundStyle(.secondary)
      } else {
        Text("Off: the document is staff-only. Links below still work.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private func setShared(_ on: Bool) async {
    switching = true
    actionError = nil
    defer { switching = false }
    let next = on ? DocsVisibility.link : DocsVisibility.internalOnly
    do {
      let updated = try await client.setVisibility(id: documentID, next)
      visibility = updated.visibility
      onVisibilityChange(updated)
      if on { copy(wwwLink) }
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func load() async {
    do {
      grants = try await client.grants(for: documentID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    loaded = true
    await loadActivity()
  }

  private func loadActivity() async {
    do {
      events = try await client.accessEvents(for: documentID)
      eventsError = nil
    } catch {
      eventsError = error.localizedDescription
    }
  }

  /// Who opened the document and which links they clicked: who, what, where, when.
  @ViewBuilder
  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Activity").font(.subheadline.weight(.semibold))
      if let eventsError {
        EnvisioningErrorNotice(eventsError) { Task { await loadActivity() } }.font(.footnote)
      } else if let events {
        if events.isEmpty {
          Text("No activity yet.").font(.footnote).foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(events) { event in
                HStack(spacing: 8) {
                  Text(event.who).lineLimit(1).truncationMode(.middle).help(event.actor ?? "")
                  Spacer(minLength: 4)
                  Text(event.kindLabel).lineLimit(1).truncationMode(.middle).help(event.href ?? "")
                  if let place = event.city ?? event.timezone {
                    Text(place).foregroundStyle(.secondary).lineLimit(1)
                  }
                  if let date = event.date {
                    Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                .font(.footnote)
              }
            }
          }
          .frame(maxHeight: 180)
        }
      } else {
        EnvisioningPlaceholderRows(count: 2)
      }
    }
  }

  private func create() async {
    working = true
    actionError = nil
    defer { working = false }
    let address = email.trimmingCharacters(in: .whitespaces)
    do {
      let grant = try await client.createGrant(
        for: documentID,
        DocsCreateGrant(role: role, email: address.isEmpty ? nil : address, requireVerification: address.isEmpty ? nil : true))
      grants.insert(grant, at: 0)
      copy(grant.url)
      email = ""
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func revoke(_ grant: DocsGrant) async {
    do {
      try await client.revokeGrant(id: grant.id)
      grants.removeAll { $0.id == grant.id }
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func copy(_ url: String) {
    DocsPasteboard.copy(url)
    onToast("Link copied")
  }
}

/// One clipboard call for both platforms.
public enum DocsPasteboard {
  public static func copy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
  }
}
