import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an image becomes before it goes to Docs (meet#345 slice 2). Docs
/// takes PNG, JPEG, WebP or GIF up to `maxBytes` and has no image service,
/// so the device does the work: anything ImageIO reads (HEIC from a phone,
/// TIFF from a Mac pasteboard) is decoded, the long edge is brought to
/// `maxPixels`, and the result is JPEG — or the original bytes, untouched,
/// when they are already a small enough PNG or JPEG. A screenshot of text
/// stays a sharp PNG that way.
public enum DocsImagePrep {
  /// Matches `IMAGE_MAX_BYTES` in envisioning/docs.
  public static let maxBytes = 10 * 1024 * 1024
  public static let maxPixels = 2560

  public struct Prepared: Sendable {
    public let data: Data
    public let contentType: String
  }

  public enum Failure: LocalizedError {
    case unreadable
    case tooLarge

    public var errorDescription: String? {
      switch self {
      case .unreadable: "That file is not an image."
      case .tooLarge: "That image is too large."
      }
    }
  }

  public static func prepare(_ data: Data) throws -> Prepared {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source).map({ $0 as String }),
      CGImageSourceGetCount(source) > 0
    else { throw Failure.unreadable }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let passthrough: [String: String] = [UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg"]
    if let contentType = passthrough[type], max(width, height) <= maxPixels, data.count <= maxBytes {
      return Prepared(data: data, contentType: contentType)
    }

    // The thumbnail call decodes, applies the EXIF orientation and scales in
    // one pass, and never upscales.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw Failure.unreadable
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
    guard out.length <= maxBytes else { throw Failure.tooLarge }
    return Prepared(data: out as Data, contentType: "image/jpeg")
  }
}
