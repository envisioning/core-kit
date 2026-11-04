import Foundation

public enum SignalsAudience: String, Sendable {
  case general, client, partner
}

public struct SignalsMailDraft: Sendable, Equatable {
  public let recipient: String
  public let subject: String
  public let body: String
  public let audience: SignalsAudience
  public let language: String

  public init(
    recipient: String, subject: String, body: String, audience: SignalsAudience, language: String
  ) {
    self.recipient = recipient
    self.subject = subject
    self.body = body
    self.audience = audience
    self.language = language
  }

  /// A `mailto:` URL that opens the user's mail composer prefilled with the draft.
  public var mailtoURL: URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = recipient
    components.queryItems = [
      URLQueryItem(name: "subject", value: subject),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url
  }
}

/// Signals prospecting-outreach logic for the iOS worklist.
///
/// The mail copy is ported **verbatim** from the canonical web source,
/// `envisioning-core/src/lib/signals-outreach-messages.ts`. Keep the two in sync
/// (or, better, replace both with a server-rendered draft endpoint) — do not
/// rewrite the copy here, or the iOS drafts drift from what the web sends.
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

  private static func firstName(_ name: String) -> String {
    name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? name
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

  private static func englishCopy(
    _ audience: SignalsAudience, _ name: String, _ organizationName: String?
  ) -> (subject: String, body: String) {
    let organization = organizationName.map { " at \($0)" } ?? ""
    switch audience {
    case .partner:
      return (
        "A new Signals platform from Envisioning",
        "Hi \(name),\n\nWe have been building Signals, a self-service research platform for identifying and tracking signals of change. I thought it could be relevant to your work\(organization), both for your own research and for work with clients.\n\nYou can see it at https://signals.envisioning.com. If it looks useful, I would be happy to show you how it works.\n\nBest,"
      )
    case .client:
      return (
        "Introducing Signals from Envisioning",
        "Hi \(name),\n\nBecause we have worked together before, I wanted to share Signals with you directly. It is our new self-service research platform for identifying and tracking signals of change.\n\nYou can see it at https://signals.envisioning.com. I would be glad to walk you through it if it is relevant to your work\(organization).\n\nBest,"
      )
    case .general:
      return (
        "Introducing Signals from Envisioning",
        "Hi \(name),\n\nI wanted to share Signals, a self-service research platform we have built for identifying and tracking signals of change.\n\nYou can see it at https://signals.envisioning.com. If it is relevant to your work\(organization), I would be happy to show you how it works.\n\nBest,"
      )
    }
  }

  private static func portugueseCopy(
    _ audience: SignalsAudience, _ name: String, _ organizationName: String?
  ) -> (subject: String, body: String) {
    let organization = organizationName.map { " na \($0)" } ?? ""
    switch audience {
    case .partner:
      return (
        "Uma nova plataforma Signals da Envisioning",
        "Olá \(name),\n\nTemos vindo a desenvolver o Signals, uma plataforma de pesquisa self-service para identificar e acompanhar sinais de mudança. Achei que poderia ser relevante para o seu trabalho\(organization), tanto para pesquisa própria como para projetos com clientes.\n\nPode conhecer a plataforma em https://signals.envisioning.com. Se fizer sentido, terei todo o gosto em mostrar como funciona.\n\nUm abraço,"
      )
    case .client:
      return (
        "Apresentamos o Signals da Envisioning",
        "Olá \(name),\n\nComo já trabalhámos juntos, queria partilhar consigo diretamente o Signals. É a nossa nova plataforma de pesquisa self-service para identificar e acompanhar sinais de mudança.\n\nPode conhecer a plataforma em https://signals.envisioning.com. Terei todo o gosto em apresentar como funciona se for relevante para o seu trabalho\(organization).\n\nUm abraço,"
      )
    case .general:
      return (
        "Apresentamos o Signals da Envisioning",
        "Olá \(name),\n\nQueria partilhar consigo o Signals, uma plataforma de pesquisa self-service que desenvolvemos para identificar e acompanhar sinais de mudança.\n\nPode conhecer a plataforma em https://signals.envisioning.com. Se for relevante para o seu trabalho\(organization), terei todo o gosto em mostrar como funciona.\n\nUm abraço,"
      )
    }
  }

  /// Build a prospecting mail draft for a contact, or `nil` when there is no
  /// recipient email. Mirrors `buildSignalsMailto` in the web source.
  public static func mailDraft(
    name: String,
    email: String?,
    corporateEmail: String? = nil,
    organizationName: String?,
    language: String,
    isExistingClient: Bool = false,
    isPartner: Bool = false
  ) -> SignalsMailDraft? {
    // Prefer the corporate address, falling back to the personal one — 1:1 with
    // `buildSignalsMailto` in the web source.
    let corp = corporateEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
    let personal = email?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let recipient = [corp, personal].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
      return nil
    }
    let audience = audience(isExistingClient: isExistingClient, isPartner: isPartner)
    let copy =
      language == "pt"
      ? portugueseCopy(audience, firstName(name), organizationName)
      : englishCopy(audience, firstName(name), organizationName)
    return SignalsMailDraft(
      recipient: recipient, subject: copy.subject, body: copy.body,
      audience: audience, language: language)
  }
}
