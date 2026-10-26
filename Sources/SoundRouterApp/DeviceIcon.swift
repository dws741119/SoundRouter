import AudioRouterCore
import IOBluetooth
import SwiftUI

/// 音訊裝置的圖示。
///
/// 依傳輸類型決定，不看名稱——名稱是使用者可以自訂的，而且翻譯後也對不上。
enum DeviceIcon {
    static func symbol(for device: AudioDevice) -> String {
        switch device.transportKind {
        case .builtIn:
            // 內建裝置同時有喇叭與麥克風，用聲音而不是「筆電」來區分方向。
            return device.canOutput ? "laptopcomputer" : "mic"
        case .usb:
            return "hifispeaker"
        case .hdmi, .displayPort:
            return "display"
        case .bluetooth:
            return "dot.radiowaves.right"
        case .airPlay:
            return "airplayaudio"
        case .virtual:
            return "waveform"
        case .aggregate:
            return "rectangle.3.group"
        case .thunderbolt, .pci, .fireWire:
            return "cable.connector"
        case .other:
            return "speaker.wave.2"
        }
    }
}

/// 連接類型的顯示名稱。`AudioDevice.transport` 是給命令列看的固定中文，這裡才跟隨系統語言。
enum DeviceTransport {
    static func name(for device: AudioDevice) -> String {
        switch device.transportKind {
        case .builtIn: return L("transport.builtIn")
        case .usb: return "USB"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .bluetooth: return L("transport.bluetooth")
        case .airPlay: return "AirPlay"
        case .virtual: return L("transport.virtual")
        case .aggregate: return L("transport.aggregate")
        case .thunderbolt: return "Thunderbolt"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .other: return L("transport.other")
        }
    }
}

/// 藍牙裝置的電量。CoreAudio 不提供，改從 IOBluetooth 讀控制中心用的那組屬性
/// （非公開，用 KVC 讀；讀不到就當沒有電量，不會崩潰）。
enum DeviceBattery {
    static func percent(for device: AudioDevice) -> Int? {
        guard device.transportKind == .bluetooth,
              // 藍牙裝置的 UID 是「24-C4-06-ED-B9-4D:output」，冒號前就是位址。
              let address = device.uid.split(separator: ":").first,
              let bt = IOBluetoothDevice(addressString: String(address)) else { return nil }
        func read(_ key: String) -> Int {
            bt.responds(to: NSSelectorFromString(key)) ? (bt.value(forKey: key) as? Int ?? 0) : 0
        }
        // 單體喇叭／耳機用 Single；AirPods 類分左右，取較低的那一耳。
        let single = read("batteryPercentSingle")
        if single > 0 { return single }
        let ears = [read("batteryPercentLeft"), read("batteryPercentRight")].filter { $0 > 0 }
        return ears.min()
    }

    static func symbol(for percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// 電量文字加電池圖示，跟系統聲音選單一樣放在裝置列右側。
struct BatteryBadge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(percent)%").monospacedDigit()
            Image(systemName: DeviceBattery.symbol(for: percent))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
