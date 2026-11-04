import Combine
import Foundation

public final class AppLogger: ObservableObject {
  public static let shared = AppLogger()

  @Published public private(set) var lines: [String] = []
  private let queue = DispatchQueue(label: "AppLogger.queue")

  public var allText: String {
    lines.joined(separator: "\n")
  }

  public func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)"
    queue.async { [weak self] in
      DispatchQueue.main.async {
        self?.lines.append(line)
      }
    }
  }

  public func clear() {
    DispatchQueue.main.async { [weak self] in
      self?.lines.removeAll(keepingCapacity: false)
    }
  }
}
