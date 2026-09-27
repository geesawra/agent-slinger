import Foundation

enum RemoteImageLimits {
  static let maximumCount = 6
  static let maximumInputBytes = 20 * 1_024 * 1_024
  static let maximumOutgoingBytes = 2 * 1_024 * 1_024
  static let maximumDisplayBytes = 8 * 1_024 * 1_024
  static let maximumPixelEdge = 2_048
}

/// A locally held image chosen by the user. The filename is UI metadata; Paseo
/// sends only the MIME type and base64 bytes.
struct RemoteDraftImage: Identifiable, Sendable, Equatable {
  var id: String
  var data: Data
  var mimeType: String
  var fileName: String?

  init(
    id: String = UUID().uuidString.lowercased(), data: Data, mimeType: String,
    fileName: String? = nil
  ) {
    self.id = id
    self.data = data
    self.mimeType = mimeType
    self.fileName = fileName
  }
}
