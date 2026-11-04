import CoreKit
import EnvisioningUI
import SwiftUI

/// Renders a Markdown string as formatted, readable blocks.
///
/// `Text(AttributedString(markdown:))` on its own only styles *inline* runs —
/// it flattens block structure, so headings and bullets arrive as literal `##`
/// and `-` characters. Block prefixes are therefore split out here and laid out
/// as real blocks, with inline parsing (bold, italic, code, links) applied
/// within each one. Author line breaks are preserved rather than reflowed into
/// paragraphs: CRM notes are usually written as lines, not prose.
///
/// Supported blocks: headings, bullet and numbered lists, blockquotes, fenced
/// code, horizontal rules, and standalone images (`![alt](url)` on their own
/// line, loaded via `CachedRemoteImage`). This is a deliberately small reader,
/// not a full CommonMark engine — enough to make a Doc readable in-app.
///
/// Text selection is deliberately left to the caller — enabling it here would
/// swallow the tap that opens the editor on an editable field.
public struct MarkdownText: View {
  let markdown: String
  /// Each block takes its first source line as its id and the stack is a
  /// scroll target layout, so a host can scroll to a line and read which
  /// line is on top (`scrollPosition(id:)`).
  let anchored: Bool
  @Environment(\.markdownDocumentLinks) private var documentLinks

  public init(markdown: String, anchored: Bool = false) {
    self.markdown = markdown
    self.anchored = anchored
  }

  public var body: some View {
    if anchored {
      stack.scrollTargetLayout()
    } else {
      stack
    }
  }

  /// The first source line of every block, in order: what an anchored
  /// reader's ids are.
  public static func blockLines(_ markdown: String) -> [Int] {
    MarkdownText(markdown: markdown).blocks.map(\.line)
  }

  private var stack: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(blocks, id: \.line) { entry in
        view(entry.block).id(entry.line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
          Text(inline(text))
            .font(level <= 1 ? .title3 : (level == 2 ? .headline : .subheadline))
            .fontWeight(.semibold)
            .padding(.top, 4)
        case .bullet(let text):
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(crmSecondaryText)
            Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
          }
        case .ordered(let number, let text):
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").foregroundStyle(crmSecondaryText).monospacedDigit()
            Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
          }
        case .quote(let text):
          HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(.secondary).frame(width: 3)
            Text(inline(text))
              .foregroundStyle(crmSecondaryText)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        case .code(let text):
          Text(text)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(EnvisioningSurface.field, in: .rect(cornerRadius: 8))
            .textSelection(.enabled)
        case .image(let alt, let url):
          VStack(alignment: .leading, spacing: 4) {
            CachedRemoteImage(url: url)
              .frame(maxWidth: .infinity, alignment: .center)
              .clipShape(.rect(cornerRadius: EnvisioningRadius.field))
            if !alt.isEmpty {
              Text(alt).font(.caption).foregroundStyle(crmSecondaryText)
            }
          }
          .padding(.vertical, 2)
        case .documentImage(let alt, let id):
          VStack(alignment: .leading, spacing: 4) {
            if let image = documentLinks.image {
              image(id, alt)
            }
            if !alt.isEmpty {
              Text(alt).font(.caption).foregroundStyle(crmSecondaryText)
            }
          }
          .padding(.vertical, 2)
        case .rule:
          Divider().padding(.vertical, 4)
        case .paragraph(let text):
          Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
        case .blank:
          Color.clear.frame(height: 2)
        }
  }

  private enum Block {
    case heading(String, level: Int)
    case bullet(String)
    case ordered(Int, String)
    case quote(String)
    case code(String)
    case image(alt: String, url: URL)
    /// `![alt](docs-image:<id>)`: an image the document holds, drawn by the
    /// host (`MarkdownDocumentLinks.image`).
    case documentImage(alt: String, id: String)
    case rule
    case paragraph(String)
    case blank
  }

  private struct Entry {
    let line: Int
    let block: Block
  }

  private var blocks: [Entry] {
    var entries: [Entry] = []
    var codeLines: [String]?  // non-nil while inside a ``` fence
    var codeStart = 0
    var index = 0
    let lines = markdown.components(separatedBy: "\n")

    /// Appends at the line being read; a code block at its opening fence.
    func append(_ block: Block) {
      if case .code = block {
        entries.append(Entry(line: codeStart, block: block))
      } else {
        entries.append(Entry(line: index, block: block))
      }
    }

    for (lineIndex, rawLine) in lines.enumerated() {
      index = lineIndex
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Fenced code: everything between ``` markers is verbatim.
      if trimmed.hasPrefix("```") {
        if let collected = codeLines {
          append(.code(collected.joined(separator: "\n")))
          codeLines = nil
        } else {
          codeLines = []
          codeStart = lineIndex
        }
        continue
      }
      if codeLines != nil {
        codeLines?.append(line)
        continue
      }

      if trimmed.isEmpty {
        append(.blank)
        continue
      }
      // Horizontal rule: a line of only ---, ***, or ___.
      if trimmed.count >= 3, Set(trimmed) == ["-"] || Set(trimmed) == ["*"] || Set(trimmed) == ["_"] {
        append(.rule)
        continue
      }
      // Standalone image: the whole line is ![alt](url).
      if let image = Self.standaloneImage(trimmed) {
        append(image)
        continue
      }
      if trimmed.hasPrefix("#") {
        let hashes = trimmed.prefix { $0 == "#" }
        let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        // A bare "#…" with no space isn't a heading (e.g. a "#1" reference).
        if !text.isEmpty, trimmed.dropFirst(hashes.count).hasPrefix(" ") {
          append(.heading(text, level: hashes.count))
          continue
        }
      }
      if trimmed.hasPrefix("> ") {
        append(.quote(String(trimmed.dropFirst(2))))
        continue
      }
      if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        append(.bullet(String(trimmed.dropFirst(2))))
        continue
      }
      if let ordered = Self.orderedItem(trimmed) {
        append(ordered)
        continue
      }
      append(.paragraph(trimmed))
    }

    // An unterminated fence still renders its collected lines as code.
    if let collected = codeLines {
      append(.code(collected.joined(separator: "\n")))
    }
    return entries
  }

  /// Parses `![alt](url)` when it is the entire line, else `nil`.
  private static func standaloneImage(_ text: String) -> Block? {
    guard text.hasPrefix("!["), text.hasSuffix(")"),
      let altClose = text.range(of: "]("),
      altClose.upperBound < text.endIndex
    else { return nil }
    let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<altClose.lowerBound])
    let urlString = String(text[altClose.upperBound..<text.index(before: text.endIndex)])
      .trimmingCharacters(in: .whitespaces)
    if urlString.hasPrefix(MarkdownDocumentLinks.imageScheme + ":") {
      let id = String(urlString.dropFirst(MarkdownDocumentLinks.imageScheme.count + 1))
      return id.isEmpty ? nil : .documentImage(alt: alt, id: id)
    }
    guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
      return nil
    }
    return .image(alt: alt, url: url)
  }

  /// Parses `1. text` (or any `<digits>. text`), else `nil`.
  private static func orderedItem(_ text: String) -> Block? {
    let digits = text.prefix { $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    let rest = text.dropFirst(digits.count)
    guard rest.hasPrefix(". ") else { return nil }
    return .ordered(number, String(rest.dropFirst(2)))
  }

  /// Inline-only so the parser never swallows the block prefixes handled above.
  /// Falls back to the raw string when the markdown doesn't parse.
  private func inline(_ text: String) -> AttributedString {
    guard let resolve = documentLinks.wikilink, text.contains("[[") else {
      return Self.parseInline(Self.unwrapWikilinks(text))
    }
    // A wikilink the host can open is a link; one it cannot is its words,
    // muted. The text between them parses as usual.
    var result = AttributedString()
    var rest = text[...]
    for match in text.matches(of: Self.wikilinkPattern) {
      result += Self.parseInline(String(rest[rest.startIndex..<match.range.lowerBound]))
      let target = String(match.output.1).trimmingCharacters(in: .whitespaces)
      var label = AttributedString(String(match.output.2 ?? match.output.1))
      if let url = resolve(target) {
        label.link = url
      } else {
        label.foregroundColor = crmSecondaryText
      }
      result += label
      rest = text[match.range.upperBound...]
    }
    result += Self.parseInline(String(rest))
    return result
  }

  private static func parseInline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }

  private static let wikilinkPattern = #/\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]/#

  /// `[[Target]]` reads as "Target" and `[[Target|Shown]]` as "Shown": vault
  /// links name a document this reader cannot open, so it shows the words,
  /// not the brackets.
  public static func unwrapWikilinks(_ text: String) -> String {
    guard text.contains("[[") else { return text }
    return text.replacing(#/\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]/#) { match in
      String(match.output.2 ?? match.output.1)
    }
  }
}

/// What a host lends `MarkdownText` for the parts of a document only it can
/// draw or open: images the document holds (`![alt](docs-image:<id>)`) and
/// wikilinks (`[[Title]]`, `[[Title|label]]`). Without it, a document image
/// shows its alt text and a wikilink its words.
public struct MarkdownDocumentLinks {
  /// The scheme of an image a document holds: `docs-image:<imageId>`. The
  /// same on every client.
  public static let imageScheme = "docs-image"

  /// Draws one held image by id, with its alt text.
  public var image: ((_ id: String, _ alt: String) -> AnyView)?
  /// The URL that opens a wikilink's target through `openURL`, or nil when
  /// the target is no document (drawn muted).
  public var wikilink: ((_ target: String) -> URL?)?

  public init(
    image: ((_ id: String, _ alt: String) -> AnyView)? = nil, wikilink: ((_ target: String) -> URL?)? = nil
  ) {
    self.image = image
    self.wikilink = wikilink
  }
}

extension EnvironmentValues {
  public var markdownDocumentLinks: MarkdownDocumentLinks {
    get { self[MarkdownDocumentLinksKey.self] }
    set { self[MarkdownDocumentLinksKey.self] = newValue }
  }
}

private struct MarkdownDocumentLinksKey: EnvironmentKey {
  static let defaultValue = MarkdownDocumentLinks()
}
