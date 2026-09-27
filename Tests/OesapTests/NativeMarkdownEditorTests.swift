import SwiftUI
import UIKit
import XCTest

@testable import Oesap

@MainActor
final class NativeMarkdownEditorTests: XCTestCase {
  func testFormattingPreservesNativeUndoAndSelection() async throws {
    let editor = NativeImagePasteTextView(
      text: .constant(""),
      isFocused: .constant(false),
      accessibilityLabel: "Test editor",
      accessibilityIdentifier: "test-editor",
      isExpanded: true,
      canSubmit: false,
      onSubmit: {},
      onPasteImage: { _, _ in },
      onPasteStarted: { 0 },
      onPasteFailed: { _, _ in }
    )
    let coordinator = editor.makeCoordinator()
    let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    textView.delegate = coordinator
    let controller = UIViewController()
    controller.view.addSubview(textView)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer {
      coordinator.cancelMarkdownParse()
      textView.resignFirstResponder()
      window.isHidden = true
    }

    XCTAssertTrue(textView.becomeFirstResponder())
    textView.insertText("**bold**")
    XCTAssertEqual(textView.text, "**bold**")
    let selection = textView.selectedRange
    XCTAssertEqual(selection.location, (textView.text as NSString).length)

    let styled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard textView.attributedText.length > 2,
          let font = textView.attributedText.attribute(
            .font, at: 2,
            effectiveRange: nil) as? UIFont
        else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
      }, object: textView)
    await fulfillment(of: [styled], timeout: 5)
    XCTAssertEqual(textView.selectedRange, selection)

    let undoManager = try XCTUnwrap(textView.undoManager)
    XCTAssertTrue(undoManager.canUndo)
    undoManager.undo()
    XCTAssertEqual(
      textView.text, "", "Undo should remove the typed source, not just its formatting.")
  }
}
