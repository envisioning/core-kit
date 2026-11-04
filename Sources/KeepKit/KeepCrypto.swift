import CommonCrypto
import CryptoKit
import Foundation

// The Swift half of Keep's crypto — a second implementation of
// `envisioning/keep` `packages/crypto/src/index.ts`, held to producing the
// same bytes. `KeepKitTests` opens every blob in that package's
// `vectors.json` with the keys given; a change to either side that breaks
// the other fails there.
//
//   staff keypair     ECDH P-256. Public key on the wire is the raw x9.63
//                     point (65 bytes); private key is PKCS#8 DER.
//   wrap to a person  ECIES: ephemeral P-256 → ECDH → HKDF-SHA256 (salt =
//                     ephemeral ‖ recipient, info = suite label) → AES-256-GCM
//                     with the recipient's public key as AAD.
//   private key       AES-256-GCM under a wrapping key from a passkey's PRF
//                     output (HKDF) or a passphrase (PBKDF2-SHA256).
//   vault key         32 random bytes.
//   item              JSON body, AES-256-GCM, AAD = `vault:item:version`.
//   release           one item body under a one-time key, AAD =
//                     `release:<release>:<vault>:<item>`, the key wrapped to
//                     an agent's session key (KeepRelease.swift, keep#5).
//
// Nothing here logs, puts a plaintext in an error, or keeps a key past the
// call. Holding keys in memory is `KeepSession`'s job.

public enum KeepCryptoError: LocalizedError, Sendable, Equatable {
  case badEncoding
  case badKey
  /// Wrong key or tampered data. Deliberately one message for both.
  case cannotOpen
  case iterationsBelowFloor

  public var errorDescription: String? {
    switch self {
    case .badEncoding: "Malformed data."
    case .badKey: "Malformed key."
    case .cannotOpen: "Could not open: wrong key or tampered data."
    case .iterationsBelowFloor: "PBKDF2 iterations below the floor."
    }
  }
}

public enum KeepCrypto {
  private static let curveInfoWrap = Data("\(KeepSuite.current)/wrap-to-public-key".utf8)
  private static let infoPRF = Data("\(KeepSuite.current)/prf-wrapping-key".utf8)
  private static let privateKeyAAD = Data("\(KeepSuite.current)/staff-private-key".utf8)

  // MARK: Encoding

  public static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func data(base64URL value: String) throws -> Data {
    var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
    guard let data = Data(base64Encoded: padded) else { throw KeepCryptoError.badEncoding }
    return data
  }

  public static func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
  }

  /// The PRF salt every enrolment and unlock passes to the authenticator.
  public static var prfSalt: Data { Data(KeepSuite.prfSaltLabel.utf8) }

  // MARK: AES-GCM

  private static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> KeepSealed {
    let nonce = AES.GCM.Nonce()
    let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
    return KeepSealed(iv: base64URL(Data(nonce)), ciphertext: base64URL(box.ciphertext + box.tag))
  }

  private static func open(_ sealed: KeepSealed, key: SymmetricKey, aad: Data) throws -> Data {
    let iv = try data(base64URL: sealed.iv)
    let combined = try data(base64URL: sealed.ciphertext)
    guard combined.count >= 16 else { throw KeepCryptoError.cannotOpen }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: iv),
        ciphertext: combined.prefix(combined.count - 16),
        tag: combined.suffix(16))
      return try AES.GCM.open(box, using: key, authenticating: aad)
    } catch {
      throw KeepCryptoError.cannotOpen
    }
  }

  // MARK: Staff keypair

  public static func generateStaffKeypair() -> (publicKey: String, privateKey: P256.KeyAgreement.PrivateKey) {
    let key = P256.KeyAgreement.PrivateKey()
    return (base64URL(key.publicKey.x963Representation), key)
  }

  /// PKCS#8 DER, what WebCrypto's `exportKey('pkcs8')` also produces.
  public static func exportPrivateKey(_ key: P256.KeyAgreement.PrivateKey) -> Data {
    key.derRepresentation
  }

  public static func importPrivateKey(pkcs8: Data) throws -> P256.KeyAgreement.PrivateKey {
    do {
      return try P256.KeyAgreement.PrivateKey(derRepresentation: pkcs8)
    } catch {
      throw KeepCryptoError.badKey
    }
  }

  private static func importPublicKey(_ raw: String) throws -> P256.KeyAgreement.PublicKey {
    do {
      return try P256.KeyAgreement.PublicKey(x963Representation: try data(base64URL: raw))
    } catch {
      throw KeepCryptoError.badKey
    }
  }

  // MARK: Wrapping the private key

  public static func wrappingKey(prfOutput: Data, hkdfSalt: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: prfOutput), salt: hkdfSalt, info: infoPRF, outputByteCount: 32)
  }

  public static func wrappingKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
    guard iterations >= KeepSuite.pbkdf2Iterations else { throw KeepCryptoError.iterationsBelowFloor }
    let password = Array(passphrase.precomposedStringWithCompatibilityMapping.utf8)
    var derived = [UInt8](repeating: 0, count: 32)
    let status = salt.withUnsafeBytes { saltBytes in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        password.map { CChar(bitPattern: $0) }, password.count,
        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
        &derived, derived.count)
    }
    guard status == kCCSuccess else { throw KeepCryptoError.badKey }
    return SymmetricKey(data: derived)
  }

  public static func wrapPrivateKey(_ key: P256.KeyAgreement.PrivateKey, prfOutput: Data, credentialId: String) throws -> (wrapped: KeepSealed, wrap: KeepWrapParams) {
    let hkdfSalt = randomBytes(32)
    let wrapped = try seal(exportPrivateKey(key), key: wrappingKey(prfOutput: prfOutput, hkdfSalt: hkdfSalt), aad: privateKeyAAD)
    return (wrapped, .prf(credentialId: credentialId, hkdfSalt: base64URL(hkdfSalt)))
  }

  public static func wrapPrivateKey(_ key: P256.KeyAgreement.PrivateKey, passphrase: String) throws -> (wrapped: KeepSealed, wrap: KeepWrapParams) {
    let salt = randomBytes(32)
    let wrappingKey = try wrappingKey(passphrase: passphrase, salt: salt, iterations: KeepSuite.pbkdf2Iterations)
    let wrapped = try seal(exportPrivateKey(key), key: wrappingKey, aad: privateKeyAAD)
    return (wrapped, .passphrase(pbkdf2Salt: base64URL(salt), pbkdf2Iterations: KeepSuite.pbkdf2Iterations))
  }

  public static func unwrapPrivateKey(_ wrapped: KeepSealed, wrappingKey: SymmetricKey) throws -> P256.KeyAgreement.PrivateKey {
    try importPrivateKey(pkcs8: open(wrapped, key: wrappingKey, aad: privateKeyAAD))
  }

  // MARK: Wrapping a symmetric key to a public key (ECIES)

  private static func ecdhWrappingKey(
    privateKey: P256.KeyAgreement.PrivateKey,
    publicKey: P256.KeyAgreement.PublicKey,
    ephemeralRaw: Data,
    recipientRaw: Data
  ) throws -> SymmetricKey {
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralRaw + recipientRaw, sharedInfo: curveInfoWrap, outputByteCount: 32)
  }

  public static func wrapKey(_ keyBytes: Data, toPublicKey recipientPublicKey: String) throws -> KeepWrappedKey {
    let recipient = try importPublicKey(recipientPublicKey)
    let recipientRaw = try data(base64URL: recipientPublicKey)
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let ephemeralRaw = ephemeral.publicKey.x963Representation
    let wrappingKey = try ecdhWrappingKey(privateKey: ephemeral, publicKey: recipient, ephemeralRaw: ephemeralRaw, recipientRaw: recipientRaw)
    let sealed = try seal(keyBytes, key: wrappingKey, aad: recipientRaw)
    return KeepWrappedKey(ephemeralPublicKey: base64URL(ephemeralRaw), iv: sealed.iv, ciphertext: sealed.ciphertext)
  }

  public static func unwrapKey(_ wrapped: KeepWrappedKey, privateKey: P256.KeyAgreement.PrivateKey, ownPublicKey: String) throws -> Data {
    let ephemeral = try importPublicKey(wrapped.ephemeralPublicKey)
    let ephemeralRaw = try data(base64URL: wrapped.ephemeralPublicKey)
    let ownRaw = try data(base64URL: ownPublicKey)
    let wrappingKey = try ecdhWrappingKey(privateKey: privateKey, publicKey: ephemeral, ephemeralRaw: ephemeralRaw, recipientRaw: ownRaw)
    return try open(KeepSealed(iv: wrapped.iv, ciphertext: wrapped.ciphertext), key: wrappingKey, aad: ownRaw)
  }

  // MARK: Recovery — two shares, both required

  /// XOR split: share A is random, share B = secret ⊕ A. Either alone is noise.
  public static func splitSecret(_ secret: Data) -> (a: Data, b: Data) {
    let a = randomBytes(secret.count)
    var b = Data(count: secret.count)
    for index in 0..<secret.count { b[index] = secret[index] ^ a[index] }
    return (a, b)
  }

  public static func joinShares(_ a: Data, _ b: Data) throws -> Data {
    guard a.count == b.count else { throw KeepCryptoError.badEncoding }
    var secret = Data(count: a.count)
    for index in 0..<a.count { secret[index] = a[index] ^ b[index] }
    return secret
  }

  /// A share as a person stores it: prefixed so it is recognisable in a vault.
  public static func formatShare(_ label: String, _ share: Data) -> String {
    "keep-recovery-\(label):\(base64URL(share))"
  }

  /// Parses `keep-recovery-A:…` or `keep-recovery-B:…`; whitespace tolerated.
  public static func parseShare(_ text: String) throws -> (label: String, share: Data) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("keep-recovery-"), let colon = trimmed.firstIndex(of: ":") else { throw KeepCryptoError.badEncoding }
    let label = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "keep-recovery-".count)..<colon])
    guard label == "A" || label == "B" else { throw KeepCryptoError.badEncoding }
    return (label, try data(base64URL: String(trimmed[trimmed.index(after: colon)...])))
  }

  // MARK: Vault keys and items

  public static func generateVaultKey() -> Data { randomBytes(32) }

  public static func vaultKey(_ raw: Data) throws -> SymmetricKey {
    guard raw.count == 32 else { throw KeepCryptoError.badKey }
    return SymmetricKey(data: raw)
  }

  private static func itemAAD(vaultId: String, itemId: String, keyVersion: Int) -> Data {
    Data("\(vaultId):\(itemId):\(keyVersion)".utf8)
  }

  public static func sealItem(_ body: KeepItemBody, vaultKey: SymmetricKey, vaultId: String, itemId: String, keyVersion: Int) throws -> KeepSealed {
    let plaintext = try JSONEncoder().encode(body)
    return try seal(plaintext, key: vaultKey, aad: itemAAD(vaultId: vaultId, itemId: itemId, keyVersion: keyVersion))
  }

  public static func openItem(_ sealed: KeepSealed, vaultKey: SymmetricKey, vaultId: String, itemId: String, keyVersion: Int) throws -> KeepItemBody {
    let plaintext = try open(sealed, key: vaultKey, aad: itemAAD(vaultId: vaultId, itemId: itemId, keyVersion: keyVersion))
    do {
      return try JSONDecoder().decode(KeepItemBody.self, from: plaintext)
    } catch {
      throw KeepCryptoError.badEncoding
    }
  }
}
