import AppKit
import Combine
import CoreAudio
import Foundation

/// 單一 App 的路由設定。以 bundle ID 為鍵持久化，App 重開後自動套用。
public struct RouteSettings: Codable, Hashable, Sendable {
    /// nil 代表「跟隨系統輸出」。
    public var outputDeviceUID: String?
    public var volume: Float
    public var muted: Bool
    public var balance: Float
    /// 給 UI 顯示用的名字（行程沒在跑的時候還是要能列出來）。
    public var displayName: String

    public init(
        outputDeviceUID: String? = nil,
        volume: Float = 1,
        muted: Bool = false,
        balance: Float = 0,
        displayName: String = ""
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.volume = volume
        self.muted = muted
        self.balance = balance
        self.displayName = displayName
    }

    /// 全部都是預設值時就不需要建立 tap，讓音訊走系統原本的路徑。
    public var isPassthrough: Bool {
        outputDeviceUID == nil && volume == 1 && !muted && balance == 0
    }
}

/// 一個播放源在 UI 上的完整狀態。
public struct RoutedApp: Identifiable, Hashable, Sendable {
    public let key: String
    /// 目前正在跑的行程群組。App 沒在跑時不會出現在清單上，設定仍會保留。
    public let group: AudioProcessGroup
    public var settings: RouteSettings
    /// 這條路由目前是否真的有 tap 在跑。
    public let isActive: Bool
    /// 建立失敗時的訊息。
    public let error: String?
    /// 引擎正在背景建立中。
    public let isStarting: Bool
    /// 指定的輸出裝置目前不在線上。設定會留著，裝置回來就自動恢復。
    /// 這一層只回報事實，要顯示什麼文案由 UI 決定。
    public let isOutputDeviceOffline: Bool
    /// 建立失敗時的目標裝置 UID（「自動」時是當下的系統輸出）。UI 用它把該裝置標成無法使用。
    public let failedDeviceUID: String?

    public var id: String { key }
    public var name: String { group.name }
    /// 持續出聲超過寬限時間才算，過濾掉切換裝置時的瞬間誤報。原始狀態在 `group.isPlaying`。
    public let isPlaying: Bool
    public var isSystemProcess: Bool { group.isSystemProcess }
}

/// 統籌所有路由：追蹤行程與裝置變動、建立/銷毀引擎、存讀設定。
@MainActor
public final class RouterManager: ObservableObject {
    /// 所有播放源（含目前沒在出聲的）。系統程序是否納入由 `showsSystemProcesses` 決定。
    @Published public private(set) var apps: [RoutedApp] = []
    @Published public private(set) var outputDevices: [AudioDevice] = []
    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var defaultOutput: AudioDevice?
    @Published public private(set) var defaultInput: AudioDevice?
    /// 系統層級操作（切換系統輸出、調系統音量）失敗的訊息。個別路由的錯誤在 `RoutedApp.error`。
    @Published public var lastError: String?
    /// 系統輸出裝置的硬體音量；裝置沒有音量控制時為 nil。
    @Published public private(set) var systemVolume: Float?
    /// 系統輸出裝置是否靜音。靜音不會改音量值，所以要另外讀。
    @Published public private(set) var systemMuted = false
    /// 音量為 0 或靜音的輸出裝置。指向這些裝置的 App 怎麼調都不會出聲，UI 據此顯示成靜音。
    @Published public private(set) var silentOutputUIDs: Set<String> = []

    /// 是否把系統守護程序（CoreSpeech、audiomxd…）也列出來。
    /// 預設關閉：機器上通常有三十幾個這種行程，全開會把真正的 App 淹掉。
    @Published public var showsSystemProcesses = false {
        didSet {
            guard oldValue != showsSystemProcesses else { return }
            rebuildSnapshot()
            // 監看範圍跟著顯示範圍走，打開系統程序後它們的播放狀態也要會動。
            updatePlaybackObservers()
        }
    }

    private var settings: [String: RouteSettings] = [:]
    private var engines: [String: RouteEngine] = [:]
    private var engineErrors: [String: String] = [:]
    /// 每個引擎目前實際綁定的輸出裝置與行程，用來判斷是否需要重建。
    private var engineTargets: [String: (deviceUID: String, processIDs: [AudioObjectID])] = [:]
    /// 建立失敗過的組合。同樣的組合不再重試——否則每次 refresh 都會再失敗一次，
    /// 錯誤訊息一直洗版，而且完全沒有好轉的可能。裝置或行程一變就會自然重試。
    private var failedTargets: [String: (deviceUID: String, processIDs: [AudioObjectID])] = [:]
    /// 正在背景建立的路由。建立中不重複發動，否則同一條路由會被啟動很多次。
    private var pendingStarts: Set<String> = []
    /// 最近一次掃描到的播放源。每輪 refresh 算一次，避免重複查詢 Core Audio。
    private var currentGroups: [AudioProcessGroup] = []
    /// 每個播放源開始出聲的時間。建立或拆掉 tap 時 App 會被重新接線，HAL 會短暫回報它在輸出
    /// （Spotify 暫停中也會），所以要連續出聲超過 `playingGrace` 才顯示成正在播放。
    private var playingSince: [String: Date] = [:]
    private static let playingGrace: TimeInterval = 2.5

    private var processObserver: Any?
    private var deviceObserver: Any?
    /// 每個輸出裝置的音量／靜音監聽，裝置清單變動時重掛。
    private var volumeObservers: [Any] = []
    private var volumeObserverDeviceIDs: [AudioObjectID] = []
    /// 播放狀態的監聽器，只掛在清單上會顯示的 App。
    private var playbackObserver: AudioProcesses.PlaybackObserver?
    /// 目前監看中的行程，用來判斷是否需要重掛。
    private var watchedPlaybackIDs: [AudioObjectID] = []
    private let storeURL: URL
    /// 延後中的存檔。拖滑桿時每一格都會呼叫 mutate，不能每格都寫一次檔。
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: Any?

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? RouterManager.defaultStoreURL()
        RouteEngine.cleanupOrphanedAggregates()
        loadSettings()
        refresh()

        processObserver = AudioProcesses.observeChanges(queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        deviceObserver = AudioDevices.observeChanges(queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // 結束前把還沒寫出去的設定補寫，最後一次調整才不會遺失。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSettings() }
        }
    }

    // MARK: - 對外操作

    public func setOutputDevice(_ uid: String?, forKey key: String) {
        mutate(key) { $0.outputDeviceUID = uid }
    }

    public func setVolume(_ volume: Float, forKey key: String) {
        let clamped = max(0, min(1, volume))
        // 只調音量時走即時路徑，不必重建整條鏈。
        engines[key]?.volume = clamped
        // 拉到 0 或從 0 拉上來都不在這裡切換靜音，由介面在放開滑桿後處理，
        // 免得拖動途中整列就在群組間跳來跳去。
        mutate(key) { $0.volume = clamped }
    }

    public func setMuted(_ muted: Bool, forKey key: String) {
        // 拉到 0 而靜音的，取消靜音時回到 100%，不然取消了還是沒聲音。
        if !muted, settings[key]?.volume == 0 { setVolume(1, forKey: key) }
        engines[key]?.isMuted = muted
        mutate(key) { $0.muted = muted }
    }

    public func setBalance(_ balance: Float, forKey key: String) {
        let clamped = max(-1, min(1, balance))
        engines[key]?.balance = clamped
        mutate(key) { $0.balance = clamped }
    }

    /// 把某個播放源恢復成完全跟隨系統。
    public func reset(key: String) {
        settings[key]?.outputDeviceUID = nil
        settings[key]?.volume = 1
        settings[key]?.muted = false
        settings[key]?.balance = 0
        saveSettings()
        reconcile()
        rebuildSnapshot()
    }

    public func setSystemDefaultOutput(_ device: AudioDevice) {
        do { try AudioDevices.setDefaultOutput(device) } catch { lastError = "\(error)" }
        refresh()
    }

    public func setSystemVolume(_ volume: Float) {
        guard let device = defaultOutput else { return }
        do {
            try AudioDevices.setVolume(volume, on: device)
            systemVolume = max(0, min(1, volume))
        } catch { lastError = "\(error)" }
    }

    public func setSystemMuted(_ muted: Bool) {
        guard let device = defaultOutput else { return }
        do {
            try AudioDevices.setMuted(muted, on: device)
            systemMuted = muted
        } catch { lastError = "\(error)" }
    }

    public func setSystemDefaultInput(_ device: AudioDevice) {
        do { try AudioDevices.setDefaultInput(device) } catch { lastError = "\(error)" }
        refresh()
    }

    public func settings(forKey key: String) -> RouteSettings {
        settings[key] ?? RouteSettings()
    }

    // MARK: - 內部

    private func mutate(_ key: String, _ body: (inout RouteSettings) -> Void) {
        var current = settings[key] ?? RouteSettings(displayName: displayName(forKey: key))
        if current.displayName.isEmpty { current.displayName = displayName(forKey: key) }
        body(&current)
        settings[key] = current
        scheduleSave()
        reconcile()
        rebuildSnapshot()
    }

    private func displayName(forKey key: String) -> String {
        currentGroups.first { $0.key == key }?.name
            ?? settings[key]?.displayName
            ?? key
    }

    public func refresh() {
        outputDevices = AudioDevices.outputs()
        inputDevices = AudioDevices.inputs()
        defaultOutput = AudioDevices.defaultOutput()
        defaultInput = AudioDevices.defaultInput()
        readSystemVolume()
        updateVolumeObserver()
        currentGroups = AudioProcesses.groups()
        releaseOfflineDevices()
        reconcile()
        rebuildSnapshot()
        updatePlaybackObservers()
        writeDiagnosticSnapshot()
    }

    /// 指定的輸出裝置斷線（藍牙關掉、拔線）就改回「跟隨系統」，不等它回來。
    /// ponytail: 裝置重新列舉時若短暫消失也會被清掉；真的遇到再加寬限時間。
    private func releaseOfflineDevices() {
        let online = Set(outputDevices.map(\.uid))
        var changed = false
        for (key, setting) in settings {
            guard let uid = setting.outputDeviceUID, !online.contains(uid) else { continue }
            settings[key]?.outputDeviceUID = nil
            changed = true
        }
        if changed { saveSettings() }
    }

    private func readSystemVolume() {
        systemVolume = defaultOutput.flatMap(AudioDevices.volume(of:))
        systemMuted = defaultOutput.flatMap(AudioDevices.isMuted) ?? false
        silentOutputUIDs = Set(outputDevices.filter {
            AudioDevices.volume(of: $0) == 0 || AudioDevices.isMuted($0) == true
        }.map(\.uid))
    }

    /// 音量變動只重讀音量，不走整個 refresh——拖音量鍵時通知很密。
    private func updateVolumeObserver() {
        let ids = outputDevices.map(\.id)
        guard ids != volumeObserverDeviceIDs else { return }
        volumeObserverDeviceIDs = ids
        volumeObservers = outputDevices.map {
            AudioDevices.observeVolume(of: $0, queue: .main) { [weak self] in
                Task { @MainActor in self?.readSystemVolume() }
            }
        }
    }

    /// 只對清單上顯示得出來的 App 監看播放狀態。
    ///
    /// 系統背景程序有二十幾個，平常根本不顯示，沒必要為了它們各掛一個監聽器；
    /// 使用者打開齒輪把它們叫出來時才一併納入。
    private func updatePlaybackObservers() {
        let ids = currentGroups
            .filter { showsSystemProcesses || !$0.isSystemProcess }
            .flatMap(\.processObjectIDs)
            .sorted()

        // 監看對象沒變就不動，否則每次 refresh 都拆掉重掛。
        guard ids != watchedPlaybackIDs else { return }
        watchedPlaybackIDs = ids

        // 先釋放舊的：它的 deinit 會把先前的監聽器移除。
        playbackObserver = nil
        playbackObserver = AudioProcesses.observePlaybackState(of: ids, queue: .main) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 每次 refresh 覆寫一份現況到 ~/Library/Logs/SoundRouter-status.txt。
    /// 選單列 App 沒有 stdout 可看，出問題時這是唯一能對照「App 到底看到什麼」的依據。
    private func writeDiagnosticSnapshot() {
        let all = AudioDevices.all()
        var lines: [String] = []
        lines.append("時間：\(Date())")
        lines.append("裝置總數：\(all.count)（輸出 \(outputDevices.count)、輸入 \(inputDevices.count)）")
        lines.append("預設輸出：\(defaultOutput?.name ?? "nil")")
        lines.append("預設輸入：\(defaultInput?.name ?? "nil")")
        lines.append("播放源群組：\(currentGroups.count)")
        lines.append("清單顯示：\(apps.count)（顯示系統程序：\(showsSystemProcesses)）")
        lines.append("播放狀態監聽：\(playbackObserver?.installedCount ?? 0) / \(watchedPlaybackIDs.count) 個行程")
        lines.append("")
        lines.append("— 所有裝置 —")
        for device in all {
            lines.append("  \(device.name)  out\(device.outputChannels) in\(device.inputChannels)  \(device.uid)")
        }
        lines.append("")
        lines.append("— 路由狀態 —")
        if apps.allSatisfy({ $0.settings.isPassthrough }) {
            lines.append("  （沒有任何自訂路由）")
        }
        for app in apps where !app.settings.isPassthrough {
            var parts: [String] = []
            parts.append(app.settings.outputDeviceUID ?? "跟隨系統")
            parts.append("音量 \(Int(app.settings.volume * 100))%")
            if app.settings.muted { parts.append("靜音") }
            parts.append(app.isActive ? "引擎執行中" : "引擎未執行")
            lines.append("  \(app.name)：\(parts.joined(separator: "、"))")
            if let error = app.error { lines.append("      錯誤：\(error)") }
            if app.isStarting { lines.append("      （建立中）") }
            if app.isOutputDeviceOffline { lines.append("      指定的裝置目前不在線上，暫時走系統輸出") }
        }
        lines.append("")
        lines.append("— 播放源 —")
        for group in currentGroups {
            lines.append("  \(group.name)  行程\(group.processes.count)  "
                + "\(group.isPlaying ? "播放中" : "閒置")\(group.isSystemProcess ? "／系統" : "")")
        }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SoundRouter-status.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 讓實際跑著的引擎與目前設定一致。
    private func reconcile() {
        var groupsByKey: [String: AudioProcessGroup] = [:]
        for group in currentGroups {
            groupsByKey[group.key] = group
        }

        // 收掉已經不需要的引擎。
        for key in engines.keys where !shouldRunEngine(key: key, group: groupsByKey[key]) {
            teardownEngine(forKey: key)
        }

        for (key, setting) in settings {
            guard let group = groupsByKey[key], shouldRunEngine(key: key, group: group) else { continue }

            // 使用者指定的裝置可能已經拔掉、關機或斷線。拿一個不存在的 UID 去建
            // aggregate 一定失敗，所以先確認它還在，不在就暫時退回系統輸出。
            // **設定本身留著不動**：使用者選過的裝置就是他要的，裝置接回來時
            // 應該自動恢復，而不是要他重選一次。
            let requestedUID = setting.outputDeviceUID
            let requestedIsAvailable = requestedUID.map { uid in
                outputDevices.contains { $0.uid == uid }
            } ?? true

            // 裝置不在線上時，這條路由等同於「跟隨系統」。若音量、靜音、平衡
            // 也都還是預設值，建 tap 就完全沒有作用，只是多一條會出錯的路徑——
            // 直接讓音訊走原本的路。設定本身留著，裝置接回來就恢復。
            var effective = setting
            if !requestedIsAvailable { effective.outputDeviceUID = nil }
            guard !effective.isPassthrough else {
                teardownEngine(forKey: key)
                continue
            }

            guard let deviceUID = effective.outputDeviceUID ?? defaultOutput?.uid else { continue }

            // 一組裡的所有行程共用一條路由，helper 發出的聲音才抓得到。
            let processIDs = group.processObjectIDs
            let target = engineTargets[key]

            // 這個組合先前失敗過就不要再試，等條件變了再說。
            if let failed = failedTargets[key],
               failed.deviceUID == deviceUID, failed.processIDs == processIDs {
                continue
            }

            if let engine = engines[key], target?.deviceUID == deviceUID, target?.processIDs == processIDs {
                // 已在跑且目標沒變，只要同步即時參數即可。
                engine.volume = setting.volume
                engine.isMuted = setting.muted
                engine.balance = setting.balance
                continue
            }

            // 已經有一個在背景建立中就不要再發動。
            guard !pendingStarts.contains(key) else { continue }

            // 舊引擎先留著，等新的建好再換（engineDidStart）。先拆的話，tap 一拆
            // 原本的輸出路徑就恢復了，建立期間會以原音量出聲——靜音的 App 也一樣。
            // helper 行程加入或離開都會走到這裡，LINE、瀏覽器這類 App 很常發生。
            let engine = RouteEngine(
                label: setting.displayName.isEmpty ? key : setting.displayName,
                processObjectIDs: processIDs,
                outputDeviceUID: deviceUID
            )
            // 新舊兩個 tap 會短暫並存，新的先靜音，否則換手前會同時出兩份聲音。
            // 真正的參數在換手時才套上。
            engine.isMuted = true

            // RouteEngine.start() 會跟 coreaudiod 做同步 IPC，而那個呼叫可能長時間
            // 不返回（裝置正在重新列舉、或 coreaudiod 忙碌時都遇過）。在主執行緒上
            // 直接呼叫會讓整個 UI 凍住、連選單都打不開，所以丟到背景執行緒。
            pendingStarts.insert(key)
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try engine.start()
                    await self?.engineDidStart(
                        key: key, engine: engine, deviceUID: deviceUID, processIDs: processIDs
                    )
                } catch {
                    await self?.engineDidFail(
                        key: key, deviceUID: deviceUID, processIDs: processIDs,
                        message: "\(error)"
                    )
                }
            }
        }
    }

    private func engineDidStart(
        key: String,
        engine: RouteEngine,
        deviceUID: String,
        processIDs: [AudioObjectID]
    ) {
        pendingStarts.remove(key)

        // 換手：先停舊的再套上真正的參數，兩步之間不會讓出主執行緒，所以不會漏音。
        // 建立期間設定若已改成不需要引擎，下面的 reconcile 會把它收掉。
        engines[key]?.stop()
        let setting = settings(forKey: key)
        engine.volume = setting.volume
        engine.isMuted = setting.muted
        engine.balance = setting.balance

        engines[key] = engine
        engineTargets[key] = (deviceUID, processIDs)
        engineErrors[key] = nil
        failedTargets.removeValue(forKey: key)
        // 目標若在這段期間變了，下一輪 reconcile 會自然把它換掉。
        reconcile()
        rebuildSnapshot()
        writeDiagnosticSnapshot()
    }

    private func engineDidFail(
        key: String,
        deviceUID: String,
        processIDs: [AudioObjectID],
        message: String
    ) {
        pendingStarts.remove(key)
        engineErrors[key] = message
        failedTargets[key] = (deviceUID, processIDs)
        rebuildSnapshot()
        writeDiagnosticSnapshot()
    }

    private func shouldRunEngine(key: String, group: AudioProcessGroup?) -> Bool {
        guard let setting = settings[key], !setting.isPassthrough else { return false }
        return group != nil
    }

    private func teardownEngine(forKey key: String) {
        engines[key]?.stop()
        engines.removeValue(forKey: key)
        engineTargets.removeValue(forKey: key)
    }

    private func isOutputDeviceOffline(_ setting: RouteSettings?) -> Bool {
        guard let uid = setting?.outputDeviceUID else { return false }
        return !outputDevices.contains { $0.uid == uid }
    }

    private func failedDeviceUID(forKey key: String) -> String? {
        engineErrors[key] == nil ? nil : failedTargets[key]?.deviceUID
    }

    private func rebuildSnapshot() {
        var result: [RoutedApp] = []
        let now = Date()
        let previous = playingSince
        playingSince = [:]
        for group in currentGroups where group.isPlaying {
            playingSince[group.key] = previous[group.key] ?? now
        }
        // 有新開始出聲的，寬限時間過後再算一次；那時還在出聲才會顯示。
        if playingSince.values.contains(now) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.playingGrace + 0.1))
                self?.rebuildSnapshot()
            }
        }

        for group in currentGroups {
            // 系統守護程序只在使用者主動要求時列出，但已經設定過的一律顯示，
            // 否則使用者會找不到自己設過的東西。
            let setting = settings[group.key]
            let hasSettings = setting.map { !$0.isPassthrough } ?? false
            guard showsSystemProcesses || !group.isSystemProcess || hasSettings else { continue }

            result.append(RoutedApp(
                key: group.key,
                group: group,
                settings: setting ?? RouteSettings(displayName: group.name),
                isActive: engines[group.key]?.isRunning ?? false,
                error: engineErrors[group.key],
                isStarting: pendingStarts.contains(group.key),
                isOutputDeviceOffline: isOutputDeviceOffline(setting),
                failedDeviceUID: failedDeviceUID(forKey: group.key),
                isPlaying: playingSince[group.key].map { now.timeIntervalSince($0) >= Self.playingGrace } ?? false
            ))
        }

        // groups() 用原始播放狀態排序，瞬間誤報會讓 App 跳到最上面；這裡改用過濾後的值重排。
        apps = result.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return AudioProcessGroup.listOrder(lhs.group, rhs.group)
        }
    }

    // MARK: - 持久化

    private static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("routes.json")
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: RouteSettings].self, from: data)
        else { return }
        // 舊版會把 pid 鍵也寫進檔案，讀回來時丟掉。
        settings = decoded.filter { AudioProcesses.isPersistentKey($0.key) }
    }

    /// 停手 0.5 秒後才寫檔。
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSettings() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveSettings() {
        pendingSave?.cancel()
        pendingSave = nil
        // 已回到預設值的項目不必留在檔案裡。
        let persisted = settings.filter { !$0.value.isPassthrough && AudioProcesses.isPersistentKey($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
