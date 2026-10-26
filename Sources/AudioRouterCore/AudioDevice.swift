import CoreAudio
import Foundation

/// 一個實體（或虛擬）音訊裝置。
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let transport: String
    /// 傳輸類型的結構化版本。UI 靠它決定圖示——用 `transport` 那個顯示字串去比對
    /// 會在翻譯之後直接壞掉。
    public let transportKind: TransportKind
    /// 由 SoundRouter 自己建立的 aggregate 裝置——不該出現在使用者可選清單裡。
    public let isOurs: Bool

    public var canOutput: Bool { outputChannels > 0 }
    public var canInput: Bool { inputChannels > 0 }

    init?(id: AudioObjectID) {
        guard let uid = try? id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
        self.id = id
        self.uid = uid
        self.name = (try? id.readString(kAudioObjectPropertyName)) ?? uid
        self.manufacturer = (try? id.readString(kAudioObjectPropertyManufacturer)) ?? ""
        self.inputChannels = id.readBufferListChannelCount(scope: kAudioObjectPropertyScopeInput)
        self.outputChannels = id.readBufferListChannelCount(scope: kAudioObjectPropertyScopeOutput)
        let transportCode: UInt32 = (try? id.read(kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
        self.transportKind = TransportKind(code: transportCode)
        self.transport = AudioDevice.transportName(transportCode)
        self.isOurs = uid.hasPrefix(RouteEngine.aggregateUIDPrefix)
    }

    public enum TransportKind: Sendable, Hashable {
        case builtIn
        case usb
        case hdmi
        case displayPort
        case bluetooth
        case airPlay
        case virtual
        case aggregate
        case thunderbolt
        case pci
        case fireWire
        case other

        init(code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypePCI: self = .pci
            case kAudioDeviceTransportTypeFireWire: self = .fireWire
            default: self = .other
            }
        }
    }

    private static func transportName(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return "內建"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "藍牙"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "虛擬"
        case kAudioDeviceTransportTypeAggregate: return "聚合"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        default: return "其他"
        }
    }
}

public enum AudioDevices {
    /// 系統上所有裝置，已濾掉 SoundRouter 自己建立的 aggregate。
    public static func all() -> [AudioDevice] {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        return ids.compactMap(AudioDevice.init(id:)).filter { !$0.isOurs }
    }

    public static func outputs() -> [AudioDevice] {
        all().filter(\.canOutput).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func inputs() -> [AudioDevice] {
        all().filter(\.canInput).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    public static func objectID(forUID uid: String) -> AudioObjectID? {
        all().first { $0.uid == uid }?.id
    }

    // MARK: - 預設裝置

    public static func defaultOutput() -> AudioDevice? {
        guard let id: AudioObjectID = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) else {
            return nil
        }
        return AudioDevice(id: id)
    }

    public static func defaultInput() -> AudioDevice? {
        guard let id: AudioObjectID = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) else {
            return nil
        }
        return AudioDevice(id: id)
    }

    public static func setDefaultOutput(_ device: AudioDevice) throws {
        try setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "設定預設輸出裝置")
    }

    public static func setDefaultInput(_ device: AudioDevice) throws {
        try setDefault(device, selector: kAudioHardwarePropertyDefaultInputDevice, label: "設定預設輸入裝置")
    }

    private static func setDefault(
        _ device: AudioDevice,
        selector: AudioObjectPropertySelector,
        label: String
    ) throws {
        var addr = AudioObjectID.address(selector)
        var value = device.id
        try checked(label) {
            AudioObjectSetPropertyData(
                .system, &addr, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &value
            )
        }
    }

    // MARK: - 硬體音量（裝置本身支援時）

    /// 有些裝置把音量掛在 main element，有些只提供 per-channel。兩種都試。
    private static func volumeElements(of device: AudioDevice) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    public static func volume(of device: AudioDevice) -> Float? {
        for element in volumeElements(of: device) {
            guard device.id.hasProperty(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) else { continue }
            if let value: Float32 = try? device.id.read(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element,
                as: Float32.self
            ) {
                return Float(value)
            }
        }
        return nil
    }

    public static func setVolume(_ value: Float, on device: AudioDevice) throws {
        var volume = Float32(max(0, min(1, value)))
        var didSet = false
        var lastError: OSStatus = noErr

        for element in volumeElements(of: device) {
            guard device.id.isSettable(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput,
                element: element
            ) else { continue }
            var addr = AudioObjectID.address(
                kAudioDevicePropertyVolumeScalar,
                kAudioObjectPropertyScopeOutput,
                element
            )
            let status = AudioObjectSetPropertyData(
                device.id, &addr, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &volume
            )
            if status == noErr {
                didSet = true
                // main element 設得動就不必再逐聲道設定。
                if element == kAudioObjectPropertyElementMain { return }
            } else {
                lastError = status
            }
        }

        guard didSet else {
            throw CoreAudioError(
                status: lastError == noErr ? kAudioHardwareUnknownPropertyError : lastError,
                operation: "設定「\(device.name)」音量（裝置不支援軟體音量控制）"
            )
        }
    }

    public static func isMuted(_ device: AudioDevice) -> Bool? {
        guard let value: UInt32 = try? device.id.read(
            kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            as: UInt32.self
        ) else { return nil }
        return value != 0
    }

    public static func setMuted(_ muted: Bool, on device: AudioDevice) throws {
        var addr = AudioObjectID.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        try checked("設定「\(device.name)」靜音") {
            AudioObjectSetPropertyData(
                device.id, &addr, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            )
        }
    }

    /// 監看裝置清單 / 預設裝置變動。回傳的 token 釋放時自動移除監聽。
    public static func observeChanges(queue: DispatchQueue = .main, handler: @escaping () -> Void) -> Any {
        Observer(queue: queue, handler: handler)
    }

    /// 監看某個輸出裝置的音量與靜音（鍵盤音量鍵、控制中心改的都會通知）。token 釋放時自動移除。
    public static func observeVolume(of device: AudioDevice, queue: DispatchQueue = .main, handler: @escaping () -> Void) -> Any {
        VolumeObserver(device: device.id, queue: queue, handler: handler)
    }

    private final class VolumeObserver {
        private let device: AudioObjectID
        private let queue: DispatchQueue
        private var blocks: [(AudioObjectPropertySelector, AudioObjectPropertyElement, AudioObjectPropertyListenerBlock)] = []

        init(device: AudioObjectID, queue: DispatchQueue, handler: @escaping () -> Void) {
            self.device = device
            self.queue = queue
            // 跟 volumeElements 一樣，音量可能在 main 或個別聲道上；掛不上的直接略過。
            let targets: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
                (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
                (kAudioDevicePropertyVolumeScalar, 1),
                (kAudioDevicePropertyVolumeScalar, 2),
                (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
            ]
            for (selector, element) in targets {
                if let block = device.addListener(
                    selector, scope: kAudioObjectPropertyScopeOutput, element: element,
                    queue: queue, handler: handler
                ) {
                    blocks.append((selector, element, block))
                }
            }
        }

        deinit {
            for (selector, element, block) in blocks {
                device.removeListener(
                    selector, scope: kAudioObjectPropertyScopeOutput, element: element,
                    queue: queue, block: block
                )
            }
        }
    }

    private final class Observer {
        private let queue: DispatchQueue
        private var blocks: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

        init(queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            let selectors: [AudioObjectPropertySelector] = [
                kAudioHardwarePropertyDevices,
                kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultInputDevice,
            ]
            for selector in selectors {
                if let block = AudioObjectID.system.addListener(selector, queue: queue, handler: handler) {
                    blocks.append((selector, block))
                }
            }
        }

        deinit {
            for (selector, block) in blocks {
                AudioObjectID.system.removeListener(selector, queue: queue, block: block)
            }
        }
    }
}
