import AppKit
import AudioRouterCore
import SwiftUI

@main
struct SoundRouterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: StatusMenuDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// 用 NSStatusItem + NSMenu 而不是 MenuBarExtra(.window)：
/// 全螢幕時只有系統選單的追蹤機制能讓選單列在滑鼠移開後仍保持顯示（控制中心也是這樣）。
@MainActor
final class StatusMenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = RouterManager()
    private let chooser = DeviceChooser()
    private var statusItem: NSStatusItem!
    private var hosting: SelfSizingHostingView<AnyView>!
    /// 讓面板裡的按鈕在開啟其他 App 前把選單收起來。
    static weak var menu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hosting = SelfSizingHostingView(rootView: AnyView(RouterPanel().environmentObject(manager).environmentObject(chooser)))
        let item = NSMenuItem()
        item.view = hosting
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item)
        Self.menu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.statusIcon()
        statusItem.menu = menu
    }

    /// 實心喇叭 + 分成兩路的分岔線。用 drawing handler 繪製，每種螢幕倍率都會重畫；
    /// template image 讓系統依選單列深淺上色，所以只畫黑色。
    private static func statusIcon() -> NSImage {
        // flipped：原點在左上，座標可直接對照 18x18 的 SVG 設計稿。
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            let speaker = NSBezierPath()
            speaker.move(to: NSPoint(x: 1.6, y: 6.9))
            speaker.line(to: NSPoint(x: 4.2, y: 6.9))
            speaker.line(to: NSPoint(x: 8, y: 3.8))
            speaker.line(to: NSPoint(x: 8, y: 14.2))
            speaker.line(to: NSPoint(x: 4.2, y: 11.1))
            speaker.line(to: NSPoint(x: 1.6, y: 11.1))
            speaker.close()
            speaker.lineWidth = 1.2
            speaker.lineJoinStyle = .round
            speaker.fill()
            speaker.stroke()

            let branches = NSBezierPath()
            branches.move(to: NSPoint(x: 10.4, y: 9))
            branches.line(to: NSPoint(x: 11.4, y: 9))
            branches.curve(to: NSPoint(x: 14.8, y: 5),
                           controlPoint1: NSPoint(x: 13.1, y: 9), controlPoint2: NSPoint(x: 13.1, y: 5))
            branches.move(to: NSPoint(x: 11.4, y: 9))
            branches.curve(to: NSPoint(x: 14.8, y: 13),
                           controlPoint1: NSPoint(x: 13.1, y: 9), controlPoint2: NSPoint(x: 13.1, y: 13))
            branches.lineWidth = 1.9
            branches.lineCapStyle = .round
            branches.lineJoinStyle = .round
            branches.stroke()

            for y in [5.0, 13.0] {
                NSBezierPath(ovalIn: NSRect(x: 15.9 - 1.4, y: y - 1.4, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SoundRouter"
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        chooser.close()
        hosting.fit()
    }
}

/// 選單項目的視圖不會自己跟著內容長高；內容一變就重量一次大小。
final class SelfSizingHostingView<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    func fit() {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        if frame.size != size { setFrameSize(size) }
    }
}
