import Foundation

/// Passwords for items. One generator, a small options struct, and named
/// presets — adding a preset is one line, adding a knob is one field.
public struct KeepPasswordOptions: Equatable, Sendable {
  public enum Style: String, CaseIterable, Sendable {
    /// One run of characters.
    case characters
    /// Groups of four joined by dashes, readable aloud.
    case groups
    /// Digits only — a PIN.
    case digits
  }

  public var style: Style
  public var length: Int
  public var uppercase: Bool
  public var digits: Bool
  public var symbols: Bool
  /// Drop 0/O, 1/l/I and the like.
  public var avoidAmbiguous: Bool

  public init(style: Style = .characters, length: Int = 20, uppercase: Bool = true, digits: Bool = true, symbols: Bool = true, avoidAmbiguous: Bool = true) {
    self.style = style
    self.length = length
    self.uppercase = uppercase
    self.digits = digits
    self.symbols = symbols
    self.avoidAmbiguous = avoidAmbiguous
  }

  public static let strong = KeepPasswordOptions()
  public static let long = KeepPasswordOptions(length: 32)
  public static let readable = KeepPasswordOptions(style: .groups, length: 20, uppercase: false, digits: true, symbols: false)
  public static let pin = KeepPasswordOptions(style: .digits, length: 6, uppercase: false, digits: true, symbols: false, avoidAmbiguous: false)
  /// For a vendor that refuses symbols.
  public static let alphanumeric = KeepPasswordOptions(length: 24, symbols: false)
}

public struct KeepPasswordPreset: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let options: KeepPasswordOptions
  public init(id: String, title: String, options: KeepPasswordOptions) {
    self.id = id
    self.title = title
    self.options = options
  }

  /// The menu, in order. Extend here.
  public static let all: [KeepPasswordPreset] = [
    .init(id: "strong", title: "Strong · 20", options: .strong),
    .init(id: "long", title: "Long · 32", options: .long),
    .init(id: "alnum", title: "No symbols · 24", options: .alphanumeric),
    .init(id: "readable", title: "Readable groups", options: .readable),
    .init(id: "pin", title: "PIN · 6 digits", options: .pin),
  ]
}

public enum KeepPasswordGenerator {
  private static let lower = "abcdefghijklmnopqrstuvwxyz"
  private static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  private static let digitChars = "0123456789"
  private static let symbolChars = "!#$%&*+-=?@^_~"
  private static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "|"]

  public static func generate(_ options: KeepPasswordOptions) -> String {
    switch options.style {
    case .digits:
      return String(pick(from: Array(digitChars), count: max(4, options.length)))
    case .groups:
      let alphabet = alphabet(for: options)
      let groups = max(2, options.length / 4)
      return (0..<groups).map { _ in String(pick(from: alphabet, count: 4)) }.joined(separator: "-")
    case .characters:
      let alphabet = alphabet(for: options)
      var result: [Character]
      // Keep drawing until every enabled class is present, so a vendor's
      // "must contain a digit" rule never bounces a generated password.
      repeat {
        result = pick(from: alphabet, count: max(8, options.length))
      } while !satisfies(result, options)
      return String(result)
    }
  }

  private static func alphabet(for options: KeepPasswordOptions) -> [Character] {
    var set = lower
    if options.uppercase { set += upper }
    if options.digits { set += digitChars }
    if options.symbols { set += symbolChars }
    var chars = Array(set)
    if options.avoidAmbiguous { chars.removeAll { ambiguous.contains($0) } }
    return chars
  }

  private static func satisfies(_ chars: [Character], _ options: KeepPasswordOptions) -> Bool {
    if options.uppercase, !chars.contains(where: { $0.isUppercase }) { return false }
    if options.digits, !chars.contains(where: { $0.isNumber }) { return false }
    if options.symbols, !chars.contains(where: { symbolChars.contains($0) }) { return false }
    return true
  }

  /// Uniform picks: rejection sampling over a byte, so no modulo bias.
  private static func pick(from alphabet: [Character], count: Int) -> [Character] {
    precondition(!alphabet.isEmpty && alphabet.count <= 256)
    let limit = 256 - (256 % alphabet.count)
    var out: [Character] = []
    out.reserveCapacity(count)
    while out.count < count {
      let bytes = KeepCrypto.randomBytes(count * 2)
      for byte in bytes where Int(byte) < limit {
        out.append(alphabet[Int(byte) % alphabet.count])
        if out.count == count { break }
      }
    }
    return out
  }
}
