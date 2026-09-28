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

  func testHardwareReturnCommandsSendOnceAndKeepShiftReturnAsText() throws {
    var sends = 0
    var editor = NativeImagePasteTextView(
      text: .constant(""), isFocused: .constant(false),
      accessibilityLabel: "Test", accessibilityIdentifier: "test", isExpanded: false,
      canSubmit: true, onSubmit: { sends += 1 }, onPasteImage: { _, _ in },
      onPasteStarted: { 0 }, onPasteFailed: { _, _ in })
    let coordinator = editor.makeCoordinator()
    defer { coordinator.cancelMarkdownParse() }
    let textView = ImagePasteTextView()
    textView.delegate = coordinator
    textView.submitMessage = { coordinator.submitFromKeyboard() }
    let send = try XCTUnwrap(
      textView.keyCommands?.first { $0.modifierFlags == .command && $0.input == "\r" })
    let newline = try XCTUnwrap(
      textView.keyCommands?.first { $0.modifierFlags == .shift && $0.input == "\r" })

    _ = textView.perform(send.action, with: send)
    XCTAssertEqual(sends, 1)
    _ = textView.perform(newline.action, with: newline)
    XCTAssertEqual(textView.text, "\n")
    XCTAssertEqual(sends, 1)

    editor = NativeImagePasteTextView(
      text: .constant(""), isFocused: .constant(false),
      accessibilityLabel: "Test", accessibilityIdentifier: "test", isExpanded: false,
      canSubmit: false, onSubmit: { sends += 1 }, onPasteImage: { _, _ in },
      onPasteStarted: { 0 }, onPasteFailed: { _, _ in })
    coordinator.parent = editor
    _ = textView.perform(send.action, with: send)
    XCTAssertEqual(sends, 1, "Disabled submission must remain disabled for hardware shortcuts")

    coordinator.parent = NativeImagePasteTextView(
      text: .constant(""), isFocused: .constant(false),
      accessibilityLabel: "Test", accessibilityIdentifier: "test", isExpanded: true,
      canSubmit: true, onSubmit: { sends += 1 }, onPasteImage: { _, _ in },
      onPasteStarted: { 0 }, onPasteFailed: { _, _ in })
    _ = textView.perform(send.action, with: send)
    XCTAssertEqual(sends, 2, "Command-Return also sends from the expanded composer")
  }

  func testCommandReturnDoesNotSubmitMarkedText() throws {
    var sends = 0
    let textView = ImagePasteTextView()
    textView.submitMessage = { sends += 1 }
    let send = try XCTUnwrap(
      textView.keyCommands?.first { $0.modifierFlags == .command && $0.input == "\r" })
    textView.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0))
    XCTAssertNotNil(textView.markedTextRange)
    XCTAssertFalse(textView.keyCommands?.contains { $0.action == send.action } ?? false)
    _ = textView.perform(send.action, with: send)
    XCTAssertEqual(sends, 0)
    XCTAssertNotNil(textView.markedTextRange)
  }

}
