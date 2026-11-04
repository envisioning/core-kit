import CoreKit
import SwiftUI

/// Resolves SF Symbol names coming from the server registry (entity icons,
/// navigation symbols, related-section glyphs). The backend occasionally
/// ships names that aren't valid system symbols — e.g. "radar" — which make
/// `Image(systemName:)` render nothing and log
/// `No symbol named '…' found in system symbol set`. This validates the name
/// against the installed symbol set and substitutes a caller-supplied fallback
/// when it's missing, so an unknown icon degrades gracefully instead of
/// vanishing.
@MainActor
public enum SFSymbolResolver {
  /// Memoized lookups — `UIImage(systemName:)` is comparatively expensive and
  /// the same handful of registry symbols render on every list row.
  private static var validity: [String: Bool] = [:]

  public static func exists(_ name: String) -> Bool {
    if let known = validity[name] { return known }
    #if canImport(UIKit)
      let ok = PlatformImage(systemName: name) != nil
    #else
      let ok = PlatformImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    #endif
    validity[name] = ok
    return ok
  }

  public static func resolve(_ name: String?, fallback: String) -> String {
    guard let name, !name.isEmpty, exists(name) else { return fallback }
    return name
  }
}

extension Image {
  /// Builds an SF Symbol image from a registry-supplied name, falling back to
  /// `fallback` when the name isn't a valid system symbol.
  @MainActor
  public init(crmSymbol name: String?, fallback: String = "square.grid.2x2") {
    self.init(systemName: SFSymbolResolver.resolve(name, fallback: fallback))
  }
}
