import AppKit
import CoreAudio
import Darwin
import Foundation

/// 一個「有音訊能力」的行程。Core Audio 會替每個開過音訊的行程建立 process object，
/// 這是 per-app 路由的基本單位。
public struct AudioProcess: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
    public let isPlaying: Bool
    public let isRecording: Bool

    init?(objectID: AudioObjectID) {
        guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
        self.id = objectID
        self.pid = pid

        let rawBundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
        self.bundleID = rawBundleID.isEmpty ? nil : rawBundleID

        let running = NSRunningApplication(processIdentifier: pid)
        if let localized = running?.localizedName, !localized.isEmpty {
            self.name = localized
        } else if !rawBundleID.isEmpty {
            self.name = rawBundleID.components(separatedBy: ".").last ?? rawBundleID
        } else {
            self.name = AudioProcess.processName(pid: pid) ?? "PID \(pid)"
        }

        let playing: UInt32 = (try? objectID.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
        let recording: UInt32 = (try? objectID.read(kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0
        self.isPlaying = playing != 0
        self.isRecording = recording != 0
    }

    /// 測試用：直接指定各欄位，不經過 Core Audio。
    init(
        id: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        name: String,
        isPlaying: Bool,
        isRecording: Bool
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
        self.isRecording = isRecording
    }

    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }
}

/// 一個「播放源」：使用者眼中的一個 App，以及它底下所有會發出聲音的行程。
///
/// 瀏覽器、Slack、LINE 這類 App 的音訊其實是由獨立的 helper 行程送出的，
/// 直接對主行程建 tap 完全抓不到聲音。所以這裡把 helper 併回它所屬的 App，
/// 一組共用一條路由。
public struct AudioProcessGroup: Identifiable, Hashable, Sendable {
    /// 路由設定的鍵：優先用 App 的 bundle ID，沒有的話退回 pid。
    public let key: String
    public let name: String
    public let bundleID: String?
    /// 代表性的 pid，用來取圖示。
    public let pid: pid_t
    public let processes: [AudioProcess]
    /// 沒有對應到任何一般 App 的行程（系統守護程序、背景服務）。
    public let isSystemProcess: Bool

    public var id: String { key }
    public var isPlaying: Bool { processes.contains(where: \.isPlaying) }
    public var isRecording: Bool { processes.contains(where: \.isRecording) }
    public var processObjectIDs: [AudioObjectID] { processes.map(\.id).sorted() }

    /// 播放狀態以外的排序：一般 App 在系統程序前，名稱自然排序。
    public static func listOrder(_ lhs: AudioProcessGroup, _ rhs: AudioProcessGroup) -> Bool {
        if lhs.isSystemProcess != rhs.isSystemProcess { return !lhs.isSystemProcess }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    @MainActor
    public var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

public enum AudioProcesses {
    /// 系統上所有已註冊的音訊行程（未分組）。
    public static func all() -> [AudioProcess] {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)) ?? []
        return ids.compactMap(AudioProcess.init(objectID:))
    }

    /// 所有播放源，已依所屬 App 分組。
    ///
    /// 排序：正在出聲的排最前面，其次是一般 App，系統程序墊底。
    public static func groups() -> [AudioProcessGroup] {
        // 同一次呼叫裡共用歸戶查詢結果，避免對每個行程重複走一次路徑解析。
        var ownerCache: [pid_t: OwningApplication?] = [:]
        return makeGroups(from: all()) { pid in
            if let cached = ownerCache[pid] { return cached }
            let owner = owningApplication(of: pid)
            ownerCache[pid] = owner
            return owner
        }
    }

    /// 分組的純邏輯，不碰 Core Audio——歸戶方式由 `resolveOwner` 注入，方便測試。
    static func makeGroups(
        from processes: [AudioProcess],
        resolveOwner: (pid_t) -> OwningApplication?
    ) -> [AudioProcessGroup] {
        var buckets: [String: [AudioProcess]] = [:]
        var owners: [String: OwningApplication?] = [:]

        for process in processes {
            let owner = resolveOwner(process.pid)
            let key = owner?.bundleID ?? process.bundleID ?? "\(pidKeyPrefix)\(process.pid)"
            buckets[key, default: []].append(process)
            if owners[key] == nil { owners[key] = owner }
        }

        let result = buckets.map { key, members -> AudioProcessGroup in
            let owner = owners[key] ?? nil
            let sorted = members.sorted { $0.pid < $1.pid }
            return AudioProcessGroup(
                key: key,
                name: owner?.name ?? sorted[0].name,
                bundleID: owner?.bundleID ?? sorted[0].bundleID,
                pid: (owner?.pid ?? 0) > 0 ? owner!.pid : sorted[0].pid,
                processes: sorted,
                isSystemProcess: !(owner?.isUserApplication ?? false)
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return AudioProcessGroup.listOrder(lhs, rhs)
        }
    }

    /// 沒有 bundle ID 可用時退回以 pid 當鍵。pid 會被重用，這種鍵只在行程活著時有意義。
    static let pidKeyPrefix = "pid:"

    /// 這個鍵指的東西在行程結束後還找得回來嗎？pid 鍵不行：存下來的設定下次可能套到別的行程上。
    static func isPersistentKey(_ key: String) -> Bool {
        !key.hasPrefix(pidKeyPrefix)
    }

    public static func group(key: String) -> AudioProcessGroup? {
        groups().first { $0.key == key }
    }

    /// 名稱或 bundle ID 的模糊比對，給 CLI 用。
    public static func search(_ query: String) -> [AudioProcess] {
        let needle = query.lowercased()
        return all().filter { process in
            process.name.lowercased().contains(needle)
                || (process.bundleID?.lowercased().contains(needle) ?? false)
        }
    }

    /// 分組後的模糊比對：搜到 helper 也會回傳整個 App 的所有行程。
    public static func searchGroups(_ query: String) -> [AudioProcessGroup] {
        let needle = query.lowercased()
        return groups().filter { group in
            group.name.lowercased().contains(needle)
                || (group.bundleID?.lowercased().contains(needle) ?? false)
                || group.processes.contains { $0.name.lowercased().contains(needle) }
        }
    }

    // MARK: - 找出行程所屬的 App

    struct OwningApplication {
        let pid: pid_t
        let bundleID: String
        let name: String
        /// 是不是使用者眼中的一般 App（會出現在 Dock 裡）。
        /// 控制中心、loginwindow、Siri 這些雖然也是 .app，但不該混在使用者的清單裡。
        let isUserApplication: Bool
    }

    /// 找出某個行程屬於哪個 App。
    ///
    /// 主要靠執行檔路徑：helper 與 XPC 服務都住在所屬 App 的 bundle 裡，
    /// 例如 `/Applications/LINE.app/Contents/XPCServices/LINE.AudioService.xpc/…`，
    /// 取路徑上最外層的 `.app` 就是它的歸屬。
    ///
    /// 不用父行程鏈當主要手段，是因為 XPC 服務是由 launchd 啟動的，
    /// 它們的父行程是 launchd 而不是那個 App——而 XPC 服務往往正是真正發聲的那個。
    /// 父行程鏈只當備援，處理不住在 bundle 裡、但由某個 App 直接生出來的行程。
    ///
    /// 系統框架裡的 XPC 服務（例如 Safari 的 `com.apple.WebKit.GPU`，住在
    /// WebKit.framework 裡）路徑上沒有 `.app`、父行程又是 launchd，兩招都失效；
    /// 這時改問核心「誰對這個行程負責」，拿到的就是呼叫它的 App。
    static func owningApplication(of pid: pid_t) -> OwningApplication? {
        if let fromPath = owningApplicationFromExecutablePath(of: pid) {
            return fromPath
        }
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        if responsible > 1, responsible != pid,
           let owner = owningApplicationFromParentChain(of: responsible) {
            return owner
        }
        return owningApplicationFromParentChain(of: pid)
    }

    /// bundle 路徑 → App 資訊。同一個 App 底下常有好幾個行程，查一次就夠。
    private static var bundleCache: [String: OwningApplication?] = [:]

    static func owningApplicationFromExecutablePath(of pid: pid_t) -> OwningApplication? {
        guard let path = executablePath(of: pid) else { return nil }
        let components = path.components(separatedBy: "/")
        // firstIndex 取到的是最外層的 .app：巢狀的 helper app 會歸給外面那個。
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = components[0...index].joined(separator: "/")

        let resolved: OwningApplication?
        if let cached = bundleCache[bundlePath] {
            resolved = cached
        } else {
            resolved = readBundle(at: bundlePath)
            bundleCache[bundlePath] = resolved
        }
        guard var owner = resolved else { return nil }

        // App 本體正在跑的話改用它的 pid，這樣才取得到圖示。
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: owner.bundleID).first {
            owner = OwningApplication(
                pid: running.processIdentifier,
                bundleID: owner.bundleID,
                name: running.localizedName ?? owner.name,
                isUserApplication: running.activationPolicy == .regular
            )
        }
        return owner
    }

    private static func readBundle(at path: String) -> OwningApplication? {
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        // 有在跑就直接看啟動策略；沒在跑時退而求其次看路徑，
        // 住在 /System 底下的一律當系統元件。
        let isUserApplication: Bool
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            isUserApplication = running.activationPolicy == .regular
        } else {
            isUserApplication = !path.hasPrefix("/System/")
        }
        return OwningApplication(
            pid: 0, bundleID: bundleID, name: name, isUserApplication: isUserApplication
        )
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    static func owningApplicationFromParentChain(of pid: pid_t) -> OwningApplication? {
        var current = pid
        // 防呆上限：行程樹不該這麼深，走太久就是資料有問題。
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular,
               let bundleID = app.bundleIdentifier {
                // 這條路徑本來就只認 .regular 的 App，一定是使用者可見的。
                return OwningApplication(
                    pid: current,
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    isUserApplication: true
                )
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func observeChanges(queue: DispatchQueue = .main, handler: @escaping () -> Void) -> Any {
        Observer(queue: queue, handler: handler)
    }

    /// 監看指定行程的音訊活動狀態。
    ///
    /// 行程清單本身的通知（kAudioHardwarePropertyProcessObjectList）只在行程加入或
    /// 離開時觸發，App 按下暫停／播放並不會動到那份清單，所以要逐一監看每個行程。
    ///
    /// 註冊的是 `kAudioProcessPropertyIsRunning` 而不是看似更貼切的
    /// `kAudioProcessPropertyIsRunningOutput`：實測 macOS 26 的 HAL 只會針對
    /// `IsRunning`（glob）與 `Devices`（inpt／outp）送出通知，掛在 `IsRunningOutput`
    /// 上永遠不會被觸發。收到通知後我們仍是重讀 `IsRunningOutput` 取得實際狀態。
    ///
    /// 回傳值釋放時會自動移除所有監聽器。
    public static func observePlaybackState(
        of processObjectIDs: [AudioObjectID],
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) -> PlaybackObserver {
        PlaybackObserver(objectIDs: processObjectIDs, queue: queue, handler: handler)
    }

    /// 回傳型別要讓 RouterManager 讀得到 installedCount，所以不設為 private。
    public final class PlaybackObserver {
        private let queue: DispatchQueue
        private var blocks: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []

        /// 實際掛上的監聽器數量，給診斷用。
        public var installedCount: Int { blocks.count }

        init(objectIDs: [AudioObjectID], queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            for objectID in objectIDs {
                if let block = objectID.addListener(
                    kAudioProcessPropertyIsRunning, queue: queue, handler: handler
                ) {
                    blocks.append((objectID, block))
                }
            }
        }

        deinit {
            for (objectID, block) in blocks {
                objectID.removeListener(
                    kAudioProcessPropertyIsRunning, queue: queue, block: block
                )
            }
        }
    }

    private final class Observer {
        private let queue: DispatchQueue
        private var block: AudioObjectPropertyListenerBlock?

        init(queue: DispatchQueue, handler: @escaping () -> Void) {
            self.queue = queue
            self.block = AudioObjectID.system.addListener(
                kAudioHardwarePropertyProcessObjectList, queue: queue, handler: handler
            )
        }

        deinit {
            if let block {
                AudioObjectID.system.removeListener(
                    kAudioHardwarePropertyProcessObjectList, queue: queue, block: block
                )
            }
        }
    }
}

/// libsystem 有匯出、但沒有公開標頭的 API：回傳對某個行程「負責」的行程（XPC 服務 → 呼叫它的 App）。
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t
