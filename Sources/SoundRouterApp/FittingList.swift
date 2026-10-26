import AppKit
import SwiftUI

/// 清單容器：塞得下就跟內容一樣高，塞不下才捲動。
///
/// `ScrollView` 沒有固有高度，所以量 `ScrollView` 裡面內容的實際高度，
/// 再把 `ScrollView` 設成「內容高度」和「螢幕放得下的高度」取小的那個。
/// 不用估算列高：估少了會在大螢幕上判定成放得下，結果面板被選單切掉又不能捲。
///
/// 選單打開後，NSMenu 的視窗不會再長高（`itemChanged`、直接改視窗 frame 都試過，沒用），
/// 所以打開期間內容一變高（例如展開裝置清單），就把高度固定在變高前的值，改成在裡面捲動。
struct FittingList<Content: View>: View {
    private let reservedHeight: CGFloat
    private let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var isOpen = false
    @State private var frozenHeight: CGFloat?

    init(reservedHeight: CGFloat = 280, @ViewBuilder content: () -> Content) {
        self.reservedHeight = reservedHeight
        self.content = content()
    }

    /// 用滑鼠所在的螢幕（就是剛點的那條選單列），不用 `NSScreen.main`：
    /// 選單開在外接螢幕時，`main` 可能還是另一個螢幕。
    private var capHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return max(240, (screen?.visibleFrame.height ?? 900) - reservedHeight)
    }

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                if isOpen, frozenHeight == nil, contentHeight > 0, height > contentHeight {
                    frozenHeight = min(contentHeight, capHeight)
                }
                contentHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: frozenHeight ?? min(contentHeight, capHeight))
        .onAppear { isOpen = true }
        .onDisappear {
            isOpen = false
            frozenHeight = nil
        }
    }
}
