import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A native text view is used for both composer sizes so UIKit can keep its
/// standard text-paste behavior while routing pasted images into the draft.
@MainActor
struct NativeImagePasteTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  let isExpanded: Bool
  let canSubmit: Bool
  let onSubmit: () -> Void
  let onPasteImage: (Data, Int) -> Void
  let onPasteStarted: () -> Int
  let onPasteFailed: (String, Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = ImagePasteTextView()
    textView.delegate = context.coordinator
    textView.pasteImage = { [weak coordinator = context.coordinator] in
      coordinator?.pasteImageFromClipboard() ?? false
    }
    textView.backgroundColor = .clear
    textView.textColor = .label
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    textView.textContainer.lineFragmentPadding = 0
    textView.returnKeyType = isExpanded ? .default : .send
    textView.accessibilityLabel = accessibilityLabel
    textView.accessibilityIdentifier = accessibilityIdentifier
    textView.text = text
    textView.isScrollEnabled = true
    context.coordinator.parent = self
    context.coordinator.updateMarkdownStyle(on: textView)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self
    if textView.text != text, textView.markedTextRange == nil {
      let selection = textView.selectedRange
      textView.text = text
      textView.selectedRange = NSRange(
        location: min(selection.location, (text as NSString).length),
        length: 0)
    }
    context.coordinator.updateMarkdownStyle(on: textView)
    textView.returnKeyType = isExpanded ? .default : .send
    textView.accessibilityLabel = accessibilityLabel
    textView.accessibilityIdentifier = accessibilityIdentifier
    updateScrolling(textView)
    context.coordinator.requestFirstResponder(isFocused, on: textView)
  }

  static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
    coordinator.cancelMarkdownParse()
    uiView.delegate = nil
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let proposedWidth = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let width = proposedWidth ?? uiView.bounds.width
    guard width.isFinite, width > 0 else { return nil }
    if isExpanded {
      let proposedHeight = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      let boundsHeight =
        uiView.bounds.height.isFinite && uiView.bounds.height > 0
        ? uiView.bounds.height : 320
      let height = proposedHeight ?? boundsHeight
      return CGSize(width: width, height: height)
    }

    let measured = uiView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    let maximumHeight = maximumCompactHeight(for: uiView)
    let height = min(max(48, measured), maximumHeight)
    return CGSize(width: width, height: height)
  }

  private func updateScrolling(_ textView: UITextView) {
    guard !isExpanded, textView.bounds.width.isFinite, textView.bounds.width > 0 else {
      if isExpanded { textView.isScrollEnabled = true }
      return
    }
    let measured = textView.sizeThatFits(
      CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
    ).height
    textView.isScrollEnabled = measured > maximumCompactHeight(for: textView)
  }

  private func maximumCompactHeight(for textView: UITextView) -> CGFloat {
    let lines: CGFloat =
      textView.traitCollection.preferredContentSizeCategory
        .isAccessibilityCategory ? 2 : 5
    return max(
      48,
      (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight * lines + 20
    )
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: NativeImagePasteTextView
    private var programmaticFocusTarget: Bool?
    private var focusUpdateGeneration = 0
    private var isApplyingStyle = false
    private var lastStyledSource: String?
    private var lastStyledBlock: NSRange?
    private var lastStyledBodySize: CGFloat = 0
    private var lastStyledFocus = false
    private let markdownParser = LiveMarkdownParser()
    private var markdownPlan: LiveMarkdownStyler.Plan?
    private var parsingSource: String?
    private var parseGeneration = 0
    private var parseTask: Task<Void, Never>?

    init(parent: NativeImagePasteTextView) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isApplyingStyle else { return }
      parent.text = textView.text
      updateMarkdownStyle(on: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingStyle else { return }
      updateMarkdownStyle(on: textView)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      guard textView.isFirstResponder else { return }
      updateMarkdownStyle(on: textView)
      if programmaticFocusTarget == true {
        programmaticFocusTarget = nil
        return
      }
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      guard !textView.isFirstResponder else { return }
      updateMarkdownStyle(on: textView)
      if programmaticFocusTarget == false {
        programmaticFocusTarget = nil
        return
      }
      parent.isFocused = false
    }

    func requestFirstResponder(_ shouldFocus: Bool, on textView: UITextView) {
      focusUpdateGeneration += 1
      let update = focusUpdateGeneration
      Task { @MainActor [weak self, weak textView] in
        await Task.yield()
        guard let self, let textView,
          self.focusUpdateGeneration == update,
          textView.isFirstResponder != shouldFocus,
          textView.window != nil
        else { return }
        self.programmaticFocusTarget = shouldFocus
        if shouldFocus {
          textView.becomeFirstResponder()
        } else {
          textView.resignFirstResponder()
        }
        Task { @MainActor [weak self] in
          try? await Task.sleep(nanoseconds: 500_000_000)
          guard self?.focusUpdateGeneration == update else { return }
          self?.programmaticFocusTarget = nil
        }
      }
    }

    func updateMarkdownStyle(on textView: UITextView) {
      // The system owns composition while an input method has marked text.
      // Reformatting it mid-composition can replace the marked range or move
      // the caret, especially for CJK keyboards.
      guard !isApplyingStyle, textView.markedTextRange == nil else { return }
      let source = textView.text ?? ""
      guard let plan = markdownPlan, plan.source == source else {
        scheduleMarkdownParse(for: source, on: textView)
        return
      }
      applyMarkdownStyle(plan, on: textView)
    }

    func cancelMarkdownParse() {
      parseTask?.cancel()
      parseGeneration += 1
      parsingSource = nil
    }

    private func scheduleMarkdownParse(for source: String, on textView: UITextView) {
      guard parsingSource != source else { return }
      parseTask?.cancel()
      parseGeneration += 1
      let generation = parseGeneration
      parsingSource = source
      let parser = markdownParser
      parseTask = Task { @MainActor [weak self, weak textView] in
        let plan = await parser.parse(source)
        guard let self, let textView,
          !Task.isCancelled, self.parseGeneration == generation
        else { return }
        self.parsingSource = nil
        guard textView.text == source, textView.markedTextRange == nil else { return }
        self.markdownPlan = plan
        self.applyMarkdownStyle(plan, on: textView)
      }
    }

    private func applyMarkdownStyle(_ plan: LiveMarkdownStyler.Plan, on textView: UITextView) {
      guard !isApplyingStyle, textView.markedTextRange == nil else { return }
      let bodyFont = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: textView.traitCollection)
      let focus = textView.isFirstResponder
      let caret = focus ? textView.selectedRange.location : nil
      let block = plan.activeBlock(at: caret)
      guard
        plan.source != lastStyledSource || block != lastStyledBlock
          || bodyFont.pointSize != lastStyledBodySize || focus != lastStyledFocus
      else { return }

      let styled = plan.attributedSource(
        activeUTF16Location: caret, bodyFont: bodyFont,
        traitCollection: textView.traitCollection)
      guard styled.string == plan.source else { return }
      let selection = textView.selectedRange
      isApplyingStyle = true
      let undoManager = textView.undoManager
      undoManager?.disableUndoRegistration()
      textView.textStorage.beginEditing()
      styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) {
        attributes, range, _ in
        textView.textStorage.setAttributes(attributes, range: range)
      }
      textView.textStorage.endEditing()
      undoManager?.enableUndoRegistration()
      // Attribute edits do not change source ranges. Keep the insertion point
      // when a heading or inline span changes shape.
      if textView.selectedRange != selection { textView.selectedRange = selection }
      textView.typingAttributes = [
        .font: bodyFont,
        .foregroundColor: UIColor.label,
      ]
      isApplyingStyle = false
      lastStyledSource = plan.source
      lastStyledBlock = block
      lastStyledBodySize = bodyFont.pointSize
      lastStyledFocus = focus
    }

    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard !parent.isExpanded, text == "\n" else { return true }
      if parent.canSubmit {
        parent.onSubmit()
      }
      return false
    }

    func pasteImageFromClipboard() -> Bool {
      let imageProviders = UIPasteboard.general.itemProviders.compactMap {
        provider -> (NSItemProvider, String)? in
        guard
          let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
          })
        else { return nil }
        return (provider, imageType)
      }
      guard !imageProviders.isEmpty else { return false }
      let onPasteImage = parent.onPasteImage
      let onPasteStarted = parent.onPasteStarted
      let onPasteFailed = parent.onPasteFailed
      for (provider, imageType) in imageProviders.prefix(RemoteImageLimits.maximumCount) {
        let generation = onPasteStarted()
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, error in
          Task { @MainActor in
            if let data {
              onPasteImage(data, generation)
            } else {
              onPasteFailed(
                error?.localizedDescription ?? "Couldn’t read the pasted image.", generation)
            }
          }
        }
      }
      return true
    }
  }
}

/// Handle image data only after the user invokes the system Paste action.
/// Ordinary text pastes keep UITextView's native editing path.
@MainActor
private final class ImagePasteTextView: UITextView {
  var pasteImage: (() -> Bool)?

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    if pasteImage?() == true { return }
    super.paste(sender)
  }
}
