import Combine
import CryptoKit
import Foundation

// The key session: the one place a private key lives while Keep is open.
// The native twin of the web app's `session.ts`, with the same rules:
//
//   - The private key is a CryptoKit key in memory. Not in the Keychain,
//     not on disk. Quitting locks. So does fifteen idle minutes.
//   - Vault keys are unwrapped on demand and cached only while unlocked.
//   - Locking drops every reference. Plaintext a view still holds is the
//     view's problem, which is why reveal views clear on disappear.
//
// Everything that touches Keep from a screen goes through here, so a screen
// never sees a key: it asks for a `KeepItemBody` and gets one, or an error.

@MainActor
public final class KeepSession: ObservableObject {
  public enum State: Equatable, Sendable {
    /// No device token yet: the app has not brokered one.
    case disconnected
    case loading
    /// Signed in, no key on the server yet.
    case unenrolled(KeepMe)
    /// Signed in and enrolled; private key not in memory.
    case locked(KeepMe)
    case unlocked(KeepMe)
    case failed(String)
  }

  @Published public private(set) var state: State = .disconnected
  @Published public private(set) var vaults: [KeepVaultSummary] = []
  /// Nil until the first list lands; a message when the last list failed.
  @Published public private(set) var vaultsLoaded = false
  @Published public private(set) var vaultsError: String?
  /// A vault a host asked to show — the Mac window selects it when it can.
  @Published public var requestedVaultId: String?

  public let client: KeepClient
  private let idleLockSeconds: TimeInterval
  private var privateKey: P256.KeyAgreement.PrivateKey?
  private var publicKey: String?
  private var vaultKeys: [String: SymmetricKey] = [:]
  private var idleTimer: Timer?

  public init(client: KeepClient, idleLockSeconds: TimeInterval = 15 * 60) {
    self.client = client
    self.idleLockSeconds = idleLockSeconds
  }

  public var me: KeepMe? {
    switch state {
    case .unenrolled(let me), .locked(let me), .unlocked(let me): me
    default: nil
    }
  }

  public var isUnlocked: Bool {
    if case .unlocked = state { return true }
    return false
  }

  // MARK: Lifecycle

  /// Ask Keep who we are. Called when the token lands and on every open.
  public func refresh() async {
    if case .disconnected = state { state = .loading }
    do {
      let me = try await client.me()
      if privateKey != nil, me.enrolled, me.key?.publicKey == publicKey {
        state = .unlocked(me)
        await loadVaults()
      } else if me.enrolled, me.key != nil {
        lock()
        state = .locked(me)
      } else {
        lock()
        state = .unenrolled(me)
      }
    } catch KeepClientError.missingToken {
      state = .disconnected
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  public func disconnect() {
    lock()
    state = .disconnected
    vaults = []
    vaultsLoaded = false
    vaultsError = nil
  }

  public func lock() {
    privateKey = nil
    publicKey = nil
    vaultKeys = [:]
    idleTimer?.invalidate()
    idleTimer = nil
    if let me { state = me.enrolled ? .locked(me) : .unenrolled(me) }
  }

  /// Any interaction with a Keep screen. Cheap; call it from `onAppear` and taps.
  public func touch() {
    guard privateKey != nil else { return }
    armIdleTimer()
  }

  private func armIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: idleLockSeconds, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.lock() }
    }
  }

  private func accept(_ key: P256.KeyAgreement.PrivateKey, publicKey own: String, me: KeepMe) async {
    privateKey = key
    publicKey = own
    vaultKeys = [:]
    armIdleTimer()
    state = .unlocked(me)
    await loadVaults()
  }

  // MARK: Enrol and unlock

  /// Enrol with a passphrase; the key is in hand afterwards, so this unlocks too.
  public func enrol(passphrase: String, replace: Bool = false) async throws {
    let pair = KeepCrypto.generateStaffKeypair()
    let (wrapped, wrap) = try KeepCrypto.wrapPrivateKey(pair.privateKey, passphrase: passphrase)
    _ = try await client.enrol(KeepEnrolInput(publicKey: pair.publicKey, wrappedPrivateKey: wrapped, wrap: wrap), replace: replace)
    let me = try await client.me()
    await accept(pair.privateKey, publicKey: pair.publicKey, me: me)
  }

  /// Enrol with a passkey the caller has already made (`KeepPasskey.enrol`).
  public func enrol(passkey: KeepPasskeyEnrolment, replace: Bool = false) async throws {
    let pair = KeepCrypto.generateStaffKeypair()
    let (wrapped, wrap) = try KeepCrypto.wrapPrivateKey(pair.privateKey, prfOutput: passkey.prf, credentialId: passkey.credentialId)
    _ = try await client.enrol(KeepEnrolInput(publicKey: pair.publicKey, wrappedPrivateKey: wrapped, wrap: wrap), replace: replace)
    let me = try await client.me()
    await accept(pair.privateKey, publicKey: pair.publicKey, me: me)
  }

  /// Whether this key holds a passphrase wrap.
  public var hasPassphrase: Bool { me?.key?.passphraseWrap != nil }

  public func unlock(passphrase: String) async throws {
    guard let me, let staffKey = me.key, let entry = staffKey.passphraseWrap,
      case .passphrase(let salt, let iterations) = entry.wrap
    else { throw KeepCryptoError.badKey }
    let wrappingKey = try KeepCrypto.wrappingKey(passphrase: passphrase, salt: try KeepCrypto.data(base64URL: salt), iterations: iterations)
    let key = try KeepCrypto.unwrapPrivateKey(entry.wrappedPrivateKey, wrappingKey: wrappingKey)
    await accept(key, publicKey: staffKey.publicKey, me: me)
  }

  /// The credential id to ask the authenticator for, when the key holds a passkey wrap.
  public var passkeyCredentialId: String? {
    guard let entry = me?.key?.passkeyWrap, case .prf(let credentialId, _) = entry.wrap else { return nil }
    return credentialId
  }

  public func unlock(prfOutput: Data) async throws {
    guard let me, let staffKey = me.key, let entry = staffKey.passkeyWrap, case .prf(_, let hkdfSalt) = entry.wrap else {
      throw KeepCryptoError.badKey
    }
    let wrappingKey = KeepCrypto.wrappingKey(prfOutput: prfOutput, hkdfSalt: try KeepCrypto.data(base64URL: hkdfSalt))
    let key = try KeepCrypto.unwrapPrivateKey(entry.wrappedPrivateKey, wrappingKey: wrappingKey)
    await accept(key, publicKey: staffKey.publicKey, me: me)
  }

  /// Seal the open private key under a passphrase and add it as a way to
  /// unlock. What a passkey-enrolled phone does so the Mac can open Keep.
  public func addPassphrase(_ passphrase: String) async throws {
    let (privateKey, _) = try requireKeys()
    let (wrapped, wrap) = try KeepCrypto.wrapPrivateKey(privateKey, passphrase: passphrase)
    _ = try await client.addWrap(KeepKeyWrap(wrappedPrivateKey: wrapped, wrap: wrap))
    await refresh()
  }

  /// Seal the open private key under a passkey's PRF output and add it.
  public func addPasskey(_ passkey: KeepPasskeyEnrolment) async throws {
    let (privateKey, _) = try requireKeys()
    let (wrapped, wrap) = try KeepCrypto.wrapPrivateKey(privateKey, prfOutput: passkey.prf, credentialId: passkey.credentialId)
    _ = try await client.addWrap(KeepKeyWrap(wrappedPrivateKey: wrapped, wrap: wrap))
    await refresh()
  }

  // MARK: Vault keys

  public enum Locked: LocalizedError { case locked
    public var errorDescription: String? { "Keep is locked." }
  }

  private func requireKeys() throws -> (P256.KeyAgreement.PrivateKey, String) {
    guard let privateKey, let publicKey else { throw Locked.locked }
    touch()
    return (privateKey, publicKey)
  }

  /// Raw vault key bytes: needed to wrap it to a colleague. Never cached.
  private func vaultKeyBytes(_ wrapped: KeepWrappedKey) throws -> Data {
    let (privateKey, publicKey) = try requireKeys()
    return try KeepCrypto.unwrapKey(wrapped, privateKey: privateKey, ownPublicKey: publicKey)
  }

  private func vaultKey(_ vaultId: String, keyVersion: Int, wrapped: KeepWrappedKey) throws -> SymmetricKey {
    let cacheKey = "\(vaultId):\(keyVersion)"
    if let cached = vaultKeys[cacheKey] {
      touch()
      return cached
    }
    let key = try KeepCrypto.vaultKey(try vaultKeyBytes(wrapped))
    vaultKeys[cacheKey] = key
    return key
  }

  // MARK: Vaults

  public func loadVaults() async {
    do {
      vaults = try await client.vaults()
      vaultsLoaded = true
      vaultsError = nil
      await coverUncoveredVaults()
    } catch {
      vaultsError = error.localizedDescription
    }
  }

  // MARK: Recovery

  @Published public private(set) var recoveryKey: KeepRecoveryKey?
  @Published public private(set) var recoveryLoaded = false

  public func loadRecoveryKey() async {
    recoveryKey = try? await client.recoveryKey()
    recoveryLoaded = true
  }

  /// The recovery rule, kept without asking: a vault made before the
  /// recovery key existed gets its recovery wrap the first time a member
  /// with the key open lists their vaults. Quiet; the audit row says it.
  private func coverUncoveredVaults() async {
    guard privateKey != nil else { return }
    let uncovered = vaults.filter { !$0.recoveryWrapped }
    guard !uncovered.isEmpty else { return }
    await loadRecoveryKey()
    guard let recovery = recoveryKey else { return }
    var changed = false
    for vault in uncovered {
      guard let keyBytes = try? vaultKeyBytes(vault.wrappedKey),
        let wrapped = try? KeepCrypto.wrapKey(keyBytes, toPublicKey: recovery.publicKey)
      else { continue }
      if (try? await client.coverVault(vault.id, recoveryWrappedKey: wrapped)) != nil { changed = true }
    }
    if changed, let fresh = try? await client.vaults() { vaults = fresh }
  }

  public struct RecoveryShares: Sendable {
    public let a: String
    public let b: String
  }

  /// The ceremony: a keypair, its private half split in two, the public
  /// half published with the holders' names. The shares are returned once
  /// and never kept; the private key is dropped with this call.
  public func createRecoveryKey(holders: [String]) async throws -> RecoveryShares {
    let pair = KeepCrypto.generateStaffKeypair()
    let (a, b) = KeepCrypto.splitSecret(KeepCrypto.exportPrivateKey(pair.privateKey))
    recoveryKey = try await client.setRecoveryKey(KeepSetRecoveryInput(publicKey: pair.publicKey, holders: holders))
    recoveryLoaded = true
    await coverUncoveredVaults()
    return RecoveryShares(a: KeepCrypto.formatShare("A", a), b: KeepCrypto.formatShare("B", b))
  }

  /// The recovery private key from the two shares, checked against the
  /// published public key so a wrong share fails here, not on a vault.
  public func recoveryPrivateKey(shareA: String, shareB: String) async throws -> P256.KeyAgreement.PrivateKey {
    let a = try KeepCrypto.parseShare(shareA)
    let b = try KeepCrypto.parseShare(shareB)
    guard a.label != b.label else { throw KeepCryptoError.badEncoding }
    let pkcs8 = try KeepCrypto.joinShares(a.label == "A" ? a.share : b.share, a.label == "A" ? b.share : a.share)
    let key = try KeepCrypto.importPrivateKey(pkcs8: pkcs8)
    await loadRecoveryKey()
    guard let published = recoveryKey, KeepCrypto.base64URL(key.publicKey.x963Representation) == published.publicKey else {
      throw KeepCryptoError.cannotOpen
    }
    return key
  }

  /// Every covered vault, for a person holding both shares.
  public func recoveryVaults() async throws -> [KeepRecoveryVaultEntry] {
    try await client.recoveryVaults()
  }

  /// Open one vault's key with the recovery private key and join it.
  public func recover(_ entry: KeepRecoveryVaultEntry, with recoveryKey: P256.KeyAgreement.PrivateKey) async throws {
    guard let me, let staffKey = me.key else { throw Locked.locked }
    let published = self.recoveryKey?.publicKey ?? KeepCrypto.base64URL(recoveryKey.publicKey.x963Representation)
    let vaultKeyBytes = try KeepCrypto.unwrapKey(entry.recoveryWrappedKey, privateKey: recoveryKey, ownPublicKey: published)
    let mine = try KeepCrypto.wrapKey(vaultKeyBytes, toPublicKey: staffKey.publicKey)
    try await client.recoveryJoin(entry.id, wrappedKey: mine)
    await loadVaults()
  }

  /// A fresh vault key wrapped to me, the chosen colleagues, and recovery.
  public func createVault(name: String, icon: String? = nil, projectId: String?, members: [KeepDirectoryEntry]) async throws -> KeepVaultDetail {
    let (_, own) = try requireKeys()
    let key = KeepCrypto.generateVaultKey()
    guard let me else { throw Locked.locked }
    var wraps = [KeepMemberWrap(email: me.email, wrappedKey: try KeepCrypto.wrapKey(key, toPublicKey: own))]
    for member in members where member.email != me.email {
      wraps.append(KeepMemberWrap(email: member.email, wrappedKey: try KeepCrypto.wrapKey(key, toPublicKey: member.publicKey)))
    }
    let recovery = try await client.recoveryKey()
    let recoveryWrap = try recovery.map { try KeepCrypto.wrapKey(key, toPublicKey: $0.publicKey) }
    let vault = try await client.createVault(KeepCreateVaultInput(name: name, icon: icon, projectId: projectId, members: wraps, recoveryWrappedKey: recoveryWrap))
    await loadVaults()
    return vault
  }

  /// The vault for a Core project, among the ones this person can open.
  public func vault(forProject projectId: String) -> KeepVaultSummary? {
    vaults.first { $0.projectId == projectId }
  }

  /// The project's vault, made if there is none: named after the project,
  /// with only this person as a member. Colleagues are added from Members.
  public func ensureVault(forProject projectId: String, named name: String) async throws -> String {
    if !vaultsLoaded { await loadVaults() }
    if let existing = vault(forProject: projectId) { return existing.id }
    let created = try await createVault(name: name, projectId: projectId, members: [])
    return created.id
  }

  public func updateVault(_ vault: KeepVaultDetail, name: String, icon: String?, projectId: String?) async throws -> KeepVaultDetail {
    let detail = try await client.updateVault(vault.id, name: name, icon: icon, projectId: projectId)
    await loadVaults()
    return detail
  }

  public func grant(_ vault: KeepVaultDetail, to entry: KeepDirectoryEntry) async throws -> KeepVaultDetail {
    let keyBytes = try vaultKeyBytes(vault.wrappedKey)
    let detail = try await client.grant(vault.id, KeepMemberWrap(email: entry.email, wrappedKey: try KeepCrypto.wrapKey(keyBytes, toPublicKey: entry.publicKey)))
    await loadVaults()
    return detail
  }

  /// Removing someone is a new vault key: open every item under the old
  /// key, seal it under the new, wrap the new key to everyone who stays and
  /// to recovery, and send it as one rotation.
  public func revoke(_ vault: KeepVaultDetail, email: String, directory: [KeepDirectoryEntry]) async throws -> KeepVaultDetail {
    let oldKey = try vaultKey(vault.id, keyVersion: vault.keyVersion, wrapped: vault.wrappedKey)
    let newKeyBytes = KeepCrypto.generateVaultKey()
    let newKey = try KeepCrypto.vaultKey(newKeyBytes)
    let nextVersion = vault.keyVersion + 1

    var items: [KeepRotateInput.Item] = []
    for summary in vault.items {
      let detail = try await client.reveal(vault.id, item: summary.id)
      let body = try KeepCrypto.openItem(detail.sealed, vaultKey: oldKey, vaultId: vault.id, itemId: summary.id, keyVersion: detail.keyVersion)
      items.append(.init(id: summary.id, sealed: try KeepCrypto.sealItem(body, vaultKey: newKey, vaultId: vault.id, itemId: summary.id, keyVersion: nextVersion)))
    }

    let keys = Dictionary(directory.map { ($0.email, $0.publicKey) }, uniquingKeysWith: { first, _ in first })
    var members: [KeepMemberWrap] = []
    for member in vault.members where member.email != email {
      guard let publicKey = keys[member.email] else {
        throw KeepClientError.api(status: 400, code: "not_enrolled", message: "\(member.email) is no longer enrolled; remove them first.")
      }
      members.append(KeepMemberWrap(email: member.email, wrappedKey: try KeepCrypto.wrapKey(newKeyBytes, toPublicKey: publicKey)))
    }
    let recovery = try await client.recoveryKey()
    let recoveryWrap = try recovery.map { try KeepCrypto.wrapKey(newKeyBytes, toPublicKey: $0.publicKey) }

    let detail = try await client.rotate(vault.id, KeepRotateInput(keyVersion: nextVersion, members: members, recoveryWrappedKey: recoveryWrap, items: items))
    vaultKeys = vaultKeys.filter { !$0.key.hasPrefix("\(vault.id):") }
    await loadVaults()
    return detail
  }

  public func deleteVault(_ vault: KeepVaultDetail) async throws {
    try await client.deleteVault(vault.id)
    vaultKeys = vaultKeys.filter { !$0.key.hasPrefix("\(vault.id):") }
    await loadVaults()
  }

  // MARK: Items

  /// Reveal: one fetch (audited), opened here, returned as plaintext.
  public func open(_ item: KeepItemSummary, in vault: KeepVaultDetail) async throws -> KeepItemBody {
    let detail = try await client.reveal(vault.id, item: item.id)
    let key = try vaultKey(vault.id, keyVersion: vault.keyVersion, wrapped: vault.wrappedKey)
    return try KeepCrypto.openItem(detail.sealed, vaultKey: key, vaultId: vault.id, itemId: item.id, keyVersion: detail.keyVersion)
  }

  public func createItem(name: String, kind: KeepItemKind, body: KeepItemBody, in vault: KeepVaultDetail) async throws -> KeepItemDetail {
    let key = try vaultKey(vault.id, keyVersion: vault.keyVersion, wrapped: vault.wrappedKey)
    let id = UUID().uuidString.lowercased()
    let sealed = try KeepCrypto.sealItem(body, vaultKey: key, vaultId: vault.id, itemId: id, keyVersion: vault.keyVersion)
    let detail = try await client.createItem(vault.id, KeepCreateItemInput(id: id, name: name, kind: kind, sealed: sealed, keyVersion: vault.keyVersion))
    await loadVaults()
    return detail
  }

  public func updateItem(_ item: KeepItemSummary, name: String, kind: KeepItemKind, body: KeepItemBody, in vault: KeepVaultDetail) async throws -> KeepItemDetail {
    let key = try vaultKey(vault.id, keyVersion: vault.keyVersion, wrapped: vault.wrappedKey)
    let sealed = try KeepCrypto.sealItem(body, vaultKey: key, vaultId: vault.id, itemId: item.id, keyVersion: vault.keyVersion)
    return try await client.updateItem(vault.id, item: item.id, KeepUpdateItemInput(name: name, kind: kind, sealed: sealed, keyVersion: vault.keyVersion))
  }

  public func deleteItem(_ item: KeepItemSummary, in vault: KeepVaultDetail) async throws {
    try await client.deleteItem(vault.id, item: item.id)
    await loadVaults()
  }
}
