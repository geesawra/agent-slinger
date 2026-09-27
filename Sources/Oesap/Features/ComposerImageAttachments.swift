import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ComposerImagePickerButton: View {
  enum Presentation: Equatable {
    case compact
    case expanded
  }

  let remainingCount: Int
  let imageImportIdentity: String
  var presentation: Presentation = .expanded
  let onOperationStarted: () -> Int
  let onImageLoaded: (Data, String?, Int) -> Void
  let onOperationFailed: (String, Int) -> Void

  @State private var selectedPhotos: [PhotosPickerItem] = []
  @State private var showsPhotosPicker = false
  @State private var showsFileImporter = false
  @State private var photosTask: Task<Void, Never>?
  @State private var fileTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      attachmentMenu

      Color.clear
        .frame(width: 1, height: 1)
        .photosPicker(
          isPresented: $showsPhotosPicker,
          selection: $selectedPhotos,
          maxSelectionCount: max(1, remainingCount),
          matching: .images
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      Color.clear
        .frame(width: 1, height: 1)
        .fileImporter(
          isPresented: $showsFileImporter,
          allowedContentTypes: [.image],
          allowsMultipleSelection: true,
          onCompletion: handleFileImport
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .fixedSize()
    .onChange(of: selectedPhotos) { _, items in loadPhotos(items) }
    .onChange(of: imageImportIdentity) { _, _ in cancelImports() }
    .onDisappear(perform: cancelImports)
  }

  @ViewBuilder
  private var attachmentMenu: some View {
    let button = Menu {
      Button("Choose from Photos", systemImage: "photo") {
        Task { @MainActor in
          await Task.yield()
          showsPhotosPicker = true
        }
      }
      Button("Choose from Files", systemImage: "folder") {
        Task { @MainActor in
          await Task.yield()
          showsFileImporter = true
        }
      }
    } label: {
      Image(systemName: presentation == .compact ? "plus" : "paperclip")
        .font(.system(size: 17, weight: .medium))
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
    .controlSize(.small)
    .accessibilityLabel("Attach image")
    .accessibilityIdentifier("attach-image")
    .disabled(remainingCount <= 0)

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .tint(Color(uiColor: .label))
    } else {
      button
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
  }

  private func loadPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    let selected = Array(items.prefix(remainingCount))
    let generations = selected.map { _ in onOperationStarted() }
    photosTask?.cancel()
    photosTask = Task { @MainActor in
      for index in selected.indices {
        let item = selected[index]
        let generation = generations[index]
        guard !Task.isCancelled else {
          for pendingGeneration in generations[index...].reversed() {
            onOperationFailed("Image import was canceled.", pendingGeneration)
          }
          break
        }
        do {
          let data = try await ImageImportService.shared.readPickedPhoto(item)
          onImageLoaded(data, nil, generation)
        } catch {
          onOperationFailed(error.localizedDescription, generation)
        }
      }
      selectedPhotos = []
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      let selected = Array(urls.prefix(remainingCount))
      let generations = selected.map { _ in onOperationStarted() }
      fileTask?.cancel()
      fileTask = Task { @MainActor in
        for index in selected.indices {
          let url = selected[index]
          let generation = generations[index]
          guard !Task.isCancelled else {
            for pendingGeneration in generations[index...].reversed() {
              onOperationFailed("Image import was canceled.", pendingGeneration)
            }
            break
          }
          do {
            let data = try await ImageImportService.shared.readSelectedFile(at: url)
            onImageLoaded(data, url.lastPathComponent, generation)
          } catch {
            onOperationFailed(error.localizedDescription, generation)
          }
        }
      }
    case .failure:
      let generation = onOperationStarted()
      onOperationFailed("Couldn’t open the selected image files.", generation)
    }
  }

  private func cancelImports() {
    photosTask?.cancel()
    fileTask?.cancel()
    Task { @MainActor in
      await Task.yield()
      photosTask = nil
      fileTask = nil
      selectedPhotos = []
    }
  }
}

struct ComposerImageDraftStrip: View {
  @Binding var images: [RemoteDraftImage]
  let isPreparing: Bool
  let error: String?
  let onRemove: (String) -> Void

  var body: some View {
    if !images.isEmpty || isPreparing || error != nil {
      VStack(alignment: .leading, spacing: 6) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
              ImageAttachmentThumbnail(image: image, size: CGSize(width: 96, height: 72)) {
                onRemove(image.id)
              }
              .frame(width: 96, height: 72, alignment: .leading)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("composer-image-\(index)")
            }

            if isPreparing {
              ProgressView()
                .frame(width: 96, height: 72)
                .accessibilityLabel("Preparing image")
                .accessibilityIdentifier("composer-image-preparing")
            }
          }
          .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 76)

        if let error {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("composer-image-error")
        }
      }
      .accessibilityIdentifier("composer-attachment-strip")
      .padding(.horizontal, 8)
      .padding(.top, 8)
    }
  }
}
