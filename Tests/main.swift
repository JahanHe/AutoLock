import Foundation
import CoreBluetooth

// 直接驱动真实蓝牙判断器，关闭硬件初始化；这些检查不会连接设备或锁定屏幕。
final class Recorder: BLEDelegate {
    var events: [(Bool, String)] = []
    var readings: [Int?] = []
    var messages: [String] = []
    func monitorEvent(_ message: String) { messages.append(message) }
    var states: [CBManagerState] = []
    func newDevice(device: Device) {}
    func updateDevice(device: Device) {}
    func removeDevice(device: Device) {}
    func updateRSSI(rssi: Int?, active: Bool) { readings.append(rssi) }
    func updatePresence(presence: Bool, reason: String) { events.append((presence, reason)) }
    func bluetoothPowerWarn() {}
    func bluetoothStateChanged(_ state: CBManagerState) { states.append(state) }
}
var checks = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    checks += 1
}
func makeBLE() -> (BLE, Recorder) {
    let ble = BLE(enableBluetooth: false)
    let recorder = Recorder()
    ble.delegate = recorder
    ble.signalTimeout = 60
    ble.proximityTimeout = 5
    ble.startMonitor(uuid: UUID())
    return (ble, recorder)
}
func clean(_ ble: BLE) { ble.signalTimer?.invalidate(); ble.proximityTimer?.invalidate() }

check(!ConnectionStatus.evaluate(selected: false, bluetooth: .poweredOn, rssi: -50, age: 0, timeout: 30).healthy, "未选设备必须红灯")
for state: CBManagerState in [.poweredOff, .unauthorized, .unsupported, .resetting, .unknown] {
    check(!ConnectionStatus.evaluate(selected: true, bluetooth: state, rssi: -50, age: 0, timeout: 30).healthy, "蓝牙不可用必须红灯")
}
for invalid in [127, 0, 1, -128] {
    check(!ConnectionStatus.evaluate(selected: true, bluetooth: .poweredOn, rssi: invalid, age: 0, timeout: 30).healthy, "无效信号必须红灯")
}
check(ConnectionStatus.evaluate(selected: true, bluetooth: .poweredOn, rssi: -90, age: 29, timeout: 30).healthy, "有效的远距离信号仍然表示监测正常")
check(!ConnectionStatus.evaluate(selected: true, bluetooth: .poweredOn, rssi: -50, age: 30, timeout: 30).healthy, "超时边界必须红灯")
check(!ConnectionStatus.evaluate(selected: true, bluetooth: .poweredOn, rssi: nil, age: nil, timeout: 30).healthy, "尚未收到信号必须红灯")

for enabled in [false, true] {
    for wake in [false, true] {
        for only in [false, true] {
            for watch in [false, true] {
                let policy = ReturnPolicy.evaluate(enabled: enabled, wake: wake, wakeOnly: only, watchCompatible: watch)
                check(policy.wake == (enabled && wake), "唤醒必须独立于密码解锁")
                check(policy.typePassword == (enabled && !only && !watch), "手表兼容、仅唤醒或关闭返回动作时不得输入密码")
            }
        }
    }
}

do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-90)
    ble.proximityTimer?.fire()
    check(recorder.events.contains { !$0.0 && $0.1 == "away" }, "持续远离必须锁定")
    ble.updateMonitoredPeripheral(-50)
    check(recorder.events.last?.0 == true, "重新靠近必须恢复在场")
    check(recorder.readings.last! == -50, "靠近事件前必须发布最新有效信号")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-85)
    ble.updateMonitoredPeripheral(-30)
    check(ble.proximityTimer == nil, "信号恢复必须移除锁定计时器")
    check(recorder.events.isEmpty, "短暂波动恢复后必须取消锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50)
    let deadline = ble.signalTimer!.fireDate
    ble.handleBluetoothState(.poweredOff)
    check(ble.signalTimer!.fireDate == deadline, "关闭蓝牙不得延后失联截止时间")
    ble.signalTimer?.fire()
    check(recorder.events.contains { !$0.0 && $0.1 == "lost" }, "关闭蓝牙不得取消原有失联锁定")
    check(recorder.states.last == .poweredOff, "灯色必须知道蓝牙已关闭")
    check(recorder.readings.last! == nil, "超时必须清除旧信号")
    ble.resetSignalTimer()
    ble.signalTimer?.fire()
    check(recorder.events.count == 2, "失联状态手动解锁后重新计时仍必须能再次锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.presence = false
    let before = recorder.readings.count
    for invalid in [127, 0, -128] { ble.updateMonitoredPeripheral(invalid) }
    check(!ble.presence && recorder.events.isEmpty, "无效信号不能触发靠近解锁")
    check(recorder.readings.count == before, "无效信号不能刷新状态或延长失联时间")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-95)
    let oldTimer = ble.proximityTimer!
    ble.startMonitor(uuid: UUID())
    check(!oldTimer.isValid, "更换设备必须取消旧设备计时器")
    check(ble.latestRSSIs.isEmpty, "更换设备必须清除旧设备样本")
    check(recorder.events.isEmpty, "更换设备必须取消旧设备延迟锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.unlockRSSI = ble.UNLOCK_DISABLED
    ble.updateMonitoredPeripheral(-90)
    ble.proximityTimer?.fire()
    check(recorder.events.contains { !$0.0 && $0.1 == "away" }, "关闭靠近动作不得影响离开锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-90)
    ble.proximityTimer?.fire()
    ble.rearmAfterUnlock()
    ble.updateMonitoredPeripheral(-90)
    ble.proximityTimer?.fire()
    check(recorder.events.filter { $0.1 == "away" }.count == 2, "远处仍在广播时手动解锁，重新判断后仍必须锁定")
}

// 使用临时目录验证退出后读取、轮转、导出与清空，不碰用户的实际诊断日志。
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoLock-日志检查-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(directory: directory, sizeLimit: 300)
    try log.append(.init(message: "设备已远离"))
    let reopened = DiagnosticLog(directory: directory, sizeLimit: 300)
    check(try reopened.recentEvents().first?.message == "设备已远离", "重新打开必须能读取历史日志")
    for index in 0..<20 { try log.append(.init(message: "诊断事件 \(index)")) }
    check(FileManager.default.fileExists(atPath: log.previous.path), "达到大小限制必须轮转日志")
    check(try log.recentEvents().first?.message == "诊断事件 19", "轮转后必须保留最新事件")
    let archive = directory.appendingPathComponent("诊断.zip")
    try log.export(to: archive, summary: ["源码提交": "测试提交", "密码是否已保存": false], events: try log.recentEvents())
    check(try Data(contentsOf: archive).prefix(2) == Data([0x50, 0x4b]), "导出必须生成有效压缩包")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-t", archive.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    check(process.terminationStatus == 0, "诊断包必须能完整解压")
    try log.clear()
    check(try log.recentEvents().isEmpty, "清空必须同时清理两个日志文件")
    let blocked = directory.appendingPathComponent("不可作为目录")
    try Data().write(to: blocked)
    do {
        try DiagnosticLog(directory: blocked).append(.init(message: "不能写入"))
        preconditionFailure("日志错误不得静默吞掉")
    } catch { check(true, "日志写入失败会返回给界面显示") }
}
print("行为检查通过：\(checks) 项，涵盖灯色、离开锁定、断蓝牙、失联兜底、信号波动、Apple Watch 密码互斥及持久诊断日志。")
