import SwiftUI

/// 音量滑桿，0…1。
///
/// 不帶 `step`：帶了就會畫出一整排刻度線，20 格密密麻麻沒有資訊量。
/// 外觀只換填色，軌道與滑鈕維持原生，鍵盤操作與焦點環才是系統的。
struct VolumeSlider: View {
    let value: Float
    /// 靜音時滑桿畫在 0、填色改灰；`value` 本身保留，取消靜音回到原本音量。
    /// 靜音中拖動時滑桿照常跟著走；要不要取消靜音由呼叫端決定。
    var dimmed = false
    let label: String
    let onChange: (Float) -> Void
    /// 放開滑鈕時呼叫。
    var onRelease: () -> Void = {}
    @State private var isEditing = false

    var body: some View {
        Slider(
            value: Binding(get: { dimmed && !isEditing ? 0 : value }, set: { onChange($0) }),
            in: 0...1,
            onEditingChanged: {
                isEditing = $0
                if !$0 { onRelease() }
            }
        )
        .controlSize(.small)
        .tint(dimmed ? Color.gray : Color.accentColor)
        .accessibilityLabel(label)
    }
}

/// 系統音量用的粗滑桿，照控制中心的樣子：膠囊軌道、白色填色、圓形滑鈕，喇叭圖示在軌道左端。
/// 點圖示切換靜音；音量 0 或靜音時圖示改成斜線喇叭，靜音時一樣畫在 0，`value` 保留。
struct SystemVolumeSlider: View {
    let value: Float
    var muted = false
    let label: String
    let onChange: (Float) -> Void
    let onToggleMute: () -> Void
    @State private var isEditing = false

    private let height: CGFloat = 22

    private var shown: Float { muted && !isEditing ? 0 : value }

    private var symbol: String {
        switch shown {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - height
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.white)
                    .frame(width: height + travel * CGFloat(shown))
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: height)
                    .offset(x: travel * CGFloat(shown))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.45))
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule())
            // 圖示不做成 Button：音量 0 時滑鈕疊在圖示上，Button 會吃掉按下，滑鈕就拖不動。
            // 改由同一個手勢分辨：從圖示按下、沒移動就放開算點擊（切換靜音），有移動就是拖曳。
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isEditing, g.startLocation.x < height, abs(g.translation.width) < 3 { return }
                        isEditing = true
                        let v = (g.location.x - height / 2) / max(travel, 1)
                        onChange(Float(min(max(v, 0), 1)))
                    }
                    .onEnded { g in
                        if !isEditing, g.startLocation.x < height { onToggleMute() }
                        isEditing = false
                    }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAction(named: L(muted ? "systemVolume.unmute" : "systemVolume.mute"), onToggleMute)
        .accessibilityValue("\(Int((shown * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 0.0625, 1))
            case .decrement: onChange(max(value - 0.0625, 0))
            @unknown default: break
            }
        }
    }
}
