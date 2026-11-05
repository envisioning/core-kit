import Foundation

public enum SignalsAudience: String, Sendable {
  case general, client, partner
}

/// Signals outreach status and audience, for the worklist.
public enum SignalsOutreach {
  /// The contact `signals_outreach_status` progression, mirroring the backend
  /// `SIGNALS_OUTREACH_STATUS_VALUES`.
  public static let statusOrder = [
    "to_notify", "notified", "replied", "interested", "not_interested",
  ]

  /// The statuses that represent live, actionable outreach (excludes the two
  /// terminal states and the empty "not selected").
  public static let actionableStatuses = ["to_notify", "notified", "replied", "interested"]

  public static func statusLabel(_ value: String) -> String {
    switch value {
    case "to_notify": "To notify"
    case "notified": "Notified"
    case "replied": "Replied"
    case "interested": "Interested"
    case "not_interested": "Not interested"
    default: value
    }
  }

  /// The next status when advancing a contact along the positive path. Returns
  /// `nil` at "interested" (end of the positive path) — moving to
  /// "not_interested" is always an explicit choice, never an auto-advance.
  public static func nextStatus(after status: String) -> String? {
    guard let idx = statusOrder.firstIndex(of: status), idx + 1 < statusOrder.count else {
      return nil
    }
    let next = statusOrder[idx + 1]
    return next == "not_interested" ? nil : next
  }

  /// Resolve the outreach audience from the contact's organization flags,
  /// mirroring `resolveAudience` in the web source.
  public static func audience(isExistingClient: Bool, isPartner: Bool) -> SignalsAudience {
    if isPartner { return .partner }
    if isExistingClient { return .client }
    return .general
  }

  /// Short label for the audience, for the "approach" badge on the worklist.
  public static func audienceLabel(_ audience: SignalsAudience) -> String {
    switch audience {
    case .partner: "Partner"
    case .client: "Client"
    case .general: "Prospect"
    }
  }
}
