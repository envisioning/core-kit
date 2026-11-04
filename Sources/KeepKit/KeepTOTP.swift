import CryptoKit
import Foundation

/// RFC 6238 time-based one-time codes from an `otpauth://totp/…` URI or a
/// bare base32 secret, as 1Password exports them. Computed on the device
/// from the sealed secret; the server never sees the secret or a code.
public struct KeepTOTP: Equatable, Sendable {
  public enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

  public let secret: Data
  public let digits: Int
  public let period: Int
  public let algorithm: Algorithm
  public let issuer: String?
  public let account: String?

  /// Parses an `otpauth://totp/` URI, or a bare base32 secret (spaces allowed).
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().hasPrefix("otpauth://") {
      guard let components = URLComponents(string: trimmed), components.host?.lowercased() == "totp" else { return nil }
      let items = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
      guard let secretText = items["secret"], let secret = KeepTOTP.base32Decode(secretText), !secret.isEmpty else { return nil }
      self.secret = secret
      digits = Int(items["digits"] ?? "") ?? 6
      period = Int(items["period"] ?? "") ?? 30
      algorithm = Algorithm(rawValue: (items["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
      let label = components.path.dropFirst().removingPercentEncoding ?? ""
      let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      issuer = items["issuer"] ?? (parts.count == 2 ? parts[0] : nil)
      account = parts.count == 2 ? parts[1] : (parts.first ?? nil)
    } else {
      guard let secret = KeepTOTP.base32Decode(trimmed), !secret.isEmpty else { return nil }
      self.secret = secret
      digits = 6
      period = 30
      algorithm = .sha1
      issuer = nil
      account = nil
    }
  }

  /// The code for `date`, zero-padded to `digits`.
  public func code(at date: Date = Date()) -> String {
    let counter = UInt64(date.timeIntervalSince1970) / UInt64(period)
    var message = counter.bigEndian
    let data = Data(bytes: &message, count: 8)
    let key = SymmetricKey(data: secret)
    let mac: [UInt8]
    switch algorithm {
    case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
    case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
    case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: data, using: key))
    }
    let offset = Int(mac[mac.count - 1] & 0x0f)
    let binary =
      (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    let modulo = UInt32(pow(10, Double(digits)))
    return String(format: "%0\(digits)d", binary % modulo)
  }

  /// Seconds until the current code changes.
  public func secondsRemaining(at date: Date = Date()) -> Int {
    period - Int(date.timeIntervalSince1970) % period
  }

  /// A canonical URI for storage, from whatever the person pasted.
  public var uri: String {
    var components = URLComponents()
    components.scheme = "otpauth"
    components.host = "totp"
    let label = [issuer, account].compactMap { $0 }.joined(separator: ":")
    components.path = "/" + (label.isEmpty ? "Keep" : label)
    var items = [URLQueryItem(name: "secret", value: KeepTOTP.base32Encode(secret))]
    if let issuer { items.append(URLQueryItem(name: "issuer", value: issuer)) }
    if algorithm != .sha1 { items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue)) }
    if digits != 6 { items.append(URLQueryItem(name: "digits", value: String(digits))) }
    if period != 30 { items.append(URLQueryItem(name: "period", value: String(period))) }
    components.queryItems = items
    return components.string ?? ""
  }

  // MARK: Base32 (RFC 4648, no padding required)

  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  static func base32Decode(_ text: String) -> Data? {
    let cleaned = text.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
    var bits = 0
    var value = 0
    var out = Data()
    for char in cleaned {
      guard let index = alphabet.firstIndex(of: char) else { return nil }
      value = (value << 5) | index
      bits += 5
      if bits >= 8 {
        out.append(UInt8((value >> (bits - 8)) & 0xff))
        bits -= 8
      }
    }
    return out
  }

  static func base32Encode(_ data: Data) -> String {
    var bits = 0
    var value = 0
    var out = ""
    for byte in data {
      value = (value << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        out.append(alphabet[(value >> (bits - 5)) & 31])
        bits -= 5
      }
    }
    if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
    return out
  }
}
