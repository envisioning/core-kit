import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI

/// Send a document for signature: one address per signer, a subject, a note.
/// Docs mails each signer their own link; they prove the address with a code
/// and sign the exact bytes on the server. The sheet shows the requests that
/// exist and lets one be cancelled — the record itself is never edited.
public struct SignatureSheet: View {
  public let documentID: String
  public let documentTitle: String
  public let client: DocsClient
  public let onToast: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var signers = ""
  @State private var subject = ""
  @State private var message = ""
  @State private var working = false
  @State private var sent: DocsSignatureRequest?

  public init(documentID: String, documentTitle: String, client: DocsClient, onToast: @escaping (String) -> Void = { _ in }) {
    self.documentID = documentID
    self.documentTitle = documentTitle
    self.client = client
    self.onToast = onToast
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Send for signature").font(.headline)
        Text(documentTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
      }

      if let sent {
        VStack(alignment: .leading, spacing: 6) {
          Label("Sent", systemImage: "checkmark.seal")
          ForEach(sent.parties) { party in
            HStack {
              Text(party.email)
              Spacer()
              Text(party.status.capitalized).foregroundStyle(.secondary)
            }
            .font(.footnote)
          }
          Text("Each signer got their own link by mail. The request expires \(sent.expiresAt.map { "on " + String($0.prefix(10)) } ?? "in 30 days").")
            .font(.footnote).foregroundStyle(.secondary)
        }
      } else {
        TextField("Signers — one address per line", text: $signers, axis: .vertical)
          .coreField()
          .lineLimit(2...5)
        TextField("Subject (optional)", text: $subject)
          .coreField()
        TextField("A note to the signers (optional)", text: $message, axis: .vertical)
          .coreField()
          .lineLimit(2...4)
        Text("Signers sign this exact version. Edit the document afterwards and the signature stays on the version they saw.")
          .font(.footnote).foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button(sent == nil ? "Cancel" : "Done") { dismiss() }
          .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 32, expands: false))
          .keyboardShortcut(.cancelAction)
        if sent == nil {
          Button("Send") { Task { await send() } }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 32, expands: false))
            .keyboardShortcut(.defaultAction)
            .disabled(working || parties.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 440)
  }

  private var parties: [DocsCreateSignatureRequest.Party] {
    signers
      .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" || $0 == " " })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.contains("@") }
      .map { DocsCreateSignatureRequest.Party(email: $0) }
  }

  private func send() async {
    working = true
    defer { working = false }
    do {
      sent = try await client.createSignatureRequest(
        for: documentID,
        DocsCreateSignatureRequest(
          subject: subject.isEmpty ? nil : subject,
          message: message.isEmpty ? nil : message,
          parties: parties))
      onToast("Sent to \(parties.count) signer\(parties.count == 1 ? "" : "s")")
    } catch {
      onToast(error.localizedDescription)
    }
  }
}
