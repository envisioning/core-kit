import CoreCRMUI
import DocsKit
import EnvisioningUI
import SwiftUI

/// What a document's markdown says about its own shape: its headings and
/// how many words it holds. Code fences are skipped; a `#` in code is code.
enum DocsOutline {
  struct Heading: Identifiable, Equatable {
    /// Zero-based source line: the reader's block id and the editor's line.
    let line: Int
    let level: Int
    let title: String
    var id: Int { line }
  }

  static func headings(_ markdown: String) -> [Heading] {
    var headings: [Heading] = []
    var inFence = false
    for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      guard !inFence, trimmed.hasPrefix("#") else { continue }
      let hashes = trimmed.prefix { $0 == "#" }
      let rest = trimmed.dropFirst(hashes.count)
      guard hashes.count <= 6, rest.hasPrefix(" ") else { continue }
      let title = rest.trimmingCharacters(in: .whitespaces)
      guard !title.isEmpty else { continue }
      headings.append(Heading(line: index, level: hashes.count, title: MarkdownText.unwrapWikilinks(title)))
    }
    return headings
  }

  /// Words a person wrote: runs that hold a letter or a digit, so a list
  /// marker or a `#` does not count.
  static func wordCount(_ markdown: String) -> Int {
    markdown.split(whereSeparator: \.isWhitespace).reduce(0) { count, token in
      token.contains(where: { $0.isLetter || $0.isNumber }) ? count + 1 : count
    }
  }
}

/// The URL a resolved wikilink opens: `docs-document:<id>?title=<target>`.
/// Only the document view reads it, through its `openURL` action.
enum DocsWikilinkURL {
  static let scheme = "docs-document"

  static func make(id: String, title: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.path = id
    components.queryItems = [URLQueryItem(name: "title", value: title)]
    return components.url
  }

  static func parse(_ url: URL) -> (id: String, title: String)? {
    guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      !components.path.isEmpty
    else { return nil }
    let title = components.queryItems?.first { $0.name == "title" }?.value ?? ""
    return (components.path, title)
  }

  /// Wikilink targets compare without case and outer space.
  static func normalized(_ target: String) -> String {
    target.trimmingCharacters(in: .whitespaces).lowercased()
  }
}

/// An image the document holds, in the body at reading width: loaded
/// through Docs, kept in the shared image cache, and red with Copy when it
/// does not load.
struct DocsBodyImage: View {
  let documentID: String
  let imageID: String
  let alt: String
  let client: DocsClient
  @State private var image: PlatformImage?
  @State private var failure: String?

  var body: some View {
    Group {
      if let image {
        #if os(macOS)
        Image(nsImage: image).resizable().scaledToFit()
        #else
        Image(uiImage: image).resizable().scaledToFit()
        #endif
      } else if let failure {
        EnvisioningErrorNotice(failure).font(.caption)
      } else {
        RoundedRectangle(cornerRadius: EnvisioningRadius.field)
          .fill(EnvisioningSurface.elevated)
          .frame(height: 120)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: 640, alignment: .leading)
    .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    .task(id: imageID) { await load() }
  }

  private func load() async {
    let key = DocsRemoteImage.imageKey(imageID) as NSString
    if let cached = DocsImageCache.shared.object(forKey: key) {
      image = cached
      return
    }
    // A placeholder still uploading has no image yet.
    guard !imageID.hasPrefix("uploading-") else { return }
    do {
      let data = try await client.imageData(documentID: documentID, imageID: imageID)
      guard let loaded = PlatformImage(data: data) else {
        failure = "That image could not be read."
        return
      }
      DocsImageCache.shared.setObject(loaded, forKey: key)
      image = loaded
      failure = nil
    } catch {
      failure = "Couldn’t load the image: \(error.localizedDescription)"
    }
  }
}
