import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import Oesap

final class ImagePreparationServiceTests: XCTestCase {
  func testDisplayDecodeDownsamplesPixelsBeforeRendering() async throws {
    let input = try makePNG(width: 1_200, height: 600, withAlpha: true)
    let image = try await ImageDisplayDecoder.shared.decode(input, maximumPixelEdge: 384)
    XCTAssertEqual(image.width, 384)
    XCTAssertEqual(image.height, 192)
  }

  func testDisplayDecodeRejectsInvalidBytes() async {
    do {
      _ = try await ImageDisplayDecoder.shared.decode(
        Data("not an image".utf8), maximumPixelEdge: 384)
      XCTFail("Expected invalid image to be rejected")
    } catch {
      XCTAssertEqual(error as? ImagePreparationError, .invalidImage)
    }
  }

  func testTransparentImageKeepsAlphaAndProducesBoundedPNG() async throws {
    let input = try makePNG(width: 16, height: 16, withAlpha: true)
    let prepared = try await ImagePreparationService.prepare(
      data: input, fileName: "folder/secret\u{0000}preview.png")

    XCTAssertEqual(prepared.mimeType, "image/png")
    XCTAssertEqual(prepared.fileName, "secretpreview.png")
    XCTAssertLessThanOrEqual(prepared.data.count, RemoteImageLimits.maximumOutgoingBytes)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertTrue(
      [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast]
        .contains(image.alphaInfo))
  }

  func testPreparationRejectsInvalidAndOversizeInputs() async throws {
    do {
      _ = try await ImagePreparationService.prepare(data: Data([0, 1, 2]))
      XCTFail("Invalid image must be rejected")
    } catch ImagePreparationError.invalidImage {}

    do {
      _ = try await ImagePreparationService.prepare(
        data: Data(count: RemoteImageLimits.maximumInputBytes + 1))
      XCTFail("Oversize input must be rejected before decoding")
    } catch ImagePreparationError.inputTooLarge {}
  }

  func testDisplayNormalizationDownsamplesImage() async throws {
    let input = try makePNG(width: 2_500, height: 8, withAlpha: false)
    let normalized = try await ImageByteProcessor.normalizeForDisplay(input)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertLessThanOrEqual(max(image.width, image.height), RemoteImageLimits.maximumPixelEdge)
    XCTAssertLessThanOrEqual(normalized.count, RemoteImageLimits.maximumDisplayBytes)
  }

  private func makePNG(width: Int, height: Int, withAlpha: Bool) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    if withAlpha {
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    } else {
      context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = try XCTUnwrap(context.makeImage())
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return bytes as Data
  }
}
