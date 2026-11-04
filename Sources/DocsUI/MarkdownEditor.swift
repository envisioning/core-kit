#if os(macOS)
import AppKit
import CoreCRMUI
import SwiftUI
import UniformTypeIdentifiers

/// What the document view asks of the open markdown editor: scroll to a
/// line, report where it is. Held by the document view; the editor fills
/// in `textView` when it is made.
@MainActor
final class MarkdownEditorController {
  weak var textView: DocsMarkdownTextView?

  /// The first line in view, zero-based.
  var topLine: Int {
    guard let textView else { return 0 }
    return textView.topVisibleLine()
  }

  func scroll(toLine line: Int) {
    textView?.scroll(toLine: line)
  }

  func focus() {
    guard let textView else { return }
    textView.window?.makeFirstResponder(textView)
  }

  /// Swap an upload's placeholder for its markdown, as one undo step that
  /// leaves the caret alone. False when the editor is closed or the
  /// placeholder is gone.
  func replace(_ placeholder: String, with text: String) -> Bool {
    guard let textView else { return false }
    let range = (textView.string as NSString).range(of: placeholder)
    guard range.location != NSNotFound else { return false }
    let selection = textView.selectedRange()
    guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
    textView.textStorage?.replaceCharacters(in: range, with: text)
    textView.didChangeText()
    let delta = (text as NSString).length - range.length
    let location = selection.location >= range.location + range.length ? selection.location + delta : selection.location
    textView.setSelectedRange(NSRange(location: max(0, location), length: selection.length))
    return true
  }
}

/// The markdown source, styled as it is typed (`MarkdownStyler`), in an
/// `NSTextView`: native undo, find (⌘F, the find bar), spelling. The text
/// column is the reader's: at most `readingWidth` wide, centred, never less
/// than 24 points from an edge, so it fits a 280-point inspector and widens
/// with the window.
struct MarkdownEditor: NSViewRepresentable {
  @Binding var text: String
  let readingWidth: CGFloat
  let controller: MarkdownEditorController
  /// The line to show first, zero-based.
  let startLine: Int
  /// Esc and ⌘E.
  let onDone: () -> Void
  /// ⌘S: save now.
  let onSave: () -> Void
  /// An image pasted or dropped, with its caption and its placeholder.
  var onImage: ((Data, String, String) -> Void)?
  /// Titles for `[[` completion.
  var linkTitles: (() -> [String])?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder

    let textView = DocsMarkdownTextView(frame: .zero)
    textView.readingWidth = readingWidth
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isContinuousSpellCheckingEnabled = true
    // The source is markdown: what is typed is what is stored.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.typingAttributes = MarkdownStyler.baseAttributes
    textView.insertionPointColor = MarkdownStyler.text
    textView.string = text
    textView.textStorage?.delegate = context.coordinator
    MarkdownStyler.styleAll(textView.textStorage!)
    context.coordinator.fences = MarkdownStyler.fenceCount(text as NSString)
    textView.delegate = context.coordinator
    textView.onDone = onDone
    textView.onSave = onSave
    textView.onImage = onImage
    textView.linkTitles = linkTitles

    scroll.documentView = textView
    controller.textView = textView
    let line = startLine
    DispatchQueue.main.async {
      textView.updateInsets()
      if line > 0 { textView.scroll(toLine: line) }
      textView.window?.makeFirstResponder(textView)
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? DocsMarkdownTextView else { return }
    textView.onDone = onDone
    textView.onSave = onSave
    textView.onImage = onImage
    textView.linkTitles = linkTitles
    textView.readingWidth = readingWidth
    controller.textView = textView
    // A change from outside (a restored draft, Use theirs): replace the text,
    // keep the caret where it can stay.
    if textView.string != text, !context.coordinator.editing {
      let selection = textView.selectedRange()
      textView.string = text
      MarkdownStyler.styleAll(textView.textStorage!)
      context.coordinator.fences = MarkdownStyler.fenceCount(text as NSString)
      let length = (text as NSString).length
      textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    var parent: MarkdownEditor
    var fences = 0
    /// True while a keystroke travels to the binding, so the binding's echo
    /// is not taken for a change from outside.
    var editing = false

    init(_ parent: MarkdownEditor) {
      self.parent = parent
    }

    nonisolated func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
      changeInLength delta: Int
    ) {
      guard editedMask.contains(.editedCharacters) else { return }
      MainActor.assumeIsolated {
        let count = MarkdownStyler.fenceCount(textStorage.string as NSString)
        let moved = count != fences
        fences = count
        MarkdownStyler.styleEdit(textStorage, editedRange: editedRange, fencesMoved: moved)
      }
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      editing = true
      parent.text = textView.string
      editing = false
    }
  }
}

/// The text view the editor hosts: the reading column as insets, Esc and
/// ⌘E for Done, ⌘S to save, ⌘F for the find bar.
final class DocsMarkdownTextView: NSTextView {
  var readingWidth: CGFloat = 720 {
    didSet { if oldValue != readingWidth { updateInsets() } }
  }
  var onDone: (() -> Void)?
  var onSave: (() -> Void)?

  /// The reader's margin: 24 points a side at least.
  static let margin: CGFloat = 24
  /// Under the header the reader leaves 20 points; the header's own 12 are
  /// above this view.
  static let topInset: CGFloat = 8

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateInsets()
  }

  func updateInsets() {
    let side = max(Self.margin, (bounds.width - readingWidth) / 2)
    let inset = NSSize(width: side, height: Self.topInset)
    if textContainerInset != inset { textContainerInset = inset }
  }

  /// An image pasted or dropped: its bytes, its caption, and the placeholder
  /// text standing in for it until the upload answers.
  var onImage: ((_ data: Data, _ caption: String, _ placeholder: String) -> Void)?
  /// Document titles for `[[` completion.
  var linkTitles: (() -> [String])?

  override func cancelOperation(_ sender: Any?) {
    if let onDone { onDone() } else { super.cancelOperation(sender) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
      switch key {
      case "f":
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
        return true
      case "s":
        onSave?()
        return true
      case "e":
        onDone?()
        return true
      case "b":
        toggleWrap("**")
        return true
      case "i":
        toggleWrap("*")
        return true
      case "k":
        insertLink(url: Self.pasteboardURL(NSPasteboard.general))
        return true
      default:
        break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  // MARK: Edits

  /// Replace a range the way typing does: one undo step, then the caret
  /// (or a selection) where `select` says, in the new text.
  func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
    guard shouldChangeText(in: range, replacementString: text) else { return }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    setSelectedRange(select ?? NSRange(location: range.location + (text as NSString).length, length: 0))
  }

  /// ⌘B and ⌘I: wrap the selection in the mark, or take the mark off.
  func toggleWrap(_ mark: String) {
    let ns = string as NSString
    let range = selectedRange()
    let m = (mark as NSString).length
    // Already wrapped just outside the selection: unwrap.
    if range.location >= m, range.location + range.length + m <= ns.length,
      ns.substring(with: NSRange(location: range.location - m, length: m)) == mark,
      ns.substring(with: NSRange(location: range.location + range.length, length: m)) == mark
    {
      let outer = NSRange(location: range.location - m, length: range.length + 2 * m)
      replace(outer, with: ns.substring(with: range), select: NSRange(location: outer.location, length: range.length))
      return
    }
    let selected = ns.substring(with: range)
    if range.length > 2 * m, selected.hasPrefix(mark), selected.hasSuffix(mark) {
      let inner = String(selected.dropFirst(mark.count).dropLast(mark.count))
      replace(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length))
      return
    }
    replace(range, with: mark + selected + mark, select: NSRange(location: range.location + m, length: range.length))
  }

  /// ⌘K: the selection becomes a link's label. A URL on the clipboard fills
  /// the address; otherwise the caret waits in the parentheses.
  func insertLink(url: String?) {
    let range = selectedRange()
    let label = (string as NSString).substring(with: range)
    let address = url ?? ""
    let text = "[\(label)](\(address))"
    let labelLength = (label as NSString).length
    if label.isEmpty {
      replace(range, with: text, select: NSRange(location: range.location + 1, length: 0))
    } else if address.isEmpty {
      replace(range, with: text, select: NSRange(location: range.location + labelLength + 3, length: 0))
    } else {
      replace(range, with: text)
    }
  }

  static func pasteboardURL(_ pasteboard: NSPasteboard) -> String? {
    guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.contains(where: \.isWhitespace),
      let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto"].contains(scheme)
    else { return nil }
    return text
  }

  // MARK: Lists and quotes

  private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?"#)
  private static let quoteMark = try! NSRegularExpression(pattern: #"^(\s*>\s?)"#)

  private func currentLine() -> (range: NSRange, text: String) {
    let ns = string as NSString
    let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    var content = line
    while content.length > 0, [10, 13].contains(ns.character(at: content.location + content.length - 1)) {
      content.length -= 1
    }
    return (content, ns.substring(with: content))
  }

  /// Return continues a list item or a quote; on an empty item it ends the
  /// list instead.
  override func insertNewline(_ sender: Any?) {
    let selection = selectedRange()
    let (line, text) = currentLine()
    let full = NSRange(location: 0, length: (text as NSString).length)
    if selection.length == 0, let match = Self.listItem.firstMatch(in: text, range: full) {
      if match.range.length == full.length {
        replace(line, with: "")
        return
      }
      let ns = text as NSString
      let indent = ns.substring(with: match.range(at: 1))
      var marker = ns.substring(with: match.range(at: 2))
      if match.range(at: 3).location != NSNotFound, let number = Int(ns.substring(with: match.range(at: 3))) {
        marker = "\(number + 1)" + ns.substring(with: match.range(at: 4))
      }
      let checkbox = match.range(at: 6).location != NSNotFound ? "[ ] " : ""
      replace(selection, with: "\n" + indent + marker + " " + checkbox)
      return
    }
    if selection.length == 0, let match = Self.quoteMark.firstMatch(in: text, range: full) {
      if match.range.length == full.length {
        replace(line, with: "")
        return
      }
      replace(selection, with: "\n" + (text as NSString).substring(with: match.range(at: 1)))
      return
    }
    super.insertNewline(sender)
  }

  /// Tab and ⇧Tab indent and outdent list items; elsewhere a tab is a tab.
  override func insertTab(_ sender: Any?) {
    guard indentListLines(by: 2) else { return super.insertTab(sender) }
  }

  override func insertBacktab(_ sender: Any?) {
    guard indentListLines(by: -2) else { return super.insertBacktab(sender) }
  }

  private func indentListLines(by step: Int) -> Bool {
    let ns = string as NSString
    let selection = selectedRange()
    let lines = ns.lineRange(for: selection)
    let block = ns.substring(with: lines)
    var parts = block.components(separatedBy: "\n")
    let trailingNewline = block.hasSuffix("\n")
    if trailingNewline { parts.removeLast() }
    guard !parts.isEmpty, parts.allSatisfy({
      Self.listItem.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
    }) else { return false }
    var shift = 0
    let changed = parts.enumerated().map { index, part -> String in
      if step > 0 {
        if index == 0 { shift = step }
        return String(repeating: " ", count: step) + part
      }
      let spaces = min(-step, part.prefix { $0 == " " }.count)
      if index == 0 { shift = -spaces }
      return String(part.dropFirst(spaces))
    }
    let text = changed.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    let select = selection.length == 0
      ? NSRange(location: max(lines.location, selection.location + shift), length: 0)
      : NSRange(location: lines.location, length: (text as NSString).length - (trailingNewline ? 1 : 0))
    replace(lines, with: text, select: select)
    return true
  }

  // MARK: Paste and drop

  /// An image on the clipboard uploads into the document; a URL pasted over
  /// a selection makes it a link. Anything else pastes as plain text.
  override func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if onImage != nil, let images = Self.images(on: pasteboard), !images.isEmpty {
      insertImages(images, at: selectedRange())
      return
    }
    if selectedRange().length > 0, let url = Self.pasteboardURL(pasteboard) {
      insertLink(url: url)
      return
    }
    pasteAsPlainText(sender)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if onImage != nil, Self.images(on: sender.draggingPasteboard, filesOnly: true)?.isEmpty == false { return .copy }
    return super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if onImage != nil, Self.images(on: sender.draggingPasteboard, filesOnly: true)?.isEmpty == false {
      return .copy
    }
    return super.draggingUpdated(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard onImage != nil, let images = Self.images(on: sender.draggingPasteboard, filesOnly: true), !images.isEmpty
    else { return super.performDragOperation(sender) }
    let point = convert(sender.draggingLocation, from: nil)
    let index = characterIndexForInsertion(at: point)
    window?.makeFirstResponder(self)
    insertImages(images, at: NSRange(location: index, length: 0))
    return true
  }

  /// Image files first (named by their file), then image data when the
  /// clipboard holds no text: a copy from Word carries a picture of its text.
  static func images(on pasteboard: NSPasteboard, filesOnly: Bool = false) -> [(data: Data, caption: String)]? {
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
      let images = urls.compactMap { url -> (Data, String)? in
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
          let data = try? Data(contentsOf: url)
        else { return nil }
        return (data, url.deletingPathExtension().lastPathComponent)
      }
      if !images.isEmpty { return images.map { (data: $0.0, caption: $0.1) } }
    }
    if filesOnly || pasteboard.string(forType: .string) != nil { return nil }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      return [(data: data, caption: "Image")]
    }
    return nil
  }

  /// Each image on its own line as a placeholder, then the upload.
  private func insertImages(_ images: [(data: Data, caption: String)], at range: NSRange) {
    let ns = string as NSString
    var text = ""
    var placeholders: [(Data, String, String)] = []
    for image in images {
      let caption = Self.caption(image.caption)
      let placeholder = "![Uploading \(caption)…](\(MarkdownDocumentLinks.imageScheme):uploading-\(UUID().uuidString.prefix(8)))"
      placeholders.append((image.data, caption, placeholder))
      text += placeholder + "\n"
    }
    if range.location > 0, ns.character(at: range.location - 1) != 10 { text = "\n" + text }
    replace(range, with: text)
    for (data, caption, placeholder) in placeholders { onImage?(data, caption, placeholder) }
  }

  /// Alt text that cannot break the markdown around it.
  static func caption(_ raw: String) -> String {
    let cleaned = raw.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
      .components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Image" : cleaned
  }

  // MARK: Wikilink completion

  /// Typing `[[` offers the workspace's document titles.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    guard linkTitles != nil, (string as? String) == "[" || (string as? NSAttributedString)?.string == "[" else { return }
    let ns = self.string as NSString
    let caret = selectedRange().location
    if caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[[" {
      complete(nil)
    }
  }

  /// The typed part of an open `[[…`, up to the caret.
  private func wikilinkPartial() -> NSRange? {
    let ns = string as NSString
    let caret = selectedRange().location
    let line = ns.lineRange(for: NSRange(location: caret, length: 0))
    let before = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
    guard let open = before.range(of: "[[", options: .backwards) else { return nil }
    let typed = before[open.upperBound...]
    guard !typed.contains("]"), !typed.contains("|"), !typed.contains("[") else { return nil }
    let length = (String(typed) as NSString).length
    return NSRange(location: caret - length, length: length)
  }

  override var rangeForUserCompletion: NSRange {
    if linkTitles != nil, let partial = wikilinkPartial() { return partial }
    return super.rangeForUserCompletion
  }

  override func completions(
    forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
  ) -> [String]? {
    guard let titles = linkTitles?(), let partial = wikilinkPartial(), partial == charRange else {
      return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
    }
    let typed = (string as NSString).substring(with: partial).lowercased()
    let starts = titles.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
    let contains = typed.isEmpty ? [] : titles.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
    index.pointee = 0
    return Array((starts + contains).prefix(30))
  }

  override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
    guard flag, movement != NSTextMovement.cancel.rawValue, linkTitles != nil, wikilinkPartial() != nil else {
      return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }
    let ns = string as NSString
    // The partial now reads as the candidate shown; replace from `[[` on.
    let caret = selectedRange().location
    let start = charRange.location
    let end = max(caret, start + charRange.length)
    let closes = end + 2 <= ns.length && ns.substring(with: NSRange(location: end, length: 2)) == "]]"
    replace(NSRange(location: start, length: end - start), with: word + (closes ? "" : "]]"))
    if closes { setSelectedRange(NSRange(location: start + (word as NSString).length + 2, length: 0)) }
  }

  /// The first line in view, zero-based.
  func topVisibleLine() -> Int {
    guard let layoutManager, let textContainer, let scroll = enclosingScrollView else { return 0 }
    let visible = scroll.contentView.bounds
    let point = NSPoint(x: textContainerInset.width + 1, y: max(0, visible.minY - textContainerInset.height) + 1)
    let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
    let character = layoutManager.characterIndexForGlyph(at: glyph)
    return Self.line(at: character, in: string as NSString)
  }

  func scroll(toLine line: Int) {
    guard let layoutManager, let textContainer, let scroll = enclosingScrollView else { return }
    let ns = string as NSString
    let location = Self.location(ofLine: line, in: ns)
    layoutManager.ensureLayout(for: textContainer)
    let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
    let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 0), in: textContainer)
    let y = max(0, rect.minY + textContainerInset.height - Self.topInset)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  static func line(at location: Int, in string: NSString) -> Int {
    var line = 0
    var index = 0
    let end = min(location, string.length)
    while index < end {
      let range = string.lineRange(for: NSRange(location: index, length: 0))
      if range.location + range.length > end { break }
      line += 1
      index = range.location + max(range.length, 1)
    }
    return line
  }

  static func location(ofLine line: Int, in string: NSString) -> Int {
    var index = 0
    var current = 0
    while current < line, index < string.length {
      let range = string.lineRange(for: NSRange(location: index, length: 0))
      index = range.location + max(range.length, 1)
      current += 1
    }
    return min(index, string.length)
  }
}
#endif
