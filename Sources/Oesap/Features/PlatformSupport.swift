import SwiftUI
import UIKit

enum InteractionFeedback {
  static func selection() {
    #if !targetEnvironment(macCatalyst)
      UISelectionFeedbackGenerator().selectionChanged()
    #endif
  }

  static func send() {
    #if !targetEnvironment(macCatalyst)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
  }
}

extension View {
  @ViewBuilder
  func appSheetSize(width: CGFloat, height: CGFloat) -> some View {
    #if targetEnvironment(macCatalyst)
      frame(minWidth: width, minHeight: height)
    #else
      self
    #endif
  }

  @ViewBuilder
  func appFullScreenCover<Item: Identifiable, Content: View>(
    item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if targetEnvironment(macCatalyst)
      sheet(item: item) { value in
        content(value).frame(minWidth: 600, minHeight: 450)
      }
    #else
      fullScreenCover(item: item, content: content)
    #endif
  }
}
