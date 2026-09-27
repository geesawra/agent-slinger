import UIKit
import XCTest

@testable import Oesap

@MainActor
final class NativeComposerLineMeasurementTests: XCTestCase {
  func testOneTwoAndThreeVisualLinesUseTheActualLayout() {
    let view = makeTextView(width: 240, text: "first")
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), false)

    view.text = "first\nsecond"
    view.layoutIfNeeded()
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), false)

    view.text = "first\nsecond\nthird"
    view.layoutIfNeeded()
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), true)
  }

  func testTrailingBlankLineCountsAsAVisualLine() {
    let view = makeTextView(width: 240, text: "first\nsecond\n")
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), true)
  }

  func testSoftWrappingAndWidthChangesRecomputeThreshold() {
    let view = makeTextView(width: 440, text: "a few words here")
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), false)

    view.frame.size.width = 90
    view.layoutIfNeeded()
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), true)
  }

  func testFormattedHeadingHeightDoesNotCountAsExtraLines() {
    let source = "# Heading\nbody"
    let view = makeTextView(width: 300, text: source)
    view.attributedText = LiveMarkdownStyler.plan(for: source)
      .attributedSource(activeUTF16Location: nil)
    view.layoutIfNeeded()
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), false)
  }

  func testAccessibilityFontMeasuresWrapsAtItsRenderedSize() {
    let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    let view = makeTextView(width: 240, text: "large words wrap now")
    view.font = font
    view.layoutIfNeeded()
    XCTAssertEqual(NativeImagePasteTextView.Coordinator.needsExpansion(for: view), true)
  }

  private func makeTextView(width: CGFloat, text: String) -> UITextView {
    let view = UITextView(frame: CGRect(x: 0, y: 0, width: width, height: 160))
    view.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = true
    view.font = .preferredFont(forTextStyle: .body)
    view.text = text
    view.layoutIfNeeded()
    return view
  }
}
