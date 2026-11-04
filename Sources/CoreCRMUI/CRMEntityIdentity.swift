import CoreKit
import Foundation

/// Single source of truth for how a CRM entity presents its *identity* — the
/// large centered header on its detail screen, the avatar in list rows and
/// search results, and the subtitle line shown under its name.
///
/// Known CRM identities have explicit defaults; all other entities derive their
/// visuals from registry field kinds. `resolve` remains the single place where
/// detail, list, and search presentation decisions are made.
public struct CRMEntityIdentity {
  /// Record fields probed, in order, for this entity's own image URL.
  public let imageFields: [String]
  /// Record fields containing inline SVG markup. CMS contracts use these for
  /// logos and illustrations that should participate in the same visual header
  /// treatment as raster image fields.
  public let svgFields: [String]
  /// Fields probed, in order, for the subtitle shown under the name. First
  /// non-empty wins; empty means the header shows just the image and name.
  public let subtitleFields: [String]
  /// Whether the detail screen renders the large centered identity header.
  public let usesCenteredHeader: Bool
  /// CMS/content visuals are rectangular hero art rather than circular avatars.
  public let usesHeroLayout: Bool

  public init(
    imageFields: [String],
    svgFields: [String] = [],
    subtitleFields: [String],
    usesCenteredHeader: Bool,
    usesHeroLayout: Bool = false
  ) {
    self.imageFields = imageFields
    self.svgFields = svgFields
    self.subtitleFields = subtitleFields
    self.usesCenteredHeader = usesCenteredHeader
    self.usesHeroLayout = usesHeroLayout
  }

  /// Whether this entity ever shows an avatar/logo (drives list & search rows).
  public var showsAvatar: Bool { !imageFields.isEmpty }

  public static func resolve(id: String) -> CRMEntityIdentity {
    switch id {
    case "contacts":
      return .init(
        imageFields: ["profile_image_url"],
        subtitleFields: ["headline", "tagline"],
        usesCenteredHeader: true
      )
    case "organizations":
      return .init(
        imageFields: ["profile_image_url", "logo_image_url"],
        subtitleFields: ["industry"],
        usesCenteredHeader: true
      )
    case "milestones":
      return .init(
        imageFields: ["public_image_url"],
        subtitleFields: [],
        usesCenteredHeader: true
      )
    default:
      return .init(imageFields: [], subtitleFields: [], usesCenteredHeader: false)
    }
  }

  public static func resolve(_ contract: CRMEntityContract) -> CRMEntityIdentity {
    let configured = resolve(id: contract.id)
    if configured.usesCenteredHeader || configured.showsAvatar {
      return configured
    }

    // CMS identity is registry-driven: every present and future content type
    // with an image/SVG field gets the same hero treatment without adding its
    // entity id here. Secondary fields provide a consistent subtitle fallback.
    let imageFields = contract.fields.filter { $0.kind == "image" }.map(\.name)
    let svgFields = contract.fields.filter { $0.kind == "svg" }.map(\.name)
    let hasVisual = !imageFields.isEmpty || !svgFields.isEmpty
    return .init(
      imageFields: imageFields,
      svgFields: svgFields,
      subtitleFields: contract.secondaryFields.filter {
        $0 != contract.primaryField && !imageFields.contains($0) && !svgFields.contains($0)
      },
      usesCenteredHeader: hasVisual,
      usesHeroLayout: hasVisual
    )
  }

  /// Every image field any entity might use, for the contract-less
  /// ``CRMRecord/avatarURL`` resolver.
  public static let allImageFields: [String] = ["profile_image_url", "logo_image_url", "public_image_url"]
}

extension CRMRecord {
  /// The record's *own* avatar/logo URL. A record never inherits a related
  /// entity's image — a contact is a separate thing from its organization, so it
  /// falls back to initials/symbol, not the company logo. The organization card
  /// renders the org's logo from the org's own record, which is the right place
  /// for it.
  public var avatarURL: URL? {
    guard let raw = Self.firstImageURLString({ self[$0] }),
      let url = URL(string: raw),
      ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    else { return nil }
    return url
  }

  /// The first safe raster image URL declared by this entity's presentation
  /// contract. Unlike `avatarURL`, this supports arbitrary CMS field names.
  func imageURL(for contract: CRMEntityContract) -> URL? {
    let identity = CRMEntityIdentity.resolve(contract)
    for field in identity.imageFields {
      guard let raw = self[field]?.stringValue, !raw.isEmpty,
        let url = URL(string: raw),
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
      else { continue }
      return url
    }
    return nil
  }

  /// The first non-empty inline SVG declared by this entity's contract.
  func svgMarkup(for contract: CRMEntityContract) -> String? {
    for field in CRMEntityIdentity.resolve(contract).svgFields {
      if let value = self[field]?.stringValue, !value.isEmpty { return value }
    }
    return nil
  }

  private static func firstImageURLString(_ lookup: (String) -> JSONValue?) -> String? {
    for field in CRMEntityIdentity.allImageFields {
      if let value = lookup(field)?.stringValue, !value.isEmpty { return value }
    }
    // Legacy camelCase shape from older payloads.
    return lookup("profileImageUrl")?.stringValue
  }
}
