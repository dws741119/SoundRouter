import AppKit
import AudioRouterCore
import SwiftUI

struct RouterPanel: View {
    @EnvironmentObject private var manager: RouterManager
    @EnvironmentObject private var chooser: DeviceChooser
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        VStack(spacing: 0) {
            content
            ErrorBanner(loginError: loginItem.lastError)
            footer
        }
        .frame(width: 420)
        // 面板外用音量鍵調過的話，打開時重讀一次。
        .onAppear { manager.refresh() }
    }

    /// 由現有欄位算出分組，空的群組不顯示。`manager.apps` 本身已經排好序
    /// （播放中在前、一般 App 在系統程序前、名稱自然排序），
    /// 這裡只做 filter，群組內就沿用那個順序。
    private var groups: [(title: String, apps: [RoutedApp])] {
        let silent = { (app: RoutedApp) in app.settings.muted || manager.isOutputSilent(for: app) }
        let live = manager.apps.filter { !silent($0) }
        return [
            (L("group.playing"), live.filter(\.isPlaying)),
            (L("group.other"), live.filter { !$0.isPlaying }),
            (L("group.muted"), manager.apps.filter(silent)),
        ].filter { !$0.apps.isEmpty }
    }

    /// 系統輸出區和 App 清單放在同一個捲動區：展開裝置清單時往下長，太高就捲動，
    /// 不會把面板撐出螢幕。
    private var content: some View {
        let groups = groups
        return FittingList(reservedHeight: 280) {
            VStack(spacing: 0) {
                SystemOutputSection()
                Divider().padding(.horizontal, 16)
                if manager.apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "speaker.slash")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(L("list.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    // 用 VStack 而非 LazyVStack：清單頂多幾十列，不需要延遲載入，
                    // 而且延遲建立的子視圖會讓視窗算不出正確高度。
                    ForEach(groups, id: \.title) { group in
                        GroupHeader(title: group.title, count: group.apps.count)
                        ForEach(group.apps) { app in
                            AppRow(app: app)
                        }
                    }
                    Spacer().frame(height: 4)
                }
            }
        }
    }

    private var footer: some View {
        // 明確指定間距，不吃系統預設值——那個值在不同 macOS 版本可能不一樣。
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { loginItem.state.isOn },
                set: { _ in loginItem.toggle() }
            )) {
                Text(L("loginItem.launchAtLogin"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            // 已註冊但使用者還沒在系統設定裡允許——不是錯誤，但也還沒生效。
            if loginItem.state == .requiresApproval {
                Button(L("loginItem.needsApproval")) { loginItem.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Spacer()

            // 不是選單，是開關：只控制要不要列出系統程序。
            IconButton(
                systemImage: manager.showsSystemProcesses ? "ellipsis.circle.fill" : "ellipsis.circle",
                label: L("systemProcesses.show"),
                isOn: manager.showsSystemProcesses
            ) {
                manager.showsSystemProcesses.toggle()
            }
            .foregroundStyle(manager.showsSystemProcesses ? Color.accentColor : Color.secondary)
            .help(L("systemProcesses.toggleHelp"))

            IconButton(systemImage: "gearshape", label: L("app.soundSettings")) {
                StatusMenuDelegate.menu?.cancelTracking()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }
            .foregroundStyle(.secondary)
            .help(L("app.soundSettings"))

            IconButton(systemImage: "power", label: L("app.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .foregroundStyle(.secondary)
            .help(L("app.quit"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider() }
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - 系統輸出

private struct SystemOutputSection: View {
    @EnvironmentObject private var manager: RouterManager
    @EnvironmentObject private var chooser: DeviceChooser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("systemOutput.title"))
                .padding(.bottom, 8)

            // 不用 SwiftUI Menu：面板放在 NSMenu 裡，Menu 在選單追蹤中開不出來，改成原地展開。
            // 系統輸出一定有指定裝置，所以沒有「跟隨系統輸出」那一項。
            Button {
                chooser.toggle(
                    owner: "system",
                    entries: manager.outputDevices.map { device in
                        PopUpEntry(
                            title: device.name,
                            subtitle: DeviceTransport.name(for: device),
                            isSelected: device.uid == manager.defaultOutput?.uid,
                            battery: DeviceBattery.percent(for: device)
                        ) { manager.setSystemDefaultOutput(device) }
                    })
            } label: { outputButtonLabel }
            .buttonStyle(.plain)
            if chooser.owner == "system" {
                DeviceList(entries: chooser.entries)
            }

            // 有些裝置（HDMI、部分 USB 介面）沒有硬體音量，那就不給滑桿。
            if let volume = manager.systemVolume {
                let muted = manager.systemMuted
                HStack(spacing: 10) {
                    SystemVolumeSlider(
                        value: volume,
                        muted: muted,
                        label: L("systemVolume.label"),
                        onChange: {
                            manager.setSystemVolume($0)
                            if muted { manager.setSystemMuted(false) }
                        },
                        onToggleMute: { manager.setSystemMuted(!muted) }
                    )
                    // 這裡一律顯示，即使是 100%；靜音時改顯示「靜音」。
                    Group {
                        if muted {
                            Text(L("row.muted")).foregroundStyle(.secondary)
                        } else {
                            Text("\(Int((volume * 100).rounded()))%")
                        }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
        }
        // NSMenu 本身上下會再加約 5pt，這裡少留一點。
        .padding(.top, 7)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var outputButtonLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: manager.defaultOutput.map(DeviceIcon.symbol(for:)) ?? "speaker.wave.2")
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.defaultOutput?.name ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let device = manager.defaultOutput {
                    Text("\(DeviceTransport.name(for: device)) · \(L("systemOutput.current"))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let battery = manager.defaultOutput.flatMap(DeviceBattery.percent(for:)) {
                BatteryBadge(percent: battery)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 群組

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.44)
            .foregroundStyle(.secondary)
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            SectionTitle(text: title)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 單一播放源

private struct AppRow: View {
    let app: RoutedApp
    @EnvironmentObject private var manager: RouterManager
    @EnvironmentObject private var chooser: DeviceChooser
    @State private var isHovered = false
    /// 靜音中拖動滑桿：數值與喇叭圖示先跟著音量走，等真的取消靜音再收起。
    @State private var isAdjusting = false

    private var isMuted: Bool { app.settings.muted }
    private var isOutputSilent: Bool { manager.isOutputSilent(for: app) }
    /// 拖到 0 還沒放開（尚未真的靜音）時，數值與喇叭圖示先顯示成靜音。
    private var showsMuted: Bool {
        (isMuted && !isAdjusting) || app.settings.volume == 0 || isOutputSilent
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if chooser.owner == app.key {
                DeviceList(entries: chooser.entries)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            icon
                .opacity(isMuted || isOutputSilent ? 0.45 : 1)

            nameColumn

            VolumeSlider(
                value: app.settings.volume,
                // 放開後等取消靜音的那 0.15 秒也算調整中，滑桿才不會先跳回 0。
                // 輸出裝置沒聲音時也一樣歸 0、變灰。
                dimmed: (isMuted && !isAdjusting) || isOutputSilent,
                label: String(format: L("row.volume"), app.name)
            ) {
                if isMuted { isAdjusting = true }
                manager.setVolume($0, forKey: app.key)
            } onRelease: {
                // 放開時停在 0 就靜音，靜音中拉上來就取消靜音。
                if app.settings.volume == 0, !isMuted { setMutedSoon(true) }
                if app.settings.volume > 0, isMuted {
                    // isAdjusting 留到真的取消靜音（onChange 收起），中間不會閃回「靜音」。
                    setMutedSoon(false)
                } else {
                    isAdjusting = false
                }
            }

            // 輸出裝置沒聲音時調了也沒用，乾脆不給調。
            .disabled(isOutputSilent)

            valueText
                .frame(width: 32, alignment: .trailing)

            RouteMenu(app: app)

            IconButton(
                systemImage: showsMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                label: String(format: L(isMuted ? "row.unmute" : "row.mute"), app.name),
                isOn: isMuted,
                // 聲波格數跟著音量走，0% 或靜音時改成靜音圖示。
                variableValue: showsMuted ? nil : Double(app.settings.volume)
            ) {
                setMutedSoon(!isMuted)
            }
            .disabled(isOutputSilent)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(
            isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
        .onChange(of: isMuted) { isAdjusting = false }
        .contextMenu {
            if !app.settings.isPassthrough {
                Button(L("route.reset")) { manager.reset(key: app.key) }
            }
        }
    }

    /// 稍等一下再切換靜音、換群組，讓人先看到滑桿停在哪。
    private func setMutedSoon(_ muted: Bool) {
        let key = app.key
        let volume = app.settings.volume
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            // 這段時間音量又被改過（例如要靜音卻又拉上來）就作罷。
            if manager.apps.first(where: { $0.key == key })?.settings.volume != volume { return }
            withAnimation(.easeInOut(duration: 0.25)) { manager.setMuted(muted, forKey: key) }
        }
    }

    /// 固定寬度：空間不夠時名稱先省略，徽章與音量條保留。
    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            nameLine
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
            }
        }
        .frame(width: 104, alignment: .leading)
    }

    /// 裝置沒聲音時註明原因；沒跟隨系統輸出時，名稱下方註明實際走哪個喇叭。
    private var subtitle: String? {
        if isOutputSilent { return L("row.outputSilent") }
        return app.settings.outputDeviceUID.map { uid in
            manager.outputDevices.first { $0.uid == uid }?.name ?? uid
        }
    }

    private var nameLine: some View {
        HStack(spacing: 5) {
            Text(app.name)
                .font(.system(size: 13))
                .foregroundStyle(nameStyle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(app.name)
            if app.isPlaying {
                PlayingBars()
                    .fixedSize()
            }
        }
    }

    private var nameStyle: HierarchicalShapeStyle {
        isMuted || isOutputSilent ? .tertiary : .primary
    }

    /// 一律顯示百分比（含 100%），0% 或靜音時改成「靜音」。
    ///
    /// 每個分支都要有視圖：空的分支不會產生視圖，外面的 `.frame(width: 32)`
    /// 跟著消失，HStack 少掉這一欄和一段間距，滑桿就會變長、整列往右擠。
    @ViewBuilder
    private var valueText: some View {
        if showsMuted {
            Text(L("row.muted"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("\(Int((app.settings.volume * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = app.group.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .frame(width: 24, height: 24)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

extension RouterManager {
    /// 實際輸出的裝置音量為 0 或靜音時，這個 App 再怎麼調也沒聲音。
    func isOutputSilent(for app: RoutedApp) -> Bool {
        guard let uid = app.settings.outputDeviceUID ?? defaultOutput?.uid else { return false }
        return silentOutputUIDs.contains(uid)
    }
}

/// 每列的輸出裝置選單。第一項是「跟隨系統輸出」（原本的「自動」），其後是所有輸出裝置。
private struct RouteMenu: View {
    let app: RoutedApp
    @EnvironmentObject private var manager: RouterManager

    private var selectedUID: String? { app.settings.outputDeviceUID }

    private var selectedName: String {
        guard let uid = selectedUID else { return L("route.auto") }
        return manager.outputDevices.first { $0.uid == uid }?.name ?? uid
    }

    @EnvironmentObject private var chooser: DeviceChooser

    var entries: [PopUpEntry] {
        var list = [
            PopUpEntry(
                title: L("route.followSystem"),
                subtitle: manager.defaultOutput?.name ?? "",
                isSelected: selectedUID == nil
            ) { manager.setOutputDevice(nil, forKey: app.key) }
        ]
        for device in manager.outputDevices {
            // 只在「這個 App」失敗過的裝置才停用：同一個裝置對別的 App 不一定會失敗。
            let failed = device.uid == app.failedDeviceUID
            list.append(PopUpEntry(
                title: device.name,
                subtitle: failed ? L("device.unavailable") : DeviceTransport.name(for: device),
                isSelected: device.uid == selectedUID,
                battery: DeviceBattery.percent(for: device),
                isEnabled: !failed
            ) { manager.setOutputDevice(device.uid, forKey: app.key) })
        }
        return list
    }

    var body: some View {
        Button {
            chooser.toggle(owner: app.key, entries: entries)
        } label: {
            RouteGlyph()
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)
                .foregroundStyle(selectedUID == nil ? Color.secondary : Color.accentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selectedUID == nil ? Color.clear : Color.accentColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(String(format: L("route.buttonLabel"), app.name, selectedName))
        // 選定的裝置暫時不在——設定留著，回來就恢復，所以不是錯誤。
        .help(app.isOutputDeviceOffline ? L("device.offline") : selectedName)
    }
}

/// 路由按鈕的「分岔選路」圖形：上路亮、實心終點是選到的輸出；下路與空心圓圈 50% 透明是沒選的。
/// 座標沿用設計稿的 18x18，依實際尺寸等比縮放。亮路跟著 foregroundStyle；
/// 暗路固定用中性的 secondary，作用中變成 accentColor 時才不會跟著變藍。
private struct RouteGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 18, y: size.height / 18)
            func line(_ width: CGFloat) -> StrokeStyle {
                StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }

            var top = Path()
            top.move(to: CGPoint(x: 2.8, y: 9))
            top.addLine(to: CGPoint(x: 5, y: 9))
            top.addCurve(to: CGPoint(x: 10.6, y: 5), control1: CGPoint(x: 7, y: 9), control2: CGPoint(x: 7.4, y: 5))
            top.addLine(to: CGPoint(x: 13, y: 5))

            var bottom = Path()
            bottom.move(to: CGPoint(x: 5, y: 9))
            bottom.addCurve(to: CGPoint(x: 10.6, y: 13), control1: CGPoint(x: 7, y: 9), control2: CGPoint(x: 7.4, y: 13))
            bottom.addLine(to: CGPoint(x: 13, y: 13))

            var dim = ctx
            dim.opacity = 0.5
            dim.stroke(bottom, with: .color(.secondary), style: line(1.3))
            dim.stroke(dot(14.9, 13, 1.5), with: .color(.secondary), lineWidth: 1.2)

            ctx.stroke(top, with: .foreground, style: line(2.0))
            ctx.fill(dot(2.8, 9, 1.7), with: .foreground)
            ctx.fill(dot(14.9, 5, 1.8), with: .foreground)
        }
    }
}

struct PopUpEntry {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var battery: Int? = nil
    var isEnabled = true
    let action: () -> Void
}

/// 面板放在 NSMenu 裡，SwiftUI Menu 和再彈出的 NSMenu 都打不開，所以裝置清單用
/// 一般視圖畫，直接展開在觸發它的按鈕下方。
final class DeviceChooser: ObservableObject {
    @Published private(set) var owner: String?
    @Published private(set) var entries: [PopUpEntry] = []

    /// 同一個按鈕再點一次就收起。
    func toggle(owner: String, entries: [PopUpEntry]) {
        if self.owner == owner { close() } else { self.owner = owner; self.entries = entries }
    }

    func close() {
        owner = nil
        entries = []
    }
}

private struct DeviceList: View {
    let entries: [PopUpEntry]
    @EnvironmentObject private var chooser: DeviceChooser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.indices, id: \.self) { i in
                let entry = entries[i]
                Button {
                    entry.action()
                    chooser.close()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14)
                            .opacity(entry.isSelected ? 1 : 0)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.system(size: 13)).lineLimit(1)
                            Text(entry.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let battery = entry.battery { BatteryBadge(percent: battery) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.isEnabled)
                .opacity(entry.isEnabled ? 1 : 0.45)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 「正在播放」的三根跳動音量條。不接真實電平：只有建了 tap 的 App 拿得到，
/// 混用會讓人以為其他 App 沒聲音。
private struct PlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let delays: [Double] = [0, 0.2, 0.45]
    private static let period = 0.9

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(Self.delays, id: \.self) { delay in
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: reduceMotion ? 8 : height(at: time - delay))
                }
            }
            .frame(height: 12)
        }
        .foregroundStyle(Color.accentColor)
        .accessibilityElement()
        .accessibilityLabel(L("row.playing"))
    }

    /// 4…12pt 之間循環。
    private func height(at time: Double) -> CGFloat {
        8 + 4 * sin(2 * .pi * time / Self.period)
    }
}

// MARK: - 錯誤提示條

/// 只有有錯誤時才出現。主文講人話，原始訊息收在「詳細資訊」裡。
///
/// 失敗的單位是「某個 App → 某個裝置」，所以依目標裝置分組：
/// 一個裝置就說「X 無法使用」，多個就說「N 個裝置無法使用」。
private struct ErrorBanner: View {
    let loginError: String?
    @EnvironmentObject private var manager: RouterManager
    @State private var isExpanded = false

    private var failedApps: [RoutedApp] { manager.apps.filter { $0.error != nil } }

    private var failedDeviceNames: [String] {
        let uids = Set(failedApps.compactMap(\.failedDeviceUID))
        return uids.map { uid in manager.outputDevices.first { $0.uid == uid }?.name ?? uid }.sorted()
    }

    private var details: [String] {
        failedApps.map { "\($0.name)：\($0.error ?? "")" }
            + [manager.lastError, loginError].compactMap { $0 }
    }

    private var title: String {
        switch failedDeviceNames.count {
        case 0: return L("error.generic.title")
        case 1: return String(format: L("error.deviceUnavailable"), failedDeviceNames[0])
        default: return String(format: L("error.devicesUnavailable"), failedDeviceNames.count)
        }
    }

    private var summary: String {
        failedDeviceNames.isEmpty ? L("error.generic.summary") : L("error.route.summary")
    }

    var body: some View {
        if !details.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(L(isExpanded ? "error.hide" : "error.details")) {
                        isExpanded.toggle()
                    }
                    .controlSize(.small)
                }
                if isExpanded {
                    Text(details.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            // 面板關閉後回到預設的收合狀態。
            .onDisappear { isExpanded = false }
        }
    }
}

// MARK: - 共用

/// 28×28 的圖示按鈕。`isOn` 不為 nil 時是切換鈕，VoiceOver 會念出選取狀態。
private struct IconButton: View {
    let systemImage: String
    let label: String
    var isOn: Bool?
    /// 0…1，給支援的符號（例如 speaker.wave.3）依數值點亮聲波格數。
    var variableValue: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage, variableValue: variableValue)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }
}
