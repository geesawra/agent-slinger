import MarkdownUI
import SwiftUI
import UIKit

struct ImageAttachmentViewerItem: Identifiable {
  let id: String
  let alt: String
  let localData: Data?
  let remoteSource: MarkdownImageSource?
  let loader: ReceivedImageLoader?

  static func local(_ image: RemoteDraftImage) -> Self {
    .init(
      id: image.id, alt: image.fileName ?? "Selected image", localData: image.data,
      remoteSource: nil, loader: nil)
  }

  static func remote(_ image: MarkdownImageSource, loader: ReceivedImageLoader) -> Self {
    .init(id: image.id, alt: image.alt, localData: nil, remoteSource: image, loader: loader)
  }
}

/// Shared preview for locally selected draft images. Tapping any thumbnail
/// opens a native full-screen viewer; the optional remove control is used by
/// the composer.
struct ImageAttachmentThumbnail: View {
  let image: RemoteDraftImage
  var onRemove: (() -> Void)? = nil

  @State private var viewerItem: ImageAttachmentViewerItem?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        viewerItem = .local(image)
      } label: {
        Group {
          if let uiImage = UIImage(data: image.data) {
            Image(uiImage: uiImage)
              .resizable()
              .scaledToFill()
          } else {
            Label("Image preview unavailable", systemImage: "photo")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.quaternary)
          }
        }
        .frame(width: 96, height: 88)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Preview \(image.fileName ?? "selected image")")

      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.72))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove image")
      }
    }
    .frame(width: 96, height: 88)
    .fullScreenCover(item: $viewerItem) { item in
      ImageAttachmentViewer(item: item)
    }
  }
}

struct ReceivedMarkdownImageProvider: ImageProvider {
  let imagesByID: [String: MarkdownImageSource]
  let loader: ReceivedImageLoader
  let onOpen: (MarkdownImageSource) -> Void

  func makeImage(url: URL?) -> some View {
    if let id = MarkdownImageActionPolicy.imageID(url),
      let image = imagesByID[id]
    {
      ReceivedMarkdownImageThumbnail(image: image, loader: loader) {
        onOpen(image)
      }
    } else {
      Label("Image unavailable", systemImage: "photo")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct ReceivedMarkdownInlineImageProvider: InlineImageProvider {
  let imagesByID: [String: MarkdownImageSource]
  let loader: ReceivedImageLoader

  func image(with url: URL, label: String) async throws -> Image {
    guard let id = MarkdownImageActionPolicy.imageID(url),
      let source = imagesByID[id],
      let data = try? await loader.load(source: source.source),
      let uiImage = await MainActor.run(body: { UIImage(data: data) })
    else {
      return Image(systemName: "photo")
    }
    return await MainActor.run { Image(uiImage: uiImage) }
  }
}

struct MarkdownImageActionPolicy {
  static func imageID(_ url: URL?) -> String? {
    guard let url else { return nil }
    return imageID(url)
  }

  static func imageID(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "oesap-image",
      url.user == nil, url.password == nil, url.port == nil,
      url.path.isEmpty, url.query == nil, url.fragment == nil,
      let host = url.host, host.hasPrefix("image-"),
      let index = Int(host.dropFirst("image-".count)), index >= 0
    else { return nil }
    return host
  }
}

private struct ReceivedMarkdownImageThumbnail: View {
  let image: MarkdownImageSource
  let loader: ReceivedImageLoader
  let onOpen: () -> Void

  @State private var preview: UIImage?
  @State private var failed = false
  @State private var reloadToken = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: onOpen) {
        Group {
          if let preview {
            Image(uiImage: preview)
              .resizable()
              .scaledToFit()
          } else if failed {
            Label("Image unavailable", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: 96)
          }
        }
        .frame(maxWidth: 260, maxHeight: 220)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(image.alt.isEmpty ? "Open image" : "Open image: \(image.alt)")

      if failed {
        Button("Retry image") { reloadToken += 1 }
          .font(.caption)
          .buttonStyle(.bordered)
      }
    }
    .task(id: reloadToken) {
      failed = false
      preview = nil
      do {
        let data = try await loader.load(source: image.source)
        try Task.checkCancellation()
        preview = await MainActor.run { UIImage(data: data) }
        failed = preview == nil
      } catch is CancellationError {
        // The tile left the visible timeline.
      } catch {
        failed = true
      }
    }
  }
}

struct ImageAttachmentViewer: View {
  let item: ImageAttachmentViewerItem

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var image: UIImage?
  @State private var loadFailed = false
  @State private var retryToken = 0
  @State private var magnification = 1.0
  @State private var savedMagnification = 1.0
  @State private var offset = CGSize.zero
  @State private var savedOffset = CGSize.zero

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .scaleEffect(magnification)
          .offset(offset)
          .gesture(
            MagnifyGesture()
              .onChanged { value in
                magnification = min(5, max(1, savedMagnification * value.magnification))
              }
              .onEnded { _ in
                savedMagnification = magnification
                if magnification <= 1 {
                  offset = .zero
                  savedOffset = .zero
                }
              }
          )
          .simultaneousGesture(
            DragGesture()
              .onChanged { value in
                guard magnification > 1 else { return }
                offset = CGSize(
                  width: savedOffset.width + value.translation.width,
                  height: savedOffset.height + value.translation.height
                )
              }
              .onEnded { _ in savedOffset = offset }
          )
          .simultaneousGesture(
            TapGesture(count: 2)
              .onEnded {
                let updateZoom = {
                  if magnification > 1 {
                    magnification = 1
                    savedMagnification = 1
                    offset = .zero
                    savedOffset = .zero
                  } else {
                    magnification = 2
                    savedMagnification = 2
                  }
                }
                if reduceMotion {
                  updateZoom()
                } else {
                  withAnimation(.snappy(duration: 0.2), updateZoom)
                }
              }
          )
          .accessibilityLabel(item.alt.isEmpty ? "Image" : item.alt)
      } else if loadFailed {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle").font(.largeTitle)
          Text("Image could not be loaded")
          Button("Retry") { retryToken += 1 }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
      } else {
        ProgressView("Loading image")
          .tint(.white)
          .foregroundStyle(.white)
      }

      VStack {
        HStack {
          closeButton
          Spacer()
        }
        Spacer()
        if !item.alt.isEmpty {
          Text(item.alt)
            .font(.callout)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
      }
      .padding(.top, 12)
      .padding(.horizontal, 16)
    }
    .task(id: "\(item.id)-\(retryToken)") {
      loadFailed = false
      do {
        let data: Data
        if let localData = item.localData {
          data = localData
        } else if let source = item.remoteSource, let loader = item.loader {
          data = try await loader.load(source: source.source)
        } else {
          throw ImageLoadError.invalidSource
        }
        try Task.checkCancellation()
        image = await MainActor.run { UIImage(data: data) }
        loadFailed = image == nil
      } catch is CancellationError {
        // A dismissed viewer should not keep decoding or retaining image bytes.
      } catch {
        loadFailed = true
      }
    }
  }

  @ViewBuilder
  private var closeButton: some View {
    let button = Button {
      dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.body.weight(.semibold))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .accessibilityLabel("Close image")

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.white)
    } else {
      button
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.white)
        .background(.ultraThinMaterial, in: Circle())
    }
  }
}
