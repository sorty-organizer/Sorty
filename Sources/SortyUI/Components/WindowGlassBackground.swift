import SwiftUI

package struct WindowGlassBackground: ViewModifier {

    package init() {}
    package func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .systemLiquidGlassBackground(cornerRadius: 0, interactive: false)
                    .ignoresSafeArea()
            }
    }
}
