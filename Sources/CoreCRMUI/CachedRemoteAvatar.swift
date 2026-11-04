import CoreKit
import CryptoKit
import EnvisioningUI
import SwiftUI

private actor CRMRemoteImageCache {
  static let shared = CRMRemoteImageCache()

  private let memory = NSCache<NSString, PlatformImage>()
  private let directory: URL

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory = caches.appending(path: "CRMAvatars", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    memory.countLimit = 300
  }

  func image(for url: URL) async -> PlatformImage? {
    let key = cacheKey(for: url)
    if let image = memory.object(forKey: key as NSString) {
      return image
    }

    let fileURL = directory.appending(path: key)
    if let data = try? Data(contentsOf: fileURL), let image = PlatformImage(data: data) {
      memory.setObject(image, forKey: key as NSString)
      return image
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .returnCacheDataElseLoad
    request.timeoutInterval = 20
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
      let image = PlatformImage(data: data)
    else { return nil }

    try? data.write(to: fileURL, options: [.atomic])
    memory.setObject(image, forKey: key as NSString)
    return image
  }

  private func cacheKey(for url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

@MainActor
private final class CRMRemoteImageLoader: ObservableObject {
  @Published var image: PlatformImage?

  func load(_ url: URL?) async {
    guard let url else {
      image = nil
      return
    }
    image = await CRMRemoteImageCache.shared.image(for: url)
  }
}

/// Contacts (and most entities) render as circles; organizations render as an
/// iOS-style squircle (continuous rounded rect) so a company logo reads as a
/// brand mark rather than a headshot. The org-vs-circle rule lives in one place
/// (`resolve(entityID:)`) so call sites just forward their contract id.
public enum CRMAvatarShape {
  case circle
  case squircle

  public static func resolve(entityID: String?) -> CRMAvatarShape {
    entityID == "organizations" ? .squircle : .circle
  }

  /// The `0.2237` ratio matches Apple's app-icon "squircle" corner radius.
  public func path(size: CGFloat) -> AnyShape {
    switch self {
    case .circle:
      return AnyShape(Circle())
    case .squircle:
      return AnyShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }
  }
}

public struct CachedRemoteAvatar: View {
  let url: URL?
  let name: String
  var size: CGFloat = 40
  var fallbackSymbol: String? = nil
  var shape: CRMAvatarShape = .circle

  @StateObject private var loader = CRMRemoteImageLoader()

  private var clip: AnyShape { shape.path(size: size) }

  public init(url: URL?, name: String, size: CGFloat = 40, fallbackSymbol: String? = nil, shape: CRMAvatarShape = .circle) {
    self.url = url; self.name = name; self.size = size; self.fallbackSymbol = fallbackSymbol; self.shape = shape
  }

  public var body: some View {
    ZStack {
      clip.fill(EnvisioningSurface.elevated)
      if let image = loader.image {
        Image(platformImage: image)
          .resizable()
          .scaledToFill()
      } else if !initials.isEmpty {
        Text(initials)
          .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
          .foregroundStyle(crmSecondaryText)
      } else if let fallbackSymbol {
        Image(crmSymbol: fallbackSymbol, fallback: "person.crop.circle")
          .font(.system(size: size * 0.38, weight: .medium))
          .foregroundStyle(crmSecondaryText)
      }
    }
    .frame(width: size, height: size)
    .clipShape(clip)
    .overlay { clip.stroke(.separator.opacity(0.25), lineWidth: 0.5) }
    .task(id: url) { await loader.load(url) }
    .accessibilityHidden(true)
  }

  private var initials: String {
    name.split(whereSeparator: \.isWhitespace)
      .prefix(2)
      .compactMap(\.first)
      .map(String.init)
      .joined()
      .uppercased()
  }
}

/// Rectangular cached remote image for CMS `image` fields (logos, covers, hero
/// art). Reuses the same memory+disk cache as `CachedRemoteAvatar`; scales to
/// fit without cropping. Raster URLs only — inline SVG markup uses `InlineSVGView`.
struct CachedRemoteImage: View {
  let url: URL?
  var contentMode: ContentMode = .fit

  @StateObject private var loader = CRMRemoteImageLoader()

  var body: some View {
    Group {
      if let image = loader.image {
        Image(platformImage: image)
          .resizable()
          .aspectRatio(contentMode: contentMode)
      } else {
        RoundedRectangle(cornerRadius: 8)
          .fill(EnvisioningSurface.elevated)
      }
    }
    .task(id: url) { await loader.load(url) }
  }
}

/// Standard thumbnail for registry-driven content rows. Kept separate from
/// circular CRM avatars so every CMS list uses the same sizing and fallback.
public struct ContentRecordThumbnail: View {
  let contract: CRMEntityContract
  let record: CRMRecord
  var width: CGFloat = 64
  var height: CGFloat = 48
  /// Opt-in because each inline SVG costs a `WKWebView` (see `InlineSVGView`).
  /// Only safe on short lists — the research hubs — never on a paged list of
  /// thousands of technologies.
  var rendersInlineSVG = false

  public init(contract: CRMEntityContract, record: CRMRecord, width: CGFloat = 64, height: CGFloat = 48, rendersInlineSVG: Bool = false) {
    self.contract = contract; self.record = record; self.width = width; self.height = height; self.rendersInlineSVG = rendersInlineSVG
  }

  public var body: some View {
    Group {
      if let imageURL = record.imageURL(for: contract) {
        CachedRemoteImage(url: imageURL, contentMode: .fill)
      } else if rendersInlineSVG, let svg = record.svgMarkup(for: contract) {
        InlineSVGView(svg: svg)
          .padding(4)
          .background(Color.black)
      } else {
        ZStack {
          Rectangle().fill(EnvisioningSurface.elevated)
          Image(crmSymbol: contract.icon, fallback: "photo")
            .foregroundStyle(crmSecondaryText)
        }
      }
    }
    .frame(width: width, height: height)
    .clipShape(.rect(cornerRadius: 8))
    .accessibilityHidden(true)
  }
}
