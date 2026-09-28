import SwiftUI

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
