import Foundation

/// 取本地化字串。
///
/// SwiftPM 把資源放在 `Bundle.module`，而 SwiftUI 的 `Text("…")` 預設查 main bundle，
/// 兩者不同——直接寫 `Text("some.key")` 會原封不動顯示 key 本身。所有字串一律
/// 經過這個函式，就不會有人不小心漏掉 bundle。
///
/// 帶參數的字串搭配 `String(format:)` 使用，例如：
/// `String(format: L("row.mute"), app.name)`
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: nil, table: nil)
}
