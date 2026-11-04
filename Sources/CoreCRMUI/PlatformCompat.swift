import CoreKit
import Combine
import EnvisioningUI
import SwiftUI
#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

// Cross-platform aliases and no-op shims so the shared CRM views compile
// unchanged on macOS. iOS-only modifiers become no-ops; iOS-only style and
// placement tokens map to their closest macOS equivalent.

#if canImport(UIKit)
  public typealias PlatformImage = UIImage
#else
  public typealias PlatformImage = NSImage
#endif

extension Image {
  public init(platformImage: PlatformImage) {
    #if canImport(UIKit)
      self.init(uiImage: platformImage)
    #else
      self.init(nsImage: platformImage)
    #endif
  }
}

/// Puts a string on the general pasteboard on either platform.
public func copyToPasteboard(_ string: String) {
  #if canImport(UIKit)
    UIPasteboard.general.string = string
  #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  #endif
}

/// Card/tile background, one rung above the grouped list — the estate's
/// `elevated` (`EnvisioningSurface`, envisioning/meet#140). This used to be the
/// system's `.controlBackgroundColor` / `.secondarySystemGroupedBackground`,
/// which painted a neutral-gray tile inside a host whose window is the shared
/// blue-tinted ladder; now the tile and the window stand on the same table.
public var crmTileBackground: Color {
  EnvisioningSurface.elevated
}

/// Canvas behind the grouped list, distinct from `crmTileBackground` so tiles
/// read as raised rather than flat. The estate's `canvas` rung on both
/// platforms; a host that paints its own canvas gets the same colour.
public var crmGroupedBackground: Color {
  EnvisioningSurface.canvas
}

/// Muted text — labels, captions, dashes for an empty value. The estate's
/// `secondaryText` rather than SwiftUI's `.secondary`, which is the system's
/// gray and does not sit on the shared ladder.
public var crmSecondaryText: Color {
  EnvisioningSurface.secondaryText
}

extension View {
  /// Trailing-aligns a field's value on iOS, the grouped-form convention where
  /// the value trails its label. Left/natural on macOS, where the wider
  /// two-column form makes trailing text read as jammed against the edge.
  @ViewBuilder
  public func crmFieldValueAlignment() -> some View {
    #if os(iOS)
      multilineTextAlignment(.trailing)
    #else
      self
    #endif
  }

  /// Gives a presented form a comfortable minimum size on macOS, where a sheet
  /// otherwise collapses to a cramped column. No-op on iOS, which sizes sheets
  /// via presentation detents.
  @ViewBuilder
  public func crmFormSheetSizing() -> some View {
    #if os(macOS)
      frame(minWidth: 480, minHeight: 560)
    #else
      self
    #endif
  }

  /// Adds the explicit Back control needed by the app's bridged macOS window.
  /// On iOS the native back button remains in charge until a form is dirty;
  /// then it is replaced so leaving can run the caller's discard confirmation.
  @ViewBuilder
  public func crmBackToolbar(
    destination: String,
    isDirty: Bool,
    onBack: @escaping () -> Void
  ) -> some View {
    #if os(macOS)
      toolbar {
        ToolbarItem(placement: .navigation) {
          Button(action: onBack) {
            Label("Back", systemImage: "chevron.backward")
          }
          .keyboardShortcut("[", modifiers: .command)
          .help("Back to \(destination)")
        }
      }
    #else
      if isDirty {
        navigationBarBackButtonHidden(true)
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button(action: onBack) {
                Label("Back", systemImage: "chevron.backward")
              }
            }
          }
      } else {
        self
      }
    #endif
  }
}

/// Lets window-level keyboard commands stand down while a record has local,
/// unsaved edits. The detail remains the owner of save/discard decisions.
public struct CRMUnsavedChangesPreferenceKey: PreferenceKey {
  public static var defaultValue = false

  public static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

/// Fires each time the app returns to the foreground.
///
/// Not `scenePhase`: on macOS the CRM window is a delegate-owned `NSWindow`,
/// not a SwiftUI scene, so no phase change reaches the views inside it. The
/// AppKit/UIKit notification reaches both platforms the same way.
private var appDidBecomeActiveNotification: Notification.Name {
  #if canImport(UIKit)
    UIApplication.didBecomeActiveNotification
  #else
    NSApplication.didBecomeActiveNotification
  #endif
}

extension View {
  /// Runs `action` on every foreground activation.
  public func onAppActivation(perform action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: appDidBecomeActiveNotification)) { _ in
      action()
    }
  }
}

/// "Reload what's on screen", broadcast from the window's Refresh command.
///
/// macOS needs this: `.refreshable` draws no pull gesture on a macOS `List`, so
/// without a command the desktop has no way to re-query a screen at all. A
/// broadcast rather than a passed-down closure because the screens sit at the
/// bottom of nested navigation stacks, each owning its own loader.
///
/// macOS-only by design. Every mounted view answers, and on macOS exactly one
/// section is mounted (`desktopDetail` swaps them), while iOS keeps every tab
/// alive — there, one command would fan out into a refresh per tab. iOS keeps
/// pull-to-refresh and the entity list's own ⌘R.
private let crmRefreshRequested = Notification.Name("work.starlings.corekit.crmRefreshRequested")

/// Posts the refresh broadcast. No-op on iOS, which has pull-to-refresh.
public func requestCRMRefresh() {
  #if os(macOS)
    NotificationCenter.default.post(name: crmRefreshRequested, object: nil)
  #endif
}

extension View {
  /// Reloads this screen when the window's Refresh command fires.
  public func onRefreshRequest(perform action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: crmRefreshRequested)) { _ in
      action()
    }
  }
}

/// The user-visible name of this device, for token/device registration.
public var platformDeviceName: String {
  #if canImport(UIKit)
    UIDevice.current.name
  #else
    Host.current().localizedName ?? "Mac"
  #endif
}

#if os(macOS)
  /// iOS keyboard types, accepted and ignored on macOS.
  public enum CRMKeyboardType {
    case numberPad, decimalPad, emailAddress, URL, `default`
  }

  /// iOS autocapitalization behaviors, accepted and ignored on macOS.
  public enum CRMTextInputAutocapitalization {
    case never, sentences
  }

  /// iOS title display modes, accepted and ignored on macOS.
  public enum CRMTitleDisplayMode {
    case inline, large
  }

  extension View {
    public func keyboardType(_ type: CRMKeyboardType) -> some View { self }
    public func textInputAutocapitalization(_ mode: CRMTextInputAutocapitalization?) -> some View { self }
    public func navigationBarTitleDisplayMode(_ mode: CRMTitleDisplayMode) -> some View { self }
  }

  extension ListStyle where Self == InsetListStyle {
    /// The iOS grouped style doesn't exist on macOS; inset is the closest look.
    public static var insetGrouped: InsetListStyle { InsetListStyle() }
  }

  extension ToolbarItemPlacement {
    public static var topBarLeading: ToolbarItemPlacement { .navigation }
    public static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
  }
#endif

extension View {
  /// `.searchFocused` is iOS 18 / macOS 15. Below that the search field simply
  /// is not programmatically focusable; the binding is ignored rather than
  /// the whole screen going unavailable.
  @ViewBuilder
  func searchFocusedCompat(_ binding: FocusState<Bool>.Binding) -> some View {
    if #available(macOS 15.0, iOS 18.0, *) {
      searchFocused(binding)
    } else {
      self
    }
  }
}

extension View {
  /// Liquid Glass button chrome where the OS has it (iOS 26 / macOS 26), the
  /// plain bordered style below. Same call site, no per-screen `#available`.
  @ViewBuilder
  func crmGlassButtonStyle() -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }
}

extension View {
  /// The contacts A–Z index rail: `sectionIndexLabel` / `listSectionIndexVisibility`
  /// are iOS 26. Below that, and on macOS, the list simply has no rail.
  @ViewBuilder
  func crmSectionIndexLabel(_ title: String) -> some View {
    #if os(iOS)
      if #available(iOS 26.0, *) {
        sectionIndexLabel(title)
      } else {
        self
      }
    #else
      self
    #endif
  }

  @ViewBuilder
  func crmListSectionIndexVisible(_ visible: Bool) -> some View {
    #if os(iOS)
      if #available(iOS 26.0, *) {
        listSectionIndexVisibility(visible ? .visible : .hidden)
      } else {
        self
      }
    #else
      self
    #endif
  }
}
