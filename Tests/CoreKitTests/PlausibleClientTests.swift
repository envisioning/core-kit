import Foundation
import Testing

@testable import CoreKit

struct PlausibleClientTests {
  @Test func twelveMonthRangeIncludesCurrentCalendarMonth() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
    )

    #expect(
      PlausibleRange.last12Months.apiDateRange(relativeTo: now, calendar: calendar)
        == .dates(from: "2025-09-01", through: "2026-08-23")
    )
    #expect(
      PlausibleRange.last30Days.apiDateRange(relativeTo: now, calendar: calendar)
        == .shorthand("30d")
    )
  }

  @Test func timeSeriesFillsMissingTimeLabelsWithZeroes() async throws {
    let response = #"""
      {
        "results": [
          {"dimensions":["2026-03-01"],"metrics":[3,5,20]},
          {"dimensions":["2026-05-01"],"metrics":[7,9,30]}
        ],
        "meta": {
          "time_labels":["2026-03-01","2026-04-01","2026-05-01"]
        }
      }
      """#.data(using: .utf8)!
    PlausibleURLProtocolStub.configure(responseData: response)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PlausibleURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    let config = PlausibleConfig(
      baseURL: URL(string: "https://plausible.example")!,
      siteID: "example.com",
      apiKey: "test-key"
    )
    let client = PlausibleClient(session: session, configProvider: { config })

    let points = try await client.timeSeries(scope: .subtree("/"), range: .last12Months)

    #expect(points.map(\.key) == ["2026-03-01", "2026-04-01", "2026-05-01"])
    #expect(points.map(\.stats.pageviews) == [5, 0, 9])

    let requestBody = try #require(PlausibleURLProtocolStub.lastRequestBody())
    let requestJSON = try #require(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    )
    let include = try #require(requestJSON["include"] as? [String: Bool])
    #expect(include["time_labels"] == true)
    #expect(requestJSON["date_range"] is [String])
  }
}

private final class PlausibleURLProtocolStub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var responseData = Data()
  private static var requestBody: Data?

  static func configure(responseData: Data) {
    Self.lock.withLock {
      Self.responseData = responseData
      Self.requestBody = nil
    }
  }

  static func lastRequestBody() -> Data? {
    Self.lock.withLock { Self.requestBody }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let responseData = Self.lock.withLock { () -> Data in
      Self.requestBody = Self.bodyData(from: request)
      return Self.responseData
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 4_096)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
