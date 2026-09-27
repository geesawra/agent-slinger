import Foundation
import XCTest

@testable import Oesap

final class ImageImportServiceTests: XCTestCase {
  func testSelectedFileReadsBoundedBytes() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("oesap-image-import-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([1, 2, 3]).write(to: url)
    let bytes = try await ImageImportService.shared.readSelectedFile(at: url)
    XCTAssertEqual(bytes, Data([1, 2, 3]))
  }

  func testSelectedFileRejectsOversizeBeforeReadingIntoMemory() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("oesap-large-image-import-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(RemoteImageLimits.maximumInputBytes + 1))
    try handle.close()

    do {
      _ = try await ImageImportService.shared.readSelectedFile(at: url)
      XCTFail("Oversize input must be refused")
    } catch ImageImportServiceError.tooLarge {}
  }
}
