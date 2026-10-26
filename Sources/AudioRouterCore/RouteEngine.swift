import AudioToolbox
import CoreAudio
import Foundation

/// IOProc（即時執行緒）會讀到的參數。放在一塊固定配置的記憶體裡，
/// 讓 render callback 不需要取鎖也不需要配置記憶體。
struct RouteParameters {
    var volume: Float32 = 1
    var muted: Int32 = 0
    /// -1 全左、0 置中、+1 全右
    var balance: Float32 = 0
    /// 以下兩個由 IOProc 寫入、UI 讀取：最近一輪 buffer 的峰值。
    var meterLeft: Float32 = 0
    var meterRight: Float32 = 0
    // 以下純粹給診斷用，IOProc 每輪更新。
    var ioProcCalls: Int64 = 0
    var lastInputBuffers: Int32 = 0
    var lastOutputBuffers: Int32 = 0
    var lastInputFrames: Int32 = 0
    var lastOutputFrames: Int32 = 0
    /// 套用音量之前、直接從 tap 讀到的峰值。用來分辨「tap 是靜音」還是「我們算錯了」。
    var rawInputPeak: Float32 = 0
    /// render 提早 return 的原因代碼，0 = 正常跑完。
    var bailReason: Int32 = 0
    /// 是否要在 IOProc 裡多跑一輪掃描來量 tap 原始峰值。診斷用，預設關閉。
    var diagnosticsEnabled: Int32 = 0
}

/// 一條路由：把指定行程的音訊擷取下來，渲染到指定的輸出裝置。
///
/// 運作方式：
///  1. `AudioHardwareCreateProcessTap` 建立一個 process tap，並把該行程原本的輸出靜音；
///  2. 建立一個私有 aggregate 裝置，成員是「目標輸出裝置 + 上面那個 tap」；
///  3. 在 aggregate 上掛 IOProc，把 tap 送進來的 input buffer 加上音量後寫進 output buffer。
///
/// 因為擷取與播放在同一個 aggregate 的同一個 IOProc 裡，兩邊共用時脈，
/// 取樣率不同時由 tap 的 drift compensation 負責補償。
public final class RouteEngine {
    public static let aggregateUIDPrefix = "com.soundrouter.aggregate."

    /// 被 tap 的行程要不要同時保留原本的輸出路徑。
    /// 正式路由用 `.muteOriginal`；診斷時用 `.keepOriginal`，才能在不影響聆聽的情況下量測 tap。
    public enum SourceBehavior {
        case muteOriginal
        case keepOriginal
    }

    public let label: String
    public private(set) var processObjectIDs: [AudioObjectID]
    public private(set) var outputDeviceUID: String
    public var sourceBehavior: SourceBehavior = .muteOriginal

    /// 打開後 IOProc 會額外計算 tap 的原始峰值，代價是每個 buffer 多一輪掃描。
    public var diagnosticsEnabled: Bool {
        get { parameters.pointee.diagnosticsEnabled != 0 }
        set { parameters.pointee.diagnosticsEnabled = newValue ? 1 : 0 }
    }

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let parameters: UnsafeMutablePointer<RouteParameters>
    private let ioQueue: DispatchQueue

    public init(label: String, processObjectIDs: [AudioObjectID], outputDeviceUID: String) {
        self.label = label
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.parameters = UnsafeMutablePointer<RouteParameters>.allocate(capacity: 1)
        self.parameters.initialize(to: RouteParameters())
        self.ioQueue = DispatchQueue(label: "com.soundrouter.io.\(label)", qos: .userInteractive)
    }

    deinit {
        stop()
        parameters.deinitialize(count: 1)
        parameters.deallocate()
    }

    // MARK: - 即時可調參數

    /// 0…1。1.0 為原音量，不提供增益放大——超過 1.0 的樣本只會在下游被削掉。
    public var volume: Float {
        get { Float(parameters.pointee.volume) }
        set { parameters.pointee.volume = Float32(max(0, min(1, newValue))) }
    }

    public var isMuted: Bool {
        get { parameters.pointee.muted != 0 }
        set { parameters.pointee.muted = newValue ? 1 : 0 }
    }

    /// -1…1
    public var balance: Float {
        get { Float(parameters.pointee.balance) }
        set { parameters.pointee.balance = Float32(max(-1, min(1, newValue))) }
    }

    /// 最近一輪 buffer 的左右聲道峰值（截斷前的值，所以可能超過 1）。UI 的電平表與「這條路由真的有聲音嗎」都靠它。
    public var levels: (left: Float, right: Float) {
        (Float(parameters.pointee.meterLeft), Float(parameters.pointee.meterRight))
    }

    public var isRunning: Bool { ioProcID != nil }

    /// 診斷快照，給 `audiorouter route --debug` 用。
    public struct Diagnostics {
        public var ioProcCalls: Int
        public var inputBuffers: Int
        public var outputBuffers: Int
        public var inputFrames: Int
        public var outputFrames: Int
        public var rawInputPeak: Float
        public var bailReason: Int
        public var tapFormat: String
        public var outputFormat: String
        public var inputBufferOffset: Int
    }

    public private(set) var tapFormatSummary = "—"
    public private(set) var outputFormatSummary = "—"
    public private(set) var inputBufferOffset = 0

    public var diagnostics: Diagnostics {
        let p = parameters.pointee
        return Diagnostics(
            ioProcCalls: Int(p.ioProcCalls),
            inputBuffers: Int(p.lastInputBuffers),
            outputBuffers: Int(p.lastOutputBuffers),
            inputFrames: Int(p.lastInputFrames),
            outputFrames: Int(p.lastOutputFrames),
            rawInputPeak: Float(p.rawInputPeak),
            bailReason: Int(p.bailReason),
            tapFormat: tapFormatSummary,
            outputFormat: outputFormatSummary,
            inputBufferOffset: inputBufferOffset
        )
    }

    // MARK: - 生命週期

    public func start() throws {
        guard !isRunning else { return }
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    /// 換輸出裝置。會重建整條鏈，但保留音量/靜音設定。
    public func setOutputDevice(uid: String) throws {
        guard uid != outputDeviceUID else { return }
        let wasRunning = isRunning
        stop()
        outputDeviceUID = uid
        if wasRunning { try start() }
    }

    /// 換這條路由涵蓋的行程。
    public func setProcesses(_ ids: [AudioObjectID]) throws {
        guard ids != processObjectIDs else { return }
        let wasRunning = isRunning
        stop()
        processObjectIDs = ids
        if wasRunning { try start() }
    }

    // MARK: - 建置步驟

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "SoundRouter – \(label)"
        description.uuid = UUID()
        description.isPrivate = true
        // .muted：被 tap 的行程完全不再走原本的輸出路徑，音訊改由我們渲染到指定裝置，
        // 否則會同時從兩個裝置出聲。
        description.muteBehavior = sourceBehavior == .muteOriginal ? .muted : .unmuted

        var id = AudioObjectID.unknown
        try checked("建立 process tap") { AudioHardwareCreateProcessTap(description, &id) }
        guard id.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "建立 process tap")
        }
        tapID = id
    }

    private func createAggregateDevice() throws {
        let tapUID = try tapID.readString(kAudioTapPropertyUID, label: "讀取 tap UID")
        let uid = Self.aggregateUIDPrefix + UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRouter \(label)",
            kAudioAggregateDeviceUIDKey: uid,
            // private：這個裝置只有我們看得到，不會污染使用者的裝置清單。
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var id = AudioObjectID.unknown
        try checked("建立 aggregate 裝置") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        }
        guard id.isValid else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "建立 aggregate 裝置")
        }
        aggregateID = id
    }

    private func startIO() throws {
        let tapFormat: AudioStreamBasicDescription = try tapID.read(
            kAudioTapPropertyFormat, label: "讀取 tap 音訊格式"
        )
        let outputFormat = try aggregateOutputFormat()

        guard tapFormat.isFloat32, outputFormat.isFloat32 else {
            throw CoreAudioError(
                status: kAudioHardwareUnsupportedOperationError,
                operation: "檢查串流格式（只支援 32-bit float；tap: \(tapFormat.debugSummary)、輸出: \(outputFormat.debugSummary)）"
            )
        }

        // 若目標輸出裝置本身也有輸入（雙工介面），它的 input buffer 會排在 tap 前面。
        let inputOffset = AudioDevices.objectID(forUID: outputDeviceUID)
            .map { $0.readBufferListCounts(scope: kAudioObjectPropertyScopeInput).buffers } ?? 0

        tapFormatSummary = tapFormat.debugSummary
        outputFormatSummary = outputFormat.debugSummary
        self.inputBufferOffset = inputOffset

        let parameters = self.parameters
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            RouteEngine.render(
                input: inputData,
                inputFormat: tapFormat,
                inputBufferOffset: inputOffset,
                output: outputData,
                outputFormat: outputFormat,
                parameters: parameters.pointee,
                parametersStorage: parameters
            )
        }

        var procID: AudioDeviceIOProcID?
        try checked("建立 IOProc") {
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block)
        }
        ioProcID = procID
        try checked("啟動聚合裝置") { AudioDeviceStart(aggregateID, procID) }
    }

    private func aggregateOutputFormat() throws -> AudioStreamBasicDescription {
        let streams: [AudioObjectID] = try aggregateID.readArray(
            kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput,
            label: "讀取聚合裝置輸出 stream"
        )
        guard let first = streams.first else {
            throw CoreAudioError(
                status: kAudioHardwareUnsupportedOperationError,
                operation: "取得聚合裝置的輸出 stream"
            )
        }
        return try first.read(kAudioStreamPropertyVirtualFormat, label: "讀取輸出串流格式")
    }

    // MARK: - 即時渲染

    /// 在即時執行緒上跑：不得配置記憶體、不得取鎖、不得呼叫 Objective-C。
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        inputFormat: AudioStreamBasicDescription,
        inputBufferOffset: Int,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputFormat: AudioStreamBasicDescription,
        parameters: RouteParameters,
        parametersStorage: UnsafeMutablePointer<RouteParameters>?
    ) {
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        parametersStorage?.pointee.ioProcCalls += 1
        parametersStorage?.pointee.lastOutputBuffers = Int32(outputList.count)

        // 先清空輸出，沒填滿的部分才不會播出上一輪的殘留。
        for buffer in outputList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        parametersStorage?.pointee.lastInputBuffers = Int32(inputList.count)
        let inputChannels = max(1, Int(inputFormat.mChannelsPerFrame))
        let outputChannels = max(1, Int(outputFormat.mChannelsPerFrame))
        let inputNonInterleaved = inputFormat.isNonInterleaved
        let outputNonInterleaved = outputFormat.isNonInterleaved

        let inputBuffersNeeded = inputNonInterleaved ? inputChannels : 1
        guard inputList.count >= inputBufferOffset + inputBuffersNeeded,
              outputList.count >= (outputNonInterleaved ? outputChannels : 1),
              inputFormat.mBytesPerFrame > 0, outputFormat.mBytesPerFrame > 0
        else {
            parametersStorage?.pointee.bailReason = 2
            return
        }

        let inputFrames = Int(inputList[inputBufferOffset].mDataByteSize) / Int(inputFormat.mBytesPerFrame)
        let outputFrames = Int(outputList[0].mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        let frames = min(inputFrames, outputFrames)
        parametersStorage?.pointee.lastInputFrames = Int32(inputFrames)
        parametersStorage?.pointee.lastOutputFrames = Int32(outputFrames)
        guard frames > 0 else {
            parametersStorage?.pointee.bailReason = 3
            return
        }
        parametersStorage?.pointee.bailReason = 0

        let volume = parameters.volume
        let balance = parameters.balance

        @inline(__always)
        func readSample(channel: Int, frame: Int) -> Float32 {
            if inputNonInterleaved {
                guard let data = inputList[inputBufferOffset + channel].mData else { return 0 }
                return data.assumingMemoryBound(to: Float32.self)[frame]
            } else {
                guard let data = inputList[inputBufferOffset].mData else { return 0 }
                return data.assumingMemoryBound(to: Float32.self)[frame * inputChannels + channel]
            }
        }

        @inline(__always)
        func writeSample(_ value: Float32, channel: Int, frame: Int) {
            if outputNonInterleaved {
                guard let data = outputList[channel].mData else { return }
                data.assumingMemoryBound(to: Float32.self)[frame] = value
            } else {
                guard let data = outputList[0].mData else { return }
                data.assumingMemoryBound(to: Float32.self)[frame * outputChannels + channel] = value
            }
        }

        var peak: (Float32, Float32) = (0, 0)
        if parameters.diagnosticsEnabled != 0 {
            var rawPeak: Float32 = 0
            for channel in 0..<inputChannels {
                for frame in 0..<frames {
                    let magnitude = abs(readSample(channel: channel, frame: frame))
                    if magnitude > rawPeak { rawPeak = magnitude }
                }
            }
            parametersStorage?.pointee.rawInputPeak = rawPeak
        }

        guard parameters.muted == 0, parameters.volume > 0 else {
            parametersStorage?.pointee.meterLeft = 0
            parametersStorage?.pointee.meterRight = 0
            parametersStorage?.pointee.bailReason = 1
            return
        }

        for channel in 0..<outputChannels {
            // 輸出聲道多於輸入時循環對應（例如立體聲來源送到 4 聲道介面）。
            let sourceChannel = channel % inputChannels
            var gain = volume
            // 左右平衡只作用在前兩個聲道。
            if channel == 0, balance > 0 { gain *= (1 - balance) }
            if channel == 1, balance < 0 { gain *= (1 + balance) }

            var channelPeak: Float32 = 0
            for frame in 0..<frames {
                let value = readSample(channel: sourceChannel, frame: frame) * gain
                // 峰值量測用截斷「之前」的值，電平表才能顯示出確實過載了。
                let magnitude = abs(value)
                if magnitude > channelPeak { channelPeak = magnitude }
                // 音量上限是 1.0，但來源本身可能已經超過 ±1.0。這種樣本若原封不動交給下游，
                // 各家驅動的處理方式不一定相同。這裡明確截斷，行為才可預期。
                writeSample(max(-1, min(1, value)), channel: channel, frame: frame)
            }
            if channel == 0 { peak.0 = channelPeak }
            if channel == 1 { peak.1 = channelPeak }
        }

        if outputChannels == 1 { peak.1 = peak.0 }
        parametersStorage?.pointee.meterLeft = peak.0
        parametersStorage?.pointee.meterRight = peak.1
    }

    // MARK: - 清理

    /// 若 App 曾經異常結束，掃掉殘留的 aggregate 裝置。
    public static func cleanupOrphanedAggregates() {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        for id in ids {
            guard let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(aggregateUIDPrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
    }

    var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }

    var debugSummary: String {
        "\(Int(mSampleRate))Hz \(mChannelsPerFrame)ch \(mBitsPerChannel)bit"
            + (isNonInterleaved ? " non-interleaved" : " interleaved")
    }
}
