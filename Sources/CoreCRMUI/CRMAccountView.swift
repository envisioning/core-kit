import CoreKit
import SwiftUI

/// Shared identity/account surface for both the macOS menubar app and the iOS
/// CRM app. Both authenticate the same account with the same personal access
/// token (`TokenManager`, one keychain item), so the "who am I / how do I sign
/// in" block is the one genuinely shared settings concept across the two apps.
///
/// This view is presentation only — it binds the token text and reports commits;
/// each host decides when to persist (iOS on a Save button, macOS on change).
/// It never reveals the stored secret: a saved token is shown masked.
public struct CRMAccountView: View {
  @Binding private var token: String
  private let savedToken: String?
  private let host: String
  private let environmentLabel: String
  private let onCommit: (() -> Void)?

  public init(
    token: Binding<String>,
    savedToken: String?,
    host: String = ServerConfig.host,
    environmentLabel: String = ServerConfig.isProduction ? "Production" : "Custom",
    onCommit: (() -> Void)? = nil
  ) {
    self._token = token
    self.savedToken = savedToken
    self.host = host
    self.environmentLabel = environmentLabel
    self.onCommit = onCommit
  }

  private var savedTokenMask: String? {
    guard let savedToken else { return nil }
    return CRMAccountView.maskToken(savedToken)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let savedTokenMask {
        Label("Signed in · \(savedTokenMask)", systemImage: "checkmark.shield.fill")
          .font(.caption)
          .foregroundStyle(crmSecondaryText)
      } else {
        Label("Not signed in", systemImage: "shield.slash")
          .font(.caption)
          .foregroundStyle(crmSecondaryText)
      }

      SecureField("Personal access token", text: $token)
        .coreField()
        .textContentType(.password)
        .autocorrectionDisabled()
        .modifier(NoAutocapitalization())
        .onSubmit { onCommit?() }

      LabeledContent("Environment", value: environmentLabel)
        .font(.caption)
      LabeledContent("Host", value: host)
        .font(.caption)
    }
  }

  /// Masks a token for display: first four and last four characters with the
  /// middle collapsed. Short tokens are fully redacted. Never returns the raw
  /// value, so it is safe to render on screen.
  public static func maskToken(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8 else { return String(repeating: "•", count: max(trimmed.count, 4)) }
    let prefix = trimmed.prefix(4)
    let suffix = trimmed.suffix(4)
    return "\(prefix)••••\(suffix)"
  }
}

/// `textInputAutocapitalization` is iOS-only; this keeps the shared view
/// compiling on macOS while disabling autocapitalization where it applies.
private struct NoAutocapitalization: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.textInputAutocapitalization(.never)
    #else
      content
    #endif
  }
}
