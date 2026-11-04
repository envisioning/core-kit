import DocsKit
import EnvisioningUI
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Screenshots on a document (meet#345 slice 2). A strip of thumbnails under
// the title: Add picks files, Paste takes an image off the clipboard, a file
// dropped on the strip attaches, a thumbnail opens large. Every image goes
// through `DocsImagePrep` first — Docs has no image service.

public struct DocumentImagesStrip: View {
  public let documentID: String
  public let images: [DocsImage]
  public let client: DocsClient
  public let editable: Bool
  /// Something was added or removed; the host reloads the document.
  public let onChange: () -> Void

  @State private var importing = false
  @State private var uploading = false
  @State private var error: String?
  @State private var preview: DocsImage?

  public init(documentID: String, images: [DocsImage], client: DocsClient, editable: Bool, onChange: @escaping () -> Void) {
    self.documentID = documentID
    self.images = images
    self.client = client
    self.editable = editable
    self.onChange = onChange
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("Screenshots").font(.caption.weight(.semibold)).foregroundStyle(EnvisioningSurface.secondaryText)
        if uploading { ProgressView().controlSize(.small) }
        Spacer()
        if editable {
          Button { importing = true } label: { Label("Add", systemImage: "plus") }
            .help("Attach images")
          Button { pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            .help("Attach the image on the clipboard")
        }
      }
      .font(.footnote)
      .buttonStyle(.borderless)
      .disabled(uploading)

      if !images.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(images) { image in
              Button { preview = image } label: {
                thumbnail(image)
                  .frame(width: 112, height: 72)
                  .clipShape(RoundedRectangle(cornerRadius: EnvisioningRadius.field))
                  .overlay(RoundedRectangle(cornerRadius: EnvisioningRadius.field).strokeBorder(EnvisioningSurface.border, lineWidth: 1))
              }
              .buttonStyle(.plain)
              .help(image.caption ?? "Open")
              .accessibilityLabel(image.caption ?? "Screenshot")
            }
          }
        }
      } else if editable {
        Text("Drop images here, or paste one.")
          .font(.caption)
          .foregroundStyle(EnvisioningSurface.secondaryText)
      }

      if let error {
        EnvisioningErrorNotice(error).font(.caption)
      }
    }
    .contentShape(Rectangle())
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard editable, !files.isEmpty else { return false }
      Task { await attach(files: files) }
      return true
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result { Task { await attach(files: urls) } }
    }
    .sheet(item: $preview) { image in
      DocumentImagePreview(documentID: documentID, image: image, client: client, editable: editable) {
        preview = nil
        onChange()
      }
    }
  }

  private func thumbnail(_ image: DocsImage) -> some View {
    DocsRemoteImage(key: DocsRemoteImage.imageKey(image.id)) { [client, documentID] in
      try await client.imageData(documentID: documentID, imageID: image.id)
    }
  }

  private func pasteImage() {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
      ?? (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
        .first.flatMap { try? Data(contentsOf: $0) }
    #else
    let data = UIPasteboard.general.image?.pngData()
    #endif
    guard let data else {
      error = String(localized: "Copy an image first.")
      return
    }
    Task { await attach(data: [data]) }
  }

  private func attach(files: [URL]) async {
    var data: [Data] = []
    for url in files {
      // A file from the importer lives outside the sandbox until asked for.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      if let bytes = try? Data(contentsOf: url) { data.append(bytes) }
    }
    await attach(data: data)
  }

  private func attach(data: [Data]) async {
    guard !data.isEmpty else { return }
    uploading = true
    defer { uploading = false }
    error = nil
    for bytes in data {
      do {
        let prepared = try DocsImagePrep.prepare(bytes)
        _ = try await client.uploadImage(documentID: documentID, data: prepared.data, contentType: prepared.contentType)
      } catch {
        self.error = error.localizedDescription
      }
    }
    onChange()
  }
}

/// One image, large, with Remove for a document the person can edit.
struct DocumentImagePreview: View {
  let documentID: String
  let image: DocsImage
  let client: DocsClient
  let editable: Bool
  let onDone: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var removing = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 12) {
      DocsRemoteImage(key: DocsRemoteImage.imageKey(image.id)) { [client, documentID, image] in
        try await client.imageData(documentID: documentID, imageID: image.id)
      }
      .aspectRatio(contentMode: .fit)
      .frame(minWidth: 320, idealWidth: 720, maxWidth: 960, minHeight: 240, idealHeight: 480, maxHeight: 720)
      .clipShape(RoundedRectangle(cornerRadius: EnvisioningRadius.control))
      if let caption = image.caption {
        Text(caption).font(.footnote).foregroundStyle(EnvisioningSurface.secondaryText)
      }
      if let error {
        EnvisioningErrorNotice(error).font(.caption)
      }
      HStack {
        if editable {
          Button("Remove", role: .destructive) { Task { await remove() } }
            .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 32, expands: false))
            .disabled(removing)
        }
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 32, expands: false))
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .background(EnvisioningSurface.canvas)
  }

  private func remove() async {
    removing = true
    defer { removing = false }
    do {
      try await client.deleteImage(documentID: documentID, imageID: image.id)
      DocsRemoteImage.forget(DocsRemoteImage.imageKey(image.id))
      onDone()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
