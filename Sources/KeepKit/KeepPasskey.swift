import AuthenticationServices
import CryptoKit
import Foundation
import Security

// Passkeys with the PRF extension, natively. The same credential Safari
// made on keep.envisioning.workers.dev answers here, and with the same
// salt gives the same 32 bytes — which is what lets one enrolment unlock
// on the web and in the app. Needs the app's `webcredentials:` associated
// domain for the Keep host, and iOS 18 / macOS 15 for the PRF API; older
// systems take the passphrase path.

public enum KeepPasskeyError: LocalizedError, Sendable, Equatable {
  case unsupported
  case cancelled
  case noPRF
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .unsupported: "Passkeys with PRF need iOS 18 or macOS 15."
    case .cancelled: "Cancelled."
    case .noPRF: "This passkey does not support PRF. Use a passphrase instead."
    case .failed(let message): message
    }
  }
}

public struct KeepPasskeyEnrolment: Sendable {
  public let credentialId: String
  public let prf: Data
}

/// One ceremony at a time; the controller's delegate is this object.
@MainActor
public final class KeepPasskey: NSObject {
  /// PRF needs iOS 18 / macOS 15, and the app must carry the
  /// `webcredentials:` associated domain for the Keep host — a restricted
  /// entitlement that only a provisioned signature can hold. On the Mac
  /// that is read off the running app's code signature: a copy signed
  /// without it (an ad-hoc build) takes the passphrase path instead of
  /// offering a passkey prompt that would fail.
  public static var isAvailable: Bool {
    #if os(macOS)
      if #available(macOS 15, *) { return hasAssociatedDomainEntitlement }
      return false
    #else
      if #available(iOS 18, *) { return true }
      return false
    #endif
  }

  #if os(macOS)
    private static let hasAssociatedDomainEntitlement: Bool = {
      guard let code = currentCode(),
        let information = codeInformation(code),
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        let domains = entitlements["com.apple.developer.associated-domains"] as? [String]
      else { return false }
      return domains.contains { $0.hasPrefix("webcredentials:") }
    }()

    private static func currentCode() -> SecCode? {
      var code: SecCode?
      guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
      return code
    }

    private static func codeInformation(_ code: SecCode) -> [String: Any]? {
      var staticCode: SecStaticCode?
      guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
      var information: CFDictionary?
      guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
        return nil
      }
      return information as? [String: Any]
    }
  #endif

  private let relyingParty: String
  private let anchor: @MainActor () -> ASPresentationAnchor
  private var continuation: CheckedContinuation<ASAuthorization, Error>?

  public init(relyingParty: String, anchor: @escaping @MainActor () -> ASPresentationAnchor) {
    self.relyingParty = relyingParty
    self.anchor = anchor
  }

  /// Make a passkey and evaluate PRF in the same ceremony.
  public func enrol(email: String, name: String) async throws -> KeepPasskeyEnrolment {
    guard #available(iOS 18, macOS 15, *) else { throw KeepPasskeyError.unsupported }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
    let request = provider.createCredentialRegistrationRequest(
      challenge: KeepCrypto.randomBytes(32), name: email, userID: KeepCrypto.randomBytes(16))
    request.displayName = name
    request.userVerificationPreference = .required
    request.prf = .inputValues(.init(saltInput1: KeepCrypto.prfSalt))
    let authorization = try await perform(request)
    guard let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
      throw KeepPasskeyError.failed("Unexpected credential.")
    }
    let credentialId = KeepCrypto.base64URL(registration.credentialID)
    if let first = registration.prf?.first {
      return KeepPasskeyEnrolment(credentialId: credentialId, prf: first.withUnsafeBytes { Data($0) })
    }
    // Some authenticators only evaluate PRF on assertion. Ask once.
    if registration.prf?.isSupported == true {
      let prf = try await unlock(credentialId: credentialId)
      return KeepPasskeyEnrolment(credentialId: credentialId, prf: prf)
    }
    throw KeepPasskeyError.noPRF
  }

  /// Ask the named passkey for its PRF output.
  public func unlock(credentialId: String) async throws -> Data {
    guard #available(iOS 18, macOS 15, *) else { throw KeepPasskeyError.unsupported }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
    let request = provider.createCredentialAssertionRequest(challenge: KeepCrypto.randomBytes(32))
    request.allowedCredentials = [
      ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: try KeepCrypto.data(base64URL: credentialId))
    ]
    request.userVerificationPreference = .required
    request.prf = .inputValues(.init(saltInput1: KeepCrypto.prfSalt))
    let authorization = try await perform(request)
    guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
      throw KeepPasskeyError.failed("Unexpected credential.")
    }
    guard let first = assertion.prf?.first else { throw KeepPasskeyError.noPRF }
    return first.withUnsafeBytes { Data($0) }
  }

  private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      controller.performRequests()
    }
  }
}

extension KeepPasskey: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    continuation?.resume(returning: authorization)
    continuation = nil
  }

  public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    let mapped: Error
    if let authError = error as? ASAuthorizationError, authError.code == .canceled {
      mapped = KeepPasskeyError.cancelled
    } else {
      mapped = KeepPasskeyError.failed(error.localizedDescription)
    }
    continuation?.resume(throwing: mapped)
    continuation = nil
  }

  public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    anchor()
  }
}
