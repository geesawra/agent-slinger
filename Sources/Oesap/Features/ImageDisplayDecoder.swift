import CoreGraphics
import Foundation
import ImageIO

/// Decode pixels before displaying them so scrolling and typing never trigger
/// a full-resolution decode in a SwiftUI body or on the main actor.
actor ImageDisplayDecoder {
  static let shared = ImageDisplayDecoder()

  func decode(_ data: Data, maximumPixelEdge: Int) throws -> CGImage {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumPixelEdge,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw ImagePreparationError.invalidImage }
    try Task.checkCancellation()
    return image
  }
}
