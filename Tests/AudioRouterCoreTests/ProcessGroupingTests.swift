import CoreAudio
import XCTest

@testable import AudioRouterCore

/// 只測不需要真實音訊硬體的邏輯。
///
/// 刻意不試著測 tap 或 aggregate：那些必須有實際裝置與 TCC 授權才有意義，
/// 在 CI 上跑只會得到假的綠燈。真正該用測試守住的是分組規則——
/// 它決定了「路由 Chrome 到底抓不抓得到聲音」，而且純粹是資料轉換。
final class ProcessGroupingTests: XCTestCase {

    private func process(
        _ id: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        name: String,
        playing: Bool = false
    ) -> AudioProcess {
        AudioProcess(
            id: id, pid: pid, bundleID: bundleID, name: name,
            isPlaying: playing, isRecording: false
        )
    }

    private func owner(_ bundleID: String, _ name: String, pid: pid_t, isUserApp: Bool = true)
        -> AudioProcesses.OwningApplication
    {
        AudioProcesses.OwningApplication(
            pid: pid, bundleID: bundleID, name: name, isUserApplication: isUserApp
        )
    }

    /// helper 與 XPC 服務必須併回主 App，否則對主行程建 tap 會完全抓不到聲音。
    func testHelpersAreGroupedIntoOwningApplication() {
        let processes = [
            process(1, pid: 100, bundleID: "jp.naver.line.mac", name: "LINE"),
            process(2, pid: 101, bundleID: "LINE.AudioService", name: "LINE.AudioService", playing: true),
            process(3, pid: 102, bundleID: "LINE.MediaService", name: "LINE.MediaService"),
        ]
        let line = owner("jp.naver.line.mac", "LINE", pid: 100)

        let groups = AudioProcesses.makeGroups(from: processes) { _ in line }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "jp.naver.line.mac")
        XCTAssertEqual(groups[0].name, "LINE")
        XCTAssertEqual(groups[0].processes.count, 3)
        // 整組的 process object 都要進同一個 tap。
        XCTAssertEqual(groups[0].processObjectIDs, [1, 2, 3])
    }

    /// 只要組裡有任何一個行程在出聲，整組就算正在播放。
    func testGroupIsPlayingWhenAnyMemberIsPlaying() {
        let processes = [
            process(1, pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome"),
            process(2, pid: 101, bundleID: "com.google.Chrome.helper", name: "Helper", playing: true),
        ]
        let chrome = owner("com.google.Chrome", "Google Chrome", pid: 100)

        let groups = AudioProcesses.makeGroups(from: processes) { _ in chrome }

        XCTAssertTrue(groups[0].isPlaying)
    }

    /// 歸不到任何一般 App 的行程算系統程序，預設不顯示。
    func testProcessWithoutOwnerIsClassifiedAsSystem() {
        let processes = [process(1, pid: 200, bundleID: "com.apple.audiomxd", name: "audiomxd")]

        let groups = AudioProcesses.makeGroups(from: processes) { _ in nil }

        XCTAssertTrue(groups[0].isSystemProcess)
        XCTAssertEqual(groups[0].key, "com.apple.audiomxd")
    }

    /// 住在 .app 裡但沒有 Dock 圖示的（控制中心、Siri…）同樣算系統程序。
    func testNonRegularApplicationIsClassifiedAsSystem() {
        let processes = [process(1, pid: 300, bundleID: "com.apple.controlcenter", name: "控制中心")]
        let controlCenter = owner(
            "com.apple.controlcenter", "控制中心", pid: 300, isUserApp: false
        )

        let groups = AudioProcesses.makeGroups(from: processes) { _ in controlCenter }

        XCTAssertTrue(groups[0].isSystemProcess)
    }

    /// 排序：播放中最前，其次一般 App，系統程序墊底。
    func testSortingPutsPlayingFirstAndSystemLast() {
        let processes = [
            process(1, pid: 100, bundleID: "com.apple.audiomxd", name: "audiomxd"),
            process(2, pid: 101, bundleID: "com.b.app", name: "B App"),
            process(3, pid: 102, bundleID: "com.a.app", name: "A App"),
            process(4, pid: 103, bundleID: "com.z.app", name: "Z App", playing: true),
        ]
        let owners: [pid_t: AudioProcesses.OwningApplication?] = [
            100: nil,
            101: owner("com.b.app", "B App", pid: 101),
            102: owner("com.a.app", "A App", pid: 102),
            103: owner("com.z.app", "Z App", pid: 103),
        ]

        let groups = AudioProcesses.makeGroups(from: processes) { owners[$0] ?? nil }

        XCTAssertEqual(groups.map(\.name), ["Z App", "A App", "B App", "audiomxd"])
    }

    /// 沒有 bundle ID 也沒有歸屬時，用 pid 當鍵，不能讓多個行程互相蓋掉。
    func testProcessesWithoutBundleIDGetDistinctKeys() {
        let processes = [
            process(1, pid: 400, bundleID: nil, name: "foo"),
            process(2, pid: 401, bundleID: nil, name: "bar"),
        ]

        let groups = AudioProcesses.makeGroups(from: processes) { _ in nil }

        XCTAssertEqual(Set(groups.map(\.key)), ["pid:400", "pid:401"])
    }

    /// pid 鍵不能存檔：pid 會被重用，存下來的設定下次可能套到別的行程上。
    func testOnlyBundleKeysArePersistent() {
        let groups = AudioProcesses.makeGroups(from: [
            process(1, pid: 400, bundleID: nil, name: "foo"),
            process(2, pid: 401, bundleID: "com.example.app", name: "App"),
        ]) { _ in nil }
        let persistent = groups.filter { AudioProcesses.isPersistentKey($0.key) }.map(\.key)

        XCTAssertEqual(persistent, ["com.example.app"])
    }
}
