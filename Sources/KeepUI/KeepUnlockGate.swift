import AuthenticationServices
import CoreCRMUI
import EnvisioningUI
import KeepKit
import SwiftUI

/// Keep's gates around a host's own content: connect, enrol and unlock, then
/// `content` once the key is in memory. For a host screen that needs the key
/// for one act, such as approving an agent's release (envisioning/keep#5),
/// without the vault list.
public struct KeepUnlockGate<Content: View>: View {
  @ObservedObject private var session: KeepSession
  private let connect: () async -> Void
  private let anchor: @MainActor () -> ASPresentationAnchor
  private let content: () -> Content

  public init(
    session: KeepSession,
    connect: @escaping () async -> Void,
    anchor: @escaping @MainActor () -> ASPresentationAnchor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.session = session
    self.connect = connect
    self.anchor = anchor
    self.content = content
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
        content()
      }
    }
    .task { await session.refresh() }
  }
}
