import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ImageImportServiceError: LocalizedError {
  case tooLarge
  case unavailable

  var errorDescription: String? {
    switch self {
    case .tooLarge: "Each image must be no larger than 20 MB before preparation."
    case .unavailable: "Couldn’t read the selected image."
    }
  }
}

/// Reads user-selected files on a non-main actor. Both Photos and Files paths
/// are bounded before the app holds image bytes in memory.
actor ImageImportService {
  static let shared = ImageImportService()

  func readSelectedFile(at url: URL) throws -> Data {
    let securityScope = url.startAccessingSecurityScopedResource()
    defer { if securityScope { url.stopAccessingSecurityScopedResource() } }
    return try Self.readBoundedFile(at: url)
  }

  func readPickedPhoto(_ item: PhotosPickerItem) async throws -> Data {
    guard let imported = try await item.loadTransferable(type: BoundedPhotoTransfer.self) else {
      throw ImageImportServiceError.unavailable
    }
    return imported.data
  }

  fileprivate static func readBoundedFile(at url: URL) throws -> Data {
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > RemoteImageLimits.maximumInputBytes
    {
      throw ImageImportServiceError.tooLarge
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var result = Data()
    while true {
      try Task.checkCancellation()
      let remaining = RemoteImageLimits.maximumInputBytes - result.count
      let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
      if chunk.isEmpty { break }
      guard chunk.count <= remaining else { throw ImageImportServiceError.tooLarge }
      result.append(chunk)
    }
    guard !result.isEmpty else { throw ImageImportServiceError.unavailable }
    return result
  }
}

private struct BoundedPhotoTransfer: Transferable {
  let data: Data

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      BoundedPhotoTransfer(data: try ImageImportService.readBoundedFile(at: received.file))
    }
  }
}
