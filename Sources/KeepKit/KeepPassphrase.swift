import Foundation

/// A generated passphrase: five groups of four from a 32-letter alphabet
/// with no look-alikes, `xxxx-xxxx-xxxx-xxxx-xxxx`, 100 bits. Readable
/// over a shoulder-free desk, typeable on a phone, and no word list to
/// carry. It is shown once and copied; the person stores it in their own
/// password manager.
public enum KeepPassphrase {
  private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

  public static func generate(groups: Int = 5, groupLength: Int = 4) -> String {
    let bytes = KeepCrypto.randomBytes(groups * groupLength)
    var out: [String] = []
    var index = 0
    for _ in 0..<groups {
      var group = ""
      for _ in 0..<groupLength {
        group.append(alphabet[Int(bytes[index]) % alphabet.count])
        index += 1
      }
      out.append(group)
    }
    return out.joined(separator: "-")
  }
}
