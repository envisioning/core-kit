import XCTest

@testable import KeepKit

/// RFC 6238 Appendix B vectors (SHA-1, secret "12345678901234567890"), plus
/// the shapes 1Password exports.
final class KeepTOTPTests: XCTestCase {
  private let rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"  // base32 of 12345678901234567890

  func testRFC6238SHA1Vectors() throws {
    let totp = try XCTUnwrap(KeepTOTP("otpauth://totp/RFC:test?secret=\(rfcSecret)&digits=8"))
    XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 59)), "94287082")
    XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 1_111_111_109)), "07081804")
    XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 1_234_567_890)), "89005924")
    XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 20_000_000_000)), "65353130")
  }

  func testBareSecretAndSpaces() throws {
    let totp = try XCTUnwrap(KeepTOTP("gezd gnbv gy3t qojq gezd gnbv gy3t qojq"))
    XCTAssertEqual(totp.digits, 6)
    XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: 59)), "287082")
    XCTAssertTrue(totp.uri.hasPrefix("otpauth://totp/"))
    XCTAssertEqual(KeepTOTP(totp.uri)?.secret, totp.secret)
  }

  func testLabelAndIssuer() throws {
    let totp = try XCTUnwrap(KeepTOTP("otpauth://totp/GitHub:rosa%40example.com?secret=\(rfcSecret)&issuer=GitHub&period=60"))
    XCTAssertEqual(totp.issuer, "GitHub")
    XCTAssertEqual(totp.account, "rosa@example.com")
    XCTAssertEqual(totp.period, 60)
    XCTAssertEqual(totp.secondsRemaining(at: Date(timeIntervalSince1970: 59)), 1)
  }

  func testRejectsGarbage() {
    XCTAssertNil(KeepTOTP(""))
    XCTAssertNil(KeepTOTP("not base32 !!"))
    XCTAssertNil(KeepTOTP("otpauth://hotp/x?secret=\(rfcSecret)"))
  }
}
