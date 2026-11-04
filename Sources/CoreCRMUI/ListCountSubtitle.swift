import CoreKit
import SwiftUI

/// The one source of truth for the entry count shown under a list page's title.
/// Every list screen renders its count through this so the phrasing and number
/// formatting stay identical across the app.
extension View {
  /// Shows `count` as the navigation subtitle, e.g. "128 entries".
  /// Pass `nil` while the count is still unknown to leave the subtitle off.
  @ViewBuilder
  public func listCountSubtitle(_ count: Int?) -> some View {
    // `navigationSubtitle` reaches iOS in 26; below that the count is simply
    // not shown rather than the screen going unavailable.
    if #available(iOS 26.0, macOS 11.0, *) {
      navigationSubtitle(count.map(ListCountSubtitle.text) ?? Text(verbatim: ""))
    } else {
      self
    }
  }
}

enum ListCountSubtitle {
  static func text(_ count: Int) -> Text {
    Text(string(count))
  }

  static func string(_ count: Int) -> String {
    let formatted = count.formatted(.number)
    return count == 1 ? "\(formatted) entry" : "\(formatted) entries"
  }
}
