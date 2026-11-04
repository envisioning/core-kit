import CoreKit
import CoreGraphics

/// Shared spacing for CRM list rows, so the gap between a row's leading icon
/// and its text — and the gap between stacked sub-indicator lines — stays
/// consistent across every list surface and can be tuned in one place.
public enum CRMListRow {
  /// Horizontal gap between a row's leading icon/avatar/thumbnail and its text.
  public static let iconSpacing: CGFloat = 8
  /// Vertical gap between stacked sub-indicator lines under a row's title.
  public static let indicatorSpacing: CGFloat = 5
}
