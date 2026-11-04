import EnvisioningUI
import SwiftUI

extension View {
  /// The one free-standing text field look in core-kit: the field fill, a
  /// hairline, and, while focused, a stroke in the host's tint instead of the
  /// system's blue focus ring (core-kit#21). Meet tints its hosted views with
  /// the workspace accent, so a focused field there is the workspace's
  /// colour; Core's own tint is the lime. Use it in place of
  /// `.textFieldStyle(.roundedBorder)`. Rows of an `EnvisioningForm` keep the
  /// form's own look.
  public func coreField() -> some View {
    modifier(CoreFieldModifier())
  }
}

private struct CoreFieldModifier: ViewModifier {
  @FocusState private var focused: Bool

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: EnvisioningRadius.field, style: .continuous)
    content
      .textFieldStyle(.plain)
      .focused($focused)
      .focusEffectDisabled()
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(shape.fill(EnvisioningSurface.field))
      .overlay {
        if focused {
          shape.strokeBorder(.tint, lineWidth: 1.5)
        } else {
          shape.strokeBorder(EnvisioningSurface.controlBorder, lineWidth: 1)
        }
      }
      .animation(.easeOut(duration: 0.12), value: focused)
  }
}
