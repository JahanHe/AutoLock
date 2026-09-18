import Foundation

// 保存原亮度后才调暗；同一轮重复锁定不能把低亮度误存为原值。
final class DisplayBrightness {
    struct Snapshot: Codable { let original: Float; var dimmed: Float }
    typealias Screen = (id: UInt32, key: String, name: String)
    private(set) var saved: [String: Snapshot]
    private(set) var dimmed = Set<String>()
    let read: (UInt32) -> (Int32, Float)
    let write: (UInt32, Float) -> Int32
    let persist: ([String: Snapshot]) -> Void
    var isDimmed: Bool { !dimmed.isEmpty }

    init(saved: [String: Snapshot] = [:], read: @escaping (UInt32) -> (Int32, Float),
         write: @escaping (UInt32, Float) -> Int32, persist: @escaping ([String: Snapshot]) -> Void) {
        self.saved = saved.filter { $0.value.original.isFinite && (0...1).contains($0.value.original)
            && $0.value.dimmed.isFinite && (0.01...0.3).contains($0.value.dimmed) && $0.value.original >= $0.value.dimmed }
        self.read = read; self.write = write; self.persist = persist
    }

    func dim(_ screens: [Screen], to level: Float) -> [String] {
        guard level.isFinite, (0.01...0.3).contains(level) else { return ["亮度必须在 1% 至 30% 之间，未改变屏幕。"] }
        return screens.map { screen in
            let (error, current) = read(screen.id)
            guard error == 0, current.isFinite, (0...1).contains(current) else {
                return "\(screen.name)：系统不支持读取亮度（错误 \(error)），保持原状。"
            }
            guard current > level || saved[screen.key] != nil else { return "\(screen.name)：已低于目标亮度，保持原状。" }
            let previous = saved[screen.key]
            let target = min(level, previous?.original ?? current)
            saved[screen.key] = .init(original: previous?.original ?? current, dimmed: target)
            persist(saved)
            let result = write(screen.id, target)
            guard result == 0 else {
                if let previous = previous { saved[screen.key] = previous; persist(saved) }
                return "\(screen.name)：调低亮度失败（错误 \(result)），保留恢复记录。"
            }
            let (verifyError, actual) = read(screen.id)
            guard verifyError == 0, actual.isFinite, abs(actual - target) <= 0.025 else {
                return "\(screen.name)：已请求调暗，但系统未确认目标亮度，保留恢复记录。"
            }
            dimmed.insert(screen.key)
            return "\(screen.name)：亮度已调为 \(Int((target * 100).rounded()))%，原亮度已保存。"
        }
    }

    func restore(_ screens: [Screen]) -> [String] {
        var messages: [String] = []
        for screen in screens {
            guard let snapshot = saved[screen.key] else { continue }
            let (error, current) = read(screen.id)
            guard error == 0, current.isFinite else {
                messages.append("\(screen.name)：暂时无法读取亮度，保留恢复记录（错误 \(error)）。"); continue
            }
            // ponytail: 尊重调暗后用户或系统的新亮度，不强制覆盖；通过读回值识别变化。
            if abs(current - snapshot.dimmed) <= 0.025 {
                let result = write(screen.id, snapshot.original)
                let (verifyError, actual) = read(screen.id)
                guard result == 0, verifyError == 0, actual.isFinite, abs(actual - snapshot.original) <= 0.025 else {
                    messages.append("\(screen.name)：恢复亮度未确认（错误 \(result)/\(verifyError)），保留记录供重试。"); continue
                }
                messages.append("\(screen.name)：已恢复原亮度 \(Int((snapshot.original * 100).rounded()))%。")
            } else { messages.append("\(screen.name)：亮度已被重新调整，保留当前亮度。") }
            saved.removeValue(forKey: screen.key); dimmed.remove(screen.key)
        }
        persist(saved)
        return messages
    }
}
