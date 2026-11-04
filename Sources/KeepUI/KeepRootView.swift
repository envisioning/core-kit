import AuthenticationServices
import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// The Keep surface: three gates, then the vaults. Connected (the host
/// brokered a device token), enrolled (a key on the server), unlocked (the
/// key in memory). The host owns the first; the other two are here.
///
/// `connect` is what the host does to broker a token; `anchor` is the
/// window the passkey sheet attaches to. Both differ per platform, and
/// nothing else does.
/// Where Keep opens once unlocked: the vault list, or straight into one
/// project's vault (made on the way in if it does not exist).
public enum KeepLanding: Equatable, Sendable {
  case vaults
  case project(id: String, name: String)
}

public struct KeepRootView: View {
  @ObservedObject private var session: KeepSession
  private let connect: () async -> Void
  private let anchor: @MainActor () -> ASPresentationAnchor
  private let landing: KeepLanding

  public init(session: KeepSession, landing: KeepLanding = .vaults, connect: @escaping () async -> Void, anchor: @escaping @MainActor () -> ASPresentationAnchor) {
    self.session = session
    self.landing = landing
    self.connect = connect
    self.anchor = anchor
  }

  public var body: some View {
    Group {
      switch session.state {
      case .disconnected:
        KeepGate(title: "Keep", message: "Connect Keep to open your vaults on this device.") {
          KeepAsyncButton("Connect Keep", systemImage: "link") { await connect() }
            .buttonStyle(EnvisioningFilledButtonStyle(minHeight: 44, expands: false))
        }
      case .loading:
        EnvisioningLoadingState("Connecting…").background(crmGroupedBackground)
      case .failed(let message):
        KeepGate(title: "Keep", message: message) {
          KeepAsyncButton("Try again", systemImage: "arrow.clockwise") { await session.refresh() }
            .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 44, expands: false))
        }
      case .unenrolled(let me):
        KeepEnrolView(session: session, me: me, anchor: anchor, replace: false)
      case .locked:
        KeepUnlockView(session: session, anchor: anchor)
      case .unlocked:
        #if os(macOS)
          KeepSplitView(session: session, anchor: anchor, landing: landing)
        #else
          switch landing {
          case .vaults:
            KeepVaultsView(session: session, anchor: anchor)
          case .project(let id, let name):
            KeepProjectVaultView(session: session, projectId: id, projectName: name)
          }
        #endif
      }
    }
    .task { await session.refresh() }
  }
}

/// `KeepRootView` inside a `NavigationStack`, for a host that has none —
/// the Mac window. On iOS the Work stack is the host; push `KeepRootView`.
public struct KeepStandaloneView: View {
  @ObservedObject private var session: KeepSession
  private let connect: () async -> Void
  private let anchor: @MainActor () -> ASPresentationAnchor
  private let landing: KeepLanding

  public init(session: KeepSession, landing: KeepLanding = .vaults, connect: @escaping () async -> Void, anchor: @escaping @MainActor () -> ASPresentationAnchor) {
    self.session = session
    self.landing = landing
    self.connect = connect
    self.anchor = anchor
  }

  public var body: some View {
    #if os(macOS)
      // The split view is its own navigation; the gates before it need none.
      KeepRootView(session: session, landing: landing, connect: connect, anchor: anchor)
    #else
      NavigationStack {
        KeepRootView(session: session, landing: landing, connect: connect, anchor: anchor)
      }
    #endif
  }
}

/// The project door on iOS: find or make the project's vault, then show it.
struct KeepProjectVaultView: View {
  @ObservedObject var session: KeepSession
  let projectId: String
  let projectName: String
  @State private var vaultId: String?
  @State private var error: String?

  var body: some View {
    Group {
      if let vaultId {
        KeepVaultView(session: session, vaultId: vaultId)
      } else if let error {
        KeepGate(title: projectName, message: error) {
          KeepAsyncButton("Try again", systemImage: "arrow.clockwise") { await resolve() }
            .buttonStyle(EnvisioningBorderedButtonStyle(minHeight: 44, expands: false))
        }
      } else {
        EnvisioningLoadingState("Opening vault…").background(crmGroupedBackground)
      }
    }
    .task { await resolve() }
  }

  private func resolve() async {
    error = nil
    do {
      vaultId = try await session.ensureVault(forProject: projectId, named: projectName)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

// MARK: - Shared bits

struct KeepGate<Actions: View>: View {
  let title: String
  let message: String
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "key.fill").font(.system(size: 34)).foregroundStyle(crmSecondaryText)
      Text(title).font(.title2.weight(.semibold))
      Text(message).font(.callout).foregroundStyle(crmSecondaryText).multilineTextAlignment(.center)
      actions
    }
    .padding(32)
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(crmGroupedBackground)
  }
}

/// A button that runs an async action and shows a spinner meanwhile.
struct KeepAsyncButton: View {
  let title: String
  let systemImage: String?
  let role: ButtonRole?
  let action: () async -> Void
  @State private var busy = false

  init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () async -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.role = role
    self.action = action
  }

  var body: some View {
    Button(role: role) {
      guard !busy else { return }
      busy = true
      Task {
        await action()
        busy = false
      }
    } label: {
      HStack(spacing: 6) {
        if busy {
          ProgressView().controlSize(.small)
        } else if let systemImage {
          Image(systemName: systemImage)
        }
        Text(title)
      }
    }
    .disabled(busy)
  }
}

/// A text or secure field on the ladder: the `field` rung in a `field`
/// radius with the house hairline. Never the system's rounded border.
struct KeepFieldStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .padding(.horizontal, 12)
      .frame(minHeight: 40)
      .background(EnvisioningSurface.field, in: RoundedRectangle(cornerRadius: EnvisioningRadius.field, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: EnvisioningRadius.field, style: .continuous).strokeBorder(EnvisioningSurface.border))
  }
}

extension View {
  func keepField() -> some View { modifier(KeepFieldStyle()) }
}

struct KeepErrorText: View {
  let message: String?
  var body: some View {
    if let message {
      Text(message).font(.footnote).foregroundStyle(EnvisioningSemantics.danger)
    }
  }
}

func keepWhen(_ iso: String) -> String {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let date = fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
  guard let date else { return iso }
  return date.formatted(date: .abbreviated, time: .shortened)
}

/// A secret entry with an eye: masked by default, shown on demand. Every
/// place Keep takes a password or passphrase uses this — a person should
/// always be able to see what they typed.
struct KeepSecretField: View {
  let title: String
  @Binding var text: String
  var contentType: KeepSecretContentType = .newPassword
  @State private var shown = false

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if shown {
          TextField(title, text: $text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        } else {
          SecureField(title, text: $text)
            .textContentType(contentType == .newPassword ? .newPassword : .password)
        }
      }
      .textFieldStyle(.plain)
      Button {
        shown.toggle()
      } label: {
        Image(systemName: shown ? "eye.slash" : "eye")
          .foregroundStyle(crmSecondaryText)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(shown ? "Hide \(title)" : "Show \(title)")
    }
  }
}

enum KeepSecretContentType { case newPassword, password }

/// The vault glyph picker: a grid of the house's short list.
struct KeepIconPicker: View {
  @Binding var icon: String?
  private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(KeepVaultIcon.choices, id: \.self) { choice in
        let selected = KeepVaultIcon.symbol(icon) == choice
        Button {
          icon = choice == KeepVaultIcon.default ? nil : choice
        } label: {
          Image(systemName: choice)
            .font(.system(size: 18))
            .frame(width: 44, height: 40)
            .foregroundStyle(selected ? EnvisioningAccent.ink : crmSecondaryText)
            .background(
              RoundedRectangle(cornerRadius: EnvisioningRadius.field, style: .continuous)
                .fill(selected ? EnvisioningAccent.fill : EnvisioningSurface.field)
            )
            .overlay(
              RoundedRectangle(cornerRadius: EnvisioningRadius.field, style: .continuous)
                .strokeBorder(selected ? Color.clear : EnvisioningSurface.border)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(.vertical, 4)
  }
}
