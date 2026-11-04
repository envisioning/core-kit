#if os(macOS)
import AppKit
import EnvisioningUI

/// Styles markdown source in place, the way Obsidian and iA Writer do: the
/// text stays the markdown that is stored, and headings, emphasis, code,
/// links, lists and quotes take their look as they are typed. The markup
/// characters stay in the text, quieter than the words they mark.
///
/// Type and spacing are the reader's (`MarkdownText`): body for a line,
/// title 3 / headline / subheadline for headings, callout monospaced for
/// code, six points between lines. So Edit and Done move nothing but the
/// markup. Colours are EnvisioningUI's tokens and follow the appearance.
@MainActor
enum MarkdownStyler {
  // MARK: Type

  static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }
  static var codeFont: NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
  }

  static func headingFont(level: Int) -> NSFont {
    let style: NSFont.TextStyle = level <= 1 ? .title3 : (level == 2 ? .headline : .subheadline)
    let base = NSFont.preferredFont(forTextStyle: style)
    return NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
  }

  static var text: NSColor { EnvisioningSurface.nsColor(.primaryText) }
  static var muted: NSColor { EnvisioningSurface.nsColor(.secondaryText) }
  static var codeGround: NSColor { EnvisioningSurface.nsColor(.field) }

  /// The reader's six points between lines.
  static let lineGap: CGFloat = 6

  static var paragraph: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = lineGap
    return style
  }

  static var baseAttributes: [NSAttributedString.Key: Any] {
    [.font: bodyFont, .foregroundColor: text, .paragraphStyle: paragraph]
  }

  // MARK: Passes

  /// Style the whole text.
  static func styleAll(_ storage: NSTextStorage) {
    style(storage, lines: NSRange(location: 0, length: storage.length))
  }

  /// Style what an edit touched: its lines, or everything after it when the
  /// edit opened or closed a code fence (a fence changes every line below).
  static func styleEdit(_ storage: NSTextStorage, editedRange: NSRange, fencesMoved: Bool) {
    let string = storage.string as NSString
    let location = min(editedRange.location, string.length)
    let length = min(editedRange.length, string.length - location)
    var lines = string.lineRange(for: NSRange(location: location, length: length))
    if fencesMoved {
      lines = NSRange(location: lines.location, length: string.length - lines.location)
    }
    style(storage, lines: lines)
  }

  /// How many fence lines the text holds; a change means every line below
  /// the edit may have moved in or out of code.
  static func fenceCount(_ string: NSString) -> Int {
    var count = 0
    string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) {
      _, range, _, _ in
      if string.substring(with: range).trimmingCharacters(in: .whitespaces).hasPrefix("```") { count += 1 }
    }
    return count
  }

  /// Style a run of whole lines. Whether a line sits inside a fence depends
  /// on every line above it, so the fences above are counted first.
  static func style(_ storage: NSTextStorage, lines range: NSRange) {
    let string = storage.string as NSString
    guard string.length > 0 else { return }
    var inFence = fenceOpen(before: range.location, in: string)
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: range)
    var location = range.location
    let end = range.location + range.length
    while location < end {
      let line = string.lineRange(for: NSRange(location: location, length: 0))
      let content = contentRange(of: line, in: string)
      let text = string.substring(with: content)
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        storage.addAttributes([.font: codeFont, .foregroundColor: muted], range: content)
        inFence.toggle()
      } else if inFence {
        storage.addAttributes([.font: codeFont, .backgroundColor: codeGround], range: content)
      } else {
        styleLine(storage, text: text, at: content.location)
      }
      location = line.location + max(line.length, 1)
    }
    storage.endEditing()
  }

  private static func fenceOpen(before location: Int, in string: NSString) -> Bool {
    guard location > 0 else { return false }
    var open = false
    string.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) {
      _, range, _, _ in
      if string.substring(with: range).trimmingCharacters(in: .whitespaces).hasPrefix("```") { open.toggle() }
    }
    return open
  }

  private static func contentRange(of line: NSRange, in string: NSString) -> NSRange {
    var length = line.length
    while length > 0 {
      let c = string.character(at: line.location + length - 1)
      guard c == 10 || c == 13 else { break }
      length -= 1
    }
    return NSRange(location: line.location, length: length)
  }

  // MARK: One line

  private static func styleLine(_ storage: NSTextStorage, text: String, at start: Int) {
    let ns = text as NSString
    let full = NSRange(location: start, length: ns.length)
    let leading = ns.length - (text.drop { $0 == " " || $0 == "\t" } as Substring).utf16.count

    // Horizontal rule.
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 3, Set(trimmed) == ["-"] || Set(trimmed) == ["*"] || Set(trimmed) == ["_"] {
      storage.addAttribute(.foregroundColor, value: muted, range: full)
      return
    }

    var body = NSRange(location: start + leading, length: ns.length - leading)
    if let match = firstMatch(heading, in: text) {
      let level = match.range(at: 1).length
      storage.addAttribute(.font, value: headingFont(level: level), range: full)
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 0), by: start))
      body = NSRange(location: start + match.range.length, length: ns.length - match.range.length)
    } else if let match = firstMatch(quote, in: text) {
      storage.addAttribute(.foregroundColor, value: muted, range: full)
      body = NSRange(location: start + match.range.length, length: ns.length - match.range.length)
    } else if let match = firstMatch(listItem, in: text) {
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 1), by: start))
      body = NSRange(location: start + match.range.length, length: ns.length - match.range.length)
    }
    styleInline(storage, line: text, lineStart: start, body: body)
  }

  private static func styleInline(_ storage: NSTextStorage, line: String, lineStart: Int, body: NSRange) {
    let local = NSRange(location: body.location - lineStart, length: body.length)
    // Code first: nothing inside a code span is markup.
    var codeSpans: [NSRange] = []
    for match in inlineCode.matches(in: line, range: local) {
      let range = shifted(match.range, by: lineStart)
      codeSpans.append(match.range)
      storage.addAttributes([.font: codeFont, .backgroundColor: codeGround], range: range)
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 1), by: lineStart))
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 3), by: lineStart))
    }
    func free(_ range: NSRange) -> Bool { !codeSpans.contains { NSIntersectionRange($0, range).length > 0 } }

    for match in bold.matches(in: line, range: local) where free(match.range) {
      let font = storage.attribute(.font, at: lineStart + match.range.location, effectiveRange: nil) as? NSFont ?? bodyFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: shifted(match.range, by: lineStart))
      muteMarks(storage, match, lineStart: lineStart)
    }
    for match in italic.matches(in: line, range: local) where free(match.range) {
      let font = storage.attribute(.font, at: lineStart + match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? bodyFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: shifted(match.range(at: 2), by: lineStart))
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 1), by: lineStart))
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 3), by: lineStart))
    }
    for match in wikilink.matches(in: line, range: local) where free(match.range) {
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range, by: lineStart))
      storage.addAttributes(
        [.foregroundColor: text, .underlineStyle: NSUnderlineStyle.single.rawValue],
        range: shifted(match.range(at: 1), by: lineStart))
    }
    for match in link.matches(in: line, range: local) where free(match.range) {
      // `![alt](url)` and `[label](url)`: the label reads, the rest is markup.
      storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range, by: lineStart))
      storage.addAttributes(
        [.foregroundColor: text, .underlineStyle: NSUnderlineStyle.single.rawValue],
        range: shifted(match.range(at: 2), by: lineStart))
    }
  }

  private static func muteMarks(_ storage: NSTextStorage, _ match: NSTextCheckingResult, lineStart: Int) {
    storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 1), by: lineStart))
    storage.addAttribute(.foregroundColor, value: muted, range: shifted(match.range(at: 3), by: lineStart))
  }

  private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
    NSRange(location: range.location + offset, length: range.length)
  }

  private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  // MARK: Patterns

  private static let heading = try! NSRegularExpression(pattern: #"^\s*(#{1,6})\s+"#)
  private static let quote = try! NSRegularExpression(pattern: #"^\s*>\s?"#)
  private static let listItem = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#)
  private static let inlineCode = try! NSRegularExpression(pattern: #"(`)([^`\n]+)(`)"#)
  private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
  private static let italic = try! NSRegularExpression(
    pattern: #"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)(?![*_\w])"#)
  private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\[\]]+?)\]\]"#)
  private static let link = try! NSRegularExpression(pattern: #"(!?)\[([^\[\]]*)\]\(([^()\s]*)\)"#)
}
#endif
