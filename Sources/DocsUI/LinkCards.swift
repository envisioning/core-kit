import DocsKit
import EnvisioningUI
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// Link saves (meet#345): a URL a person dropped, drawn as a card — the
// page's image, its title, the site, and the subjects it is filed on. The
// grid is the Links view on every host; the header sits in the editor above
// the person's notes. The image is the copy Docs keeps, fetched with the
// device's token; nothing here calls the site.

/// Every save as a card, newest first. Same contract as `DocumentList`: the
/// host decides what opening one means and which verbs a card offers.
public struct LinkGrid: View {
  public let documents: [DocsDocumentSummary]
  public let client: DocsClient
  public let subjectNames: [String: String]
  public let selectedID: String?
  public let onOpen: (DocsDocumentSummary) -> Void
  public let cardMenu: ((DocsDocumentSummary) -> AnyView)?

  public init(
    documents: [DocsDocumentSummary],
    client: DocsClient,
    subjectNames: [String: String] = [:],
    selectedID: String? = nil,
    cardMenu: ((DocsDocumentSummary) -> AnyView)? = nil,
    onOpen: @escaping (DocsDocumentSummary) -> Void
  ) {
    self.documents = documents
    self.client = client
    self.subjectNames = subjectNames
    self.selectedID = selectedID
    self.cardMenu = cardMenu
    self.onOpen = onOpen
  }

  private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12, alignment: .top)]

  public var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(documents) { document in
          Button { onOpen(document) } label: {
            LinkCard(document: document, client: client, subjectNames: subjectNames, isSelected: document.id == selectedID)
          }
          .buttonStyle(.plain)
          .modifier(CardMenu(menu: cardMenu.map { menu in { menu(document) } }))
        }
      }
      .padding(12)
    }
    .background(EnvisioningSurface.canvas)
  }
}

private struct CardMenu: ViewModifier {
  let menu: (() -> AnyView)?

  func body(content: Content) -> some View {
    if let menu {
      content.contextMenu { menu() }
    } else {
      content
    }
  }
}

/// One save: cover, title, site, subjects.
public struct LinkCard: View {
  public let document: DocsDocumentSummary
  public let client: DocsClient
  public var subjectNames: [String: String] = [:]
  public var isSelected = false

  public init(document: DocsDocumentSummary, client: DocsClient, subjectNames: [String: String] = [:], isSelected: Bool = false) {
    self.document = document
    self.client = client
    self.subjectNames = subjectNames
    self.isSelected = isSelected
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      LinkCoverImage(
        documentID: document.id, hasImage: document.link?.hasImage == true,
        firstImageID: document.link?.firstImageId, client: client
      )
      .frame(height: 120)
      .frame(maxWidth: .infinity)
      .clipped()
      .overlay(alignment: .bottomTrailing) {
        if let count = document.link?.imageCount, count > 0 {
          Label("\(count)", systemImage: "photo.on.rectangle")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(EnvisioningSurface.panel.opacity(0.9), in: Capsule())
            .padding(6)
            .help("\(count) screenshot\(count == 1 ? "" : "s")")
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(document.title).font(.callout.weight(.semibold)).lineLimit(2)
        if let link = document.link {
          HStack(spacing: 4) {
            if link.fetchStatus == "failed" {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(EnvisioningSemantics.danger)
            }
            Text(link.site).lineLimit(1)
          }
          .font(.caption)
          .foregroundStyle(EnvisioningSurface.secondaryText)
        }
        if !document.subjects.isEmpty {
          SubjectChips(subjects: document.subjects, names: subjectNames)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(EnvisioningSurface.panel)
    .clipShape(RoundedRectangle(cornerRadius: EnvisioningRadius.control))
    .overlay(
      RoundedRectangle(cornerRadius: EnvisioningRadius.control)
        .strokeBorder(isSelected ? EnvisioningSurface.borderHover : EnvisioningSurface.border, lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: EnvisioningRadius.control))
  }
}

/// The card's cover: the copy of the page's image Docs keeps, else the first
/// screenshot the person attached, else a quiet link glyph.
public struct LinkCoverImage: View {
  public let documentID: String
  public let hasImage: Bool
  public let firstImageID: String?
  public let client: DocsClient

  public init(documentID: String, hasImage: Bool, firstImageID: String? = nil, client: DocsClient) {
    self.documentID = documentID
    self.hasImage = hasImage
    self.firstImageID = firstImageID
    self.client = client
  }

  public var body: some View {
    if hasImage {
      DocsRemoteImage(key: Self.coverKey(documentID), symbol: "link") { [client, documentID] in
        try await client.linkImage(id: documentID)
      }
    } else if let firstImageID {
      DocsRemoteImage(key: DocsRemoteImage.imageKey(firstImageID), symbol: "link") { [client, documentID] in
        try await client.imageData(documentID: documentID, imageID: firstImageID)
      }
    } else {
      DocsRemoteImage.placeholder(symbol: "link")
    }
  }

  /// Drop a cover after Read again replaced it.
  public static func forget(_ documentID: String) {
    DocsRemoteImage.forget(coverKey(documentID))
  }

  static func coverKey(_ documentID: String) -> String { "cover:\(documentID)" }
}

/// An image Docs holds, loaded with the device's token and kept in memory
/// for the session by `key`. Fills its frame; the host sizes and clips it.
public struct DocsRemoteImage: View {
  public let key: String
  public let symbol: String
  public let load: @Sendable () async throws -> Data
  @State private var image: PlatformImage?

  public init(key: String, symbol: String = "photo", load: @escaping @Sendable () async throws -> Data) {
    self.key = key
    self.symbol = symbol
    self.load = load
  }

  public var body: some View {
    ZStack {
      EnvisioningSurface.elevated
      if let image {
        #if os(macOS)
        Image(nsImage: image).resizable().scaledToFill()
        #else
        Image(uiImage: image).resizable().scaledToFill()
        #endif
      } else {
        Image(systemName: symbol).font(.title2).foregroundStyle(EnvisioningSurface.secondaryText)
      }
    }
    .task(id: key) {
      if let cached = DocsImageCache.shared.object(forKey: key as NSString) {
        image = cached
        return
      }
      image = nil
      guard let data = try? await load(), let loaded = PlatformImage(data: data) else { return }
      DocsImageCache.shared.setObject(loaded, forKey: key as NSString)
      image = loaded
    }
  }

  static func placeholder(symbol: String) -> some View {
    ZStack {
      EnvisioningSurface.elevated
      Image(systemName: symbol).font(.title2).foregroundStyle(EnvisioningSurface.secondaryText)
    }
  }

  public static func imageKey(_ imageID: String) -> String { "image:\(imageID)" }

  public static func forget(_ key: String) {
    DocsImageCache.shared.removeObject(forKey: key as NSString)
  }
}

enum DocsImageCache {
  static let shared: NSCache<NSString, PlatformImage> = {
    let cache = NSCache<NSString, PlatformImage>()
    cache.countLimit = 400
    return cache
  }()
}

/// Above a save's notes in the editor: the cover, what the page says it is,
/// Open, and Read again for a page that failed or changed.
public struct LinkHeader: View {
  public let document: DocsDocumentDetail
  public let client: DocsClient
  /// Read the page again. Nil hides the button: only Meet's Worker reads
  /// pages, so a host without it offers no Read again.
  public let refetch: ((String) async throws -> DocsDocumentDetail)?
  public let onRefetched: (DocsDocumentDetail) -> Void
  @State private var refetching = false
  @State private var error: String?

  public init(
    document: DocsDocumentDetail,
    client: DocsClient,
    refetch: ((String) async throws -> DocsDocumentDetail)? = nil,
    onRefetched: @escaping (DocsDocumentDetail) -> Void
  ) {
    self.document = document
    self.client = client
    self.refetch = refetch
    self.onRefetched = onRefetched
  }

  public var body: some View {
    if let link = document.link {
      HStack(alignment: .top, spacing: 12) {
        LinkCoverImage(documentID: document.id, hasImage: link.hasImage, firstImageID: document.images?.first?.id, client: client)
          .frame(width: 120, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: EnvisioningRadius.field))
        VStack(alignment: .leading, spacing: 4) {
          Text(link.site).font(.caption.weight(.semibold)).foregroundStyle(EnvisioningSurface.secondaryText)
          if let description = link.description {
            Text(description).font(.footnote).lineLimit(3)
          }
          if let message = error ?? (link.fetchStatus == "failed" ? link.fetchError ?? "The page did not load." : nil) {
            EnvisioningErrorNotice(message).font(.caption)
          }
          HStack(spacing: 12) {
            if let url = link.openURL {
              Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }
            }
            if refetch != nil {
              Button {
                Task { await readAgain() }
              } label: {
                Label(refetching ? "Reading…" : "Read again", systemImage: "arrow.clockwise")
              }
              .disabled(refetching)
            }
          }
          .font(.footnote)
          .buttonStyle(.borderless)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func readAgain() async {
    guard let refetch else { return }
    refetching = true
    defer { refetching = false }
    do {
      let updated = try await refetch(document.id)
      LinkCoverImage.forget(document.id)
      error = nil
      onRefetched(updated)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
