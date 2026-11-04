import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI

/// Comments on a document — Docs annotations (meet#175 slice 3): the
/// threads, a reply, resolve / reopen by any member, and a new thread on
/// the document. Passage anchors are the web's for now: SwiftUI's `Text`
/// exposes no selection range, so a comment written here has no anchor
/// and reads as being on the whole document; one written on the web
/// shows its quote.
public struct CommentsPane: View {
  @StateObject private var model: CommentsModel
  @State private var composing = false
  @State private var showResolved = false

  public init(documentID: String, client: DocsClient) {
    _model = StateObject(wrappedValue: CommentsModel(documentID: documentID, client: client))
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Comments")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        if !model.open.isEmpty {
          Text("\(model.open.count)").font(.footnote).foregroundStyle(.secondary)
        }
        Spacer()
        if !model.resolved.isEmpty {
          Button(showResolved ? "Hide resolved" : "\(model.resolved.count) resolved") { showResolved.toggle() }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        Button { composing = true } label: { Image(systemName: "plus.bubble") }
          .buttonStyle(.borderless)
          .help("New comment")
          .disabled(composing)
      }

      if let errorMessage = model.errorMessage {
        EnvisioningErrorNotice(errorMessage) { Task { await model.load() } }.font(.footnote)
      }

      if composing {
        Composer(placeholder: "Comment on this document", submit: "Comment") { body in
          await model.post(body, parentId: nil)
          composing = false
        } cancel: {
          composing = false
        }
      }

      if model.loaded, model.threads.isEmpty, !composing {
        Text("No comments yet.").font(.footnote).foregroundStyle(.secondary)
      }

      ForEach(model.open) { thread in
        ThreadView(thread: thread, model: model)
      }
      if showResolved {
        ForEach(model.resolved) { thread in
          ThreadView(thread: thread, model: model)
        }
      }
    }
    .task(id: model.documentID) { await model.load() }
  }
}

private struct ThreadView: View {
  let thread: DocsThread
  @ObservedObject var model: CommentsModel
  @State private var replying = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let quote = thread.root.anchor?.quote, !quote.isEmpty {
        Text(quote)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .strikethrough(thread.root.orphaned == true)
          .padding(.leading, 8)
          .overlay(alignment: .leading) {
            Rectangle().fill(thread.root.orphaned == true ? Color.secondary.opacity(0.3) : Color.accentColor).frame(width: 2)
          }
      }
      if thread.root.orphaned == true {
        Text("This passage is no longer in the document.").font(.caption).foregroundStyle(.secondary)
      }
      CommentView(annotation: thread.root)
      ForEach(thread.replies) { reply in
        CommentView(annotation: reply).padding(.leading, 12)
      }
      HStack(spacing: 12) {
        if !replying {
          Button("Reply") { replying = true }
        }
        if thread.isOpen {
          Button("Resolve") { Task { await model.setStatus(thread, "resolved") } }
        } else {
          Button("Reopen") { Task { await model.setStatus(thread, "open") } }
        }
      }
      .buttonStyle(.borderless)
      .font(.footnote)
      if replying {
        Composer(placeholder: "Reply", submit: "Reply") { body in
          await model.post(body, parentId: thread.root.id)
          replying = false
        } cancel: {
          replying = false
        }
      }
    }
    .padding(10)
    .background(crmTileBackground, in: RoundedRectangle(cornerRadius: 10))
    .opacity(thread.isOpen ? 1 : 0.7)
  }
}

private struct CommentView: View {
  let annotation: DocsAnnotation

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(annotation.who).font(.footnote.weight(.semibold))
        if annotation.authorKind == "agent" {
          Text("AGENT")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
        }
        if let when = DocumentEditor.updatedLabel(annotation.createdAt) {
          Text(when).font(.caption).foregroundStyle(.secondary)
        }
      }
      MarkdownText(markdown: annotation.bodyMd)
        .font(.footnote)
        .textSelection(.enabled)
    }
  }
}

private struct Composer: View {
  let placeholder: String
  let submit: String
  let onSubmit: (String) async -> Void
  let cancel: () -> Void
  @State private var text = ""
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(placeholder, text: $text, axis: .vertical)
        .coreField()
        .lineLimit(2...6)
      HStack {
        Button(submit) {
          let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !body.isEmpty else { return }
          busy = true
          Task {
            await onSubmit(body)
            text = ""
            busy = false
          }
        }
        .buttonStyle(EnvisioningFilledButtonStyle(expands: false))
        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", action: cancel).buttonStyle(.borderless)
      }
    }
  }
}

@MainActor
final class CommentsModel: ObservableObject {
  let documentID: String
  private let client: DocsClient
  @Published private(set) var annotations: [DocsAnnotation] = []
  @Published private(set) var loaded = false
  @Published private(set) var errorMessage: String?

  init(documentID: String, client: DocsClient) {
    self.documentID = documentID
    self.client = client
  }

  var threads: [DocsThread] { DocsThread.threads(annotations) }
  var open: [DocsThread] { threads.filter(\.isOpen) }
  var resolved: [DocsThread] { threads.filter { !$0.isOpen } }

  func load() async {
    do {
      annotations = try await client.annotations(for: documentID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    loaded = true
  }

  func post(_ body: String, parentId: String?) async {
    do {
      let created = try await client.createAnnotation(for: documentID, DocsCreateAnnotation(bodyMd: body, parentId: parentId))
      annotations.append(created)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setStatus(_ thread: DocsThread, _ status: String) async {
    do {
      let updated = try await client.updateAnnotation(id: thread.root.id, DocsUpdateAnnotation(status: status))
      annotations = annotations.map { $0.id == updated.id ? updated : $0 }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
