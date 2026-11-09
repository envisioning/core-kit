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
// page's image, its title, its type and site, whether the page was read,
// the notes document it belongs to, and the subjects it is filed on. A save
// is outside knowledge (an article, a video, a talk, a book, a law); the
// type rule is `DocsLinkType`. The grid is the Links view on every host;
// the header sits in the editor above the person's notes. The image is the
// copy Docs keeps, fetched with the device's token; nothing here calls the
// site.

/// Every save as a card, newest first, under a type filter. Same contract
/// as `DocumentList`: the host decides what opening one means and which
/// verbs a card offers. `onOpenDocument` opens a save's notes document;
/// nil shows its title as text.
public struct LinkGrid: View {
  public let documents: [DocsDocumentSummary]
  public let client: DocsClient
  public let subjectNames: [String: String]
  public let selectedID: String?
  public let onOpen: (DocsDocumentSummary) -> Void
  public let cardMenu: ((DocsDocumentSummary) -> AnyView)?
  public let onOpenDocument: ((_ id: String, _ title: String) -> Void)?
  @State private var type: DocsLinkType?

  public init(
    documents: [DocsDocumentSummary],
    client: DocsClient,
    subjectNames: [String: String] = [:],
    selectedID: String? = nil,
    cardMenu: ((DocsDocumentSummary) -> AnyView)? = nil,
    onOpenDocument: ((_ id: String, _ title: String) -> Void)? = nil,
    onOpen: @escaping (DocsDocumentSummary) -> Void
  ) {
    self.documents = documents
    self.client = client
    self.subjectNames = subjectNames
    self.selectedID = selectedID
    self.cardMenu = cardMenu
    self.onOpenDocument = onOpenDocument
    self.onOpen = onOpen
  }

  private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12, alignment: .top)]

  /// How many saves of each type the list holds. A type with none is not offered.
  private static func counts(_ documents: [DocsDocumentSummary]) -> [DocsLinkType: Int] {
    documents.reduce(into: [:]) { counts, document in
      counts[document.linkType ?? .other, default: 0] += 1
    }
  }

  public var body: some View {
    let counts = Self.counts(documents)
    // The filter narrows the list; it never reorders it.
    let shown = type.map { type in documents.filter { ($0.linkType ?? .other) == type } } ?? documents
    VStack(spacing: 0) {
      HStack {
        Picker("Type", selection: $type) {
          Text("All types").tag(DocsLinkType?.none)
          ForEach(DocsLinkType.allCases.filter { counts[$0] != nil }, id: \.self) { option in
            Text("\(option.label) (\(counts[option] ?? 0))").tag(DocsLinkType?.some(option))
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      if shown.isEmpty {
        Text("Nothing matches.")
          .font(.callout)
          .foregroundStyle(EnvisioningSurface.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(shown) { document in
              LinkCard(
                document: document, client: client, subjectNames: subjectNames, isSelected: document.id == selectedID,
                onOpenNotes: onOpenDocument.map { open in { notes in open(notes.id, notes.title) } },
                onOpen: { onOpen(document) }
              )
              .modifier(CardMenu(menu: cardMenu.map { menu in { menu(document) } }))
            }
          }
          .padding(12)
        }
      }
    }
    .background(EnvisioningSurface.canvas)
    // A filter left on a type the new list no longer holds shows everything.
    .onChange(of: documents) { _, documents in
      if let type, Self.counts(documents)[type] == nil { self.type = nil }
    }
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

/// One save: the cover with Open page, title, type and site, whether the
/// page was read, the notes document, subjects. With `onOpen` the card is
/// the button, and Open page and the notes document stay their own
/// buttons; without it the host wraps the card.
public struct LinkCard: View {
  public let document: DocsDocumentSummary
  public let client: DocsClient
  public var subjectNames: [String: String] = [:]
  public var isSelected = false
  public var onOpenNotes: ((DocsLinkNotesDocument) -> Void)?
  public var onOpen: (() -> Void)?

  public init(
    document: DocsDocumentSummary, client: DocsClient, subjectNames: [String: String] = [:], isSelected: Bool = false,
    onOpenNotes: ((DocsLinkNotesDocument) -> Void)? = nil, onOpen: (() -> Void)? = nil
  ) {
    self.document = document
    self.client = client
    self.subjectNames = subjectNames
    self.isSelected = isSelected
    self.onOpenNotes = onOpenNotes
    self.onOpen = onOpen
  }

  public var body: some View {
    if let onOpen {
      // Not a Button: a button inside a button does not take its own click.
      card
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
    } else {
      card
    }
  }

  private var card: some View {
    let shape = RoundedRectangle(cornerRadius: EnvisioningRadius.control)
    return VStack(alignment: .leading, spacing: 0) {
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
      .overlay(alignment: .topTrailing) {
        if let page = document.linkPage {
          Link(destination: page) {
            Image(systemName: "arrow.up.right")
              .font(.caption.weight(.semibold))
              .padding(6)
              .background(EnvisioningSurface.panel.opacity(0.9), in: Circle())
          }
          .buttonStyle(.plain)
          .padding(6)
          .help("Open page")
          .accessibilityLabel("Open page")
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(document.title).font(.callout.weight(.semibold)).lineLimit(2)
        if let link = document.link {
          HStack(spacing: 4) {
            if link.pageNotRead {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(EnvisioningSemantics.danger)
            }
            Text([document.linkType?.label, link.site].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
          }
          .font(.caption)
          .foregroundStyle(EnvisioningSurface.secondaryText)
          LinkMarks(link: link)
          if let notes = link.notesDocuments?.first {
            LinkNotesLine(notes: notes, onOpen: onOpenNotes)
          }
        }
        if !document.subjects.isEmpty {
          SubjectChips(subjects: document.subjects, names: subjectNames)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(EnvisioningSurface.panel)
    .clipShape(shape)
    .overlay(shape.strokeBorder(isSelected ? EnvisioningSurface.borderHover : EnvisioningSurface.border, lineWidth: 1))
    .contentShape(shape)
  }
}

/// What is true of the page: Page not read, Paywalled. Nothing when neither is.
struct LinkMarks: View {
  let link: DocsLinkSave

  var body: some View {
    if link.pageNotRead || link.paywalled {
      HStack(spacing: 4) {
        if link.pageNotRead { LinkMark(text: "Page not read") }
        if link.paywalled { LinkMark(text: "Paywalled") }
      }
    }
  }
}

struct LinkMark: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(EnvisioningSurface.secondaryText)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .overlay(Capsule().strokeBorder(EnvisioningSurface.border))
  }
}

/// "Notes: <title>", the document a save belongs to. A button when the
/// host can open it.
struct LinkNotesLine: View {
  let notes: DocsLinkNotesDocument
  let onOpen: ((DocsLinkNotesDocument) -> Void)?

  var body: some View {
    HStack(spacing: 4) {
      Text("Notes:").foregroundStyle(EnvisioningSurface.secondaryText)
      if let onOpen {
        Button(notes.title) { onOpen(notes) }
          .buttonStyle(.borderless)
          .lineLimit(1)
      } else {
        Text(notes.title).lineLimit(1)
      }
    }
    .font(.caption)
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

/// Above a save's notes in the editor: the cover, its type and site, what
/// the page says it is, whether it was read, the notes document, Open page,
/// and Read again for a page that failed or changed.
public struct LinkHeader: View {
  public let document: DocsDocumentDetail
  public let client: DocsClient
  /// Read the page again. Nil hides the button: only Meet's Worker reads
  /// pages, so a host without it offers no Read again.
  public let refetch: ((String) async throws -> DocsDocumentDetail)?
  /// Open the notes document. Nil shows its title as text.
  public let onOpenDocument: ((_ id: String, _ title: String) -> Void)?
  public let onRefetched: (DocsDocumentDetail) -> Void
  @State private var refetching = false
  @State private var error: String?

  public init(
    document: DocsDocumentDetail,
    client: DocsClient,
    refetch: ((String) async throws -> DocsDocumentDetail)? = nil,
    onOpenDocument: ((_ id: String, _ title: String) -> Void)? = nil,
    onRefetched: @escaping (DocsDocumentDetail) -> Void
  ) {
    self.document = document
    self.client = client
    self.refetch = refetch
    self.onOpenDocument = onOpenDocument
    self.onRefetched = onRefetched
  }

  public var body: some View {
    if let link = document.link {
      HStack(alignment: .top, spacing: 12) {
        LinkCoverImage(documentID: document.id, hasImage: link.hasImage, firstImageID: document.images?.first?.id, client: client)
          .frame(width: 120, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: EnvisioningRadius.field))
        VStack(alignment: .leading, spacing: 4) {
          Text([document.linkType?.label, link.site].compactMap { $0 }.joined(separator: " · "))
            .font(.caption.weight(.semibold)).foregroundStyle(EnvisioningSurface.secondaryText)
          if let description = link.description {
            Text(description).font(.footnote).lineLimit(3)
          }
          if let message = error ?? (link.pageNotRead ? link.fetchError ?? "The page did not load." : nil) {
            EnvisioningErrorNotice(message).font(.caption)
          }
          LinkMarks(link: link)
          ForEach(link.notesDocuments ?? []) { notes in
            LinkNotesLine(notes: notes, onOpen: onOpenDocument.map { open in { open($0.id, $0.title) } })
          }
          HStack(spacing: 12) {
            if let url = document.linkPage {
              Link(destination: url) { Label("Open page", systemImage: "arrow.up.right.square") }
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

/// On a notes document: the saved links whose notes point at it. Read from
/// the Links list the device can already see, so a save the member cannot
/// read is never named. Nothing when none point here or the read fails.
public struct SavedLinksSection: View {
  public let documentID: String
  public let client: DocsClient
  public let onOpenDocument: ((_ id: String, _ title: String) -> Void)?
  @State private var links: [DocsDocumentSummary] = []

  public init(documentID: String, client: DocsClient, onOpenDocument: ((_ id: String, _ title: String) -> Void)? = nil) {
    self.documentID = documentID
    self.client = client
    self.onOpenDocument = onOpenDocument
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !links.isEmpty {
        Text("Saved links").font(.footnote.weight(.semibold))
        ForEach(links) { link in
          HStack(spacing: 6) {
            if let onOpenDocument {
              Button(link.title) { onOpenDocument(link.id, link.title) }
                .buttonStyle(.borderless)
                .lineLimit(1)
            } else {
              Text(link.title).lineLimit(1)
            }
            Text([link.linkType?.label, link.link?.site].compactMap { $0 }.joined(separator: " · "))
              .foregroundStyle(EnvisioningSurface.secondaryText)
              .lineLimit(1)
          }
          .font(.footnote)
        }
      }
    }
    .task(id: documentID) {
      let read = DocsListRead.links()
      if let cached = client.cachedDocuments(read) { links = pointingHere(cached) }
      // The section is extra: a failed read keeps what the cache showed.
      if let fresh = try? await client.documents(read) { links = pointingHere(fresh) }
    }
  }

  private func pointingHere(_ documents: [DocsDocumentSummary]) -> [DocsDocumentSummary] {
    documents.filter { $0.link?.notesDocuments?.contains(where: { $0.id == documentID }) == true }
  }
}
