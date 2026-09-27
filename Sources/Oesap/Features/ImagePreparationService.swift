import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImagePreparationService {
  static func prepare(data: Data, fileName: String? = nil) async throws -> RemoteDraftImage {
    try Task.checkCancellation()
    guard !data.isEmpty else { throw ImagePreparationError.invalidImage }
    guard data.count <= RemoteImageLimits.maximumInputBytes else {
      throw ImagePreparationError.inputTooLarge
    }

    let image = try await ImageProcessingActor.shared.normalize(
      data, maximumBytes: RemoteImageLimits.maximumOutgoingBytes)
    try Task.checkCancellation()
    return RemoteDraftImage(
      data: image.data,
      mimeType: image.mimeType,
      fileName: safeFileName(fileName)
    )
  }

  // Keep the instance entry point for consumers that inject this small service.
  func prepare(data: Data, fileName: String? = nil) async throws -> RemoteDraftImage {
    try await Self.prepare(data: data, fileName: fileName)
  }

  private static func safeFileName(_ fileName: String?) -> String? {
    guard let fileName else { return nil }
    let name =
      fileName.replacingOccurrences(of: "\\", with: "/")
      .split(separator: "/", omittingEmptySubsequences: false).last ?? ""
    let cleaned = String(
      name.filter { character in
        character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }.prefix(96))
    return cleaned.isEmpty ? nil : cleaned
  }
}

enum ImagePreparationError: LocalizedError, Equatable {
  case inputTooLarge
  case invalidImage
  case imageTooLargeAfterNormalization

  var errorDescription: String? {
    switch self {
    case .inputTooLarge:
      "Image exceeds the 20 MB import limit."
    case .invalidImage:
      "This file could not be decoded as an image."
    case .imageTooLargeAfterNormalization:
      "Image could not fit within the 2 MB attachment limit."
    }
  }
}

private struct NormalizedImage: Sendable {
  var data: Data
  var mimeType: String
}

/// Serializes ImageIO work away from the main actor. No unstructured task can
/// outlive the caller and later add an attachment after it was cancelled.
private actor ImageProcessingActor {
  static let shared = ImageProcessingActor()

  func normalize(_ data: Data, maximumBytes: Int) throws -> NormalizedImage {
    try ImageByteProcessor.normalize(
      data,
      maximumEdge: RemoteImageLimits.maximumPixelEdge,
      maximumBytes: maximumBytes
    )
  }
}

/// ImageIO corrects orientation, downsamples and re-encodes without carrying
/// source metadata into either outbound or displayed image bytes.
enum ImageByteProcessor {
  static func normalizeForDisplay(_ data: Data) async throws -> Data {
    try Task.checkCancellation()
    guard !data.isEmpty else { throw ImagePreparationError.invalidImage }
    guard data.count <= RemoteImageLimits.maximumDisplayBytes else {
      throw ImagePreparationError.inputTooLarge
    }
    let image = try await ImageProcessingActor.shared.normalize(
      data, maximumBytes: RemoteImageLimits.maximumDisplayBytes)
    try Task.checkCancellation()
    return image.data
  }

  fileprivate static func normalize(
    _ data: Data, maximumEdge: Int, maximumBytes: Int
  ) throws -> NormalizedImage {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0,
      width <= 100_000, height <= 100_000,
      Int64(width) * Int64(height) <= 200_000_000
    else { throw ImagePreparationError.invalidImage }

    let sizes = Array(Set([maximumEdge, 1_792, 1_536, 1_280, 1_024, 768, 512]))
      .sorted(by: >)
    for edge in sizes where edge <= maximumEdge {
      try Task.checkCancellation()
      guard
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
          source,
          0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary
        )
      else { continue }

      if hasAlpha(thumbnail),
        let encoded = encode(thumbnail, type: .png), encoded.count <= maximumBytes
      {
        return NormalizedImage(data: encoded, mimeType: UTType.png.preferredMIMEType ?? "image/png")
      }

      guard let flattened = flattenOnWhite(thumbnail) else { continue }
      for quality in [0.82, 0.72, 0.62, 0.52, 0.42, 0.32, 0.24] {
        try Task.checkCancellation()
        if let encoded = encode(flattened, type: .jpeg, quality: quality),
          encoded.count <= maximumBytes
        {
          return NormalizedImage(
            data: encoded, mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg")
        }
      }
    }
    throw ImagePreparationError.imageTooLargeAfterNormalization
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
      true
    default:
      false
    }
  }

  private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: info
      )
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  private static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, type.identifier as CFString, 1, nil
      )
    else { return nil }
    let options: CFDictionary? = quality.map {
      [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
    }
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
