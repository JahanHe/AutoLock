import Foundation
import CoreBluetooth

struct ConnectionStatus {
    let healthy: Bool
    let title: String
    let detail: String

    static func evaluate(selected: Bool, bluetooth: CBManagerState, rssi: Int?, age: TimeInterval?, timeout: TimeInterval) -> ConnectionStatus {
        guard selected else { return .init(healthy: false, title: "尚未选择设备", detail: "先扫描并选择随身携带的设备，才会开始自动锁定。") }
        guard bluetooth == .poweredOn else {
            let reason: String
            switch bluetooth {
            case .poweredOff: reason = "蓝牙已关闭"
            case .unauthorized: reason = "蓝牙权限未允许"
            case .unsupported: reason = "这台 Mac 不支持低功耗蓝牙"
            case .resetting: reason = "蓝牙正在恢复"
            default: reason = "正在等待蓝牙就绪"
            }
            return .init(healthy: false, title: reason, detail: "无法接收设备信号；请检查连接，断连后是否锁定由设置决定。")
        }
        guard let rssi = rssi, validRSSI(rssi), let age = age, age >= 0, age < timeout else {
            return .init(healthy: false, title: "未收到有效信号", detail: "设备可能已离开或停止广播。异常灯色表示监测异常，不代表屏幕已经锁定。")
        }
        return .init(healthy: true, title: "设备信号正常", detail: "正在接收所选设备的有效信号。被动模式接收到广播也算正常监测。")
    }

    static func validRSSI(_ value: Int) -> Bool { (-127 ... -1).contains(value) }

    static func shouldKeepDisplayAwake(enabled: Bool, healthy: Bool, present: Bool,
                                       raw: Int?, average: Int?, threshold: Int, age: TimeInterval?,
                                       manualLock: Bool, systemSleep: Bool, displaySleep: Bool) -> Bool {
        guard enabled, healthy, present, !manualLock, !systemSleep, !displaySleep,
              let raw = raw, validRSSI(raw), raw >= threshold,
              let average = average, validRSSI(average), average >= threshold,
              let age = age, age >= 0, age < 6 else { return false }
        return true
    }
}

struct ReturnPolicy {
    let wake: Bool
    let typePassword: Bool

    static func evaluate(enabled: Bool, wake: Bool, wakeOnly: Bool, watchCompatible: Bool) -> ReturnPolicy {
        .init(wake: enabled && wake, typePassword: enabled && !wakeOnly && !watchCompatible)
    }
}

struct RuntimeEvent: Identifiable {
    let id = UUID()
    let date: Date
    let message: String

    init(message: String, date: Date = Date()) { self.message = message; self.date = date }
}
