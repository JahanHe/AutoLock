import Foundation
import CoreBluetooth

// 直接驱动真实蓝牙判断器，关闭硬件初始化；这些检查不会连接设备或锁定屏幕。
final class Recorder: BLEDelegate {
    var events: [(Bool, String)] = []
    var readings: [Int?] = []
    var messages: [String] = []
    func monitorEvent(_ message: String) { messages.append(message) }
    var states: [CBManagerState] = []
    var lossChanges = 0
    func signalLossChanged() { lossChanges += 1 }
    var wakes = 0
    func reachedWakeRange() { wakes += 1 }
    func newDevice(device: Device) {}
    func updateDevice(device: Device) {}
    func removeDevice(device: Device) {}
    func updateRSSI(rssi: Int?, active: Bool) { readings.append(rssi) }
    func updatePresence(presence: Bool, reason: String) { events.append((presence, reason)) }
    func bluetoothPowerWarn() {}
    func bluetoothStateChanged(_ state: CBManagerState) { states.append(state) }
}
var checks = 0
var failures: [String] = []
func check(_ value: Bool, _ message: String) {
    if !value { failures.append(message) }
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
func clean(_ ble: BLE) { ble.signalTimer?.invalidate(); ble.proximityTimer?.invalidate(); ble.signalLossTimer?.invalidate() }

do {
    let (ble, _) = makeBLE(); defer { clean(ble) }
    let device = Device(uuid: UUID())
    ble.devices[device.uuid] = device
    ble.resetScanTimer(device: device)
    let expiry = device.scanTimer!
    let lockDeadline = ble.signalTimer!.fireDate
    ble.stopScanning()
    check(!expiry.isValid, "扫描结束必须停止清理列表，给用户保留选择设备的时间")
    check(ble.devices[device.uuid] === device, "扫描结束必须保留已发现的设备")
    check(ble.signalTimer!.fireDate == lockDeadline, "停止扫描不得延后已选设备的失联锁定")
}

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
    check(recorder.events.isEmpty && recorder.lossChanges == 1, "断连必须先提醒，不能立即锁定")
    ble.signalLossTimer?.fire()
    check(recorder.events.contains { !$0.0 && $0.1 == "lost" }, "关闭蓝牙不得取消原有失联锁定")
    check(recorder.states.last == .poweredOff, "灯色必须知道蓝牙已关闭")
    check(recorder.readings.last! == nil, "超时必须清除旧信号")
    ble.rearmAfterUnlock()
    ble.signalTimer?.fire()
    ble.signalLossTimer?.fire()
    check(recorder.events.count == 1, "失联时手动解锁后，在设备回来前不能再次锁定")
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

// 手动解锁豁免仅等到下一次所选设备的有效采样；蓝牙重启或无效值不能结束豁免。
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50)
    ble.signalLost()
    let pending = ble.signalLossTimer!
    ble.rearmAfterUnlock()
    check(ble.waitingForDeviceAfterUnlock && !pending.isValid, "手动解锁必须立即撤销待执行的断连锁定")
    ble.signalLost(); ble.configureSignalLossLock(); pending.fire()
    ble.handleBluetoothState(.poweredOff); ble.handleBluetoothState(.poweredOn)
    for rssi in [0, 127, -128] { ble.updateMonitoredPeripheral(rssi) }
    ble.signalTimer?.fire(); ble.signalLossTimer?.fire()
    check(ble.waitingForDeviceAfterUnlock && recorder.events.isEmpty, "无设备期间不再锁定，重启蓝牙或无效采样均不解除暂停")
    ble.updateMonitoredPeripheral(-90)
    check(!ble.waitingForDeviceAfterUnlock && ble.proximityTimer != nil, "恢复有效弱信号即恢复正常远离确认")
    ble.proximityTimer?.fire()
    check(recorder.events.last?.1 == "away", "恢复后持续远离仍然锁定")
    ble.rearmAfterUnlock()
    ble.setPauseAfterManualUnlock(false)
    ble.signalTimer?.fire(); ble.signalLossTimer?.fire()
    check(!ble.waitingForDeviceAfterUnlock && recorder.events.last?.1 == "lost", "关闭豁免开关可恢复原有失联保护")
}
do {
    let (ble, _) = makeBLE(); defer { clean(ble) }
    ble.rearmAfterUnlock()
    check(ble.waitingForDeviceAfterUnlock, "启动尚无信号时的解锁同样应等待设备")
    ble.startMonitor(uuid: UUID())
    check(!ble.waitingForDeviceAfterUnlock, "主动更换监测设备应开启新的监测周期")
    ble.updateMonitoredPeripheral(-50); ble.rearmAfterUnlock()
    check(!ble.waitingForDeviceAfterUnlock, "设备在附近正常解锁不能暂停离开保护")
    ble.lastSampleAt = Date().addingTimeInterval(-61); ble.rearmAfterUnlock()
    check(ble.waitingForDeviceAfterUnlock, "过期的近处信号不能阻止解锁豁免")
}

do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50)
    let before = recorder.wakes
    ble.displayDidSleep()
    for rssi in [0, 127, -128] { ble.updateMonitoredPeripheral(rssi) }
    check(recorder.wakes == before, "熄屏后无效采样不能触发亮屏")
    ble.updateMonitoredPeripheral(-50)
    check(recorder.wakes == before + 1, "熄屏后已经在附近的设备也能用新的近处采样触发亮屏")
    for _ in 0..<5 { ble.updateMonitoredPeripheral(-50) }
    check(recorder.wakes == before + 1, "同一熄屏周期内持续强信号只触发一次补偿亮屏")
    ble.displayDidSleep(); ble.updateMonitoredPeripheral(-50)
    check(recorder.wakes == before + 2, "下一次熄屏可重新等待新信号亮屏")
}

// 未彻底断联的返回也应亮屏，且不能要求先达到更近的密码门槛。
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-95)
    ble.updateMonitoredPeripheral(-75)
    check(recorder.wakes == 1, "远离确认尚未到期时返回亮屏范围，也必须报告亮屏")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-85)
    ble.proximityTimer?.fire()
    let before = recorder.wakes
    for _ in 0..<5 { ble.updateMonitoredPeripheral(-85) }
    check(recorder.wakes == before, "持续弱信号不能在远离锁定后立即反复亮屏")
    ble.updateMonitoredPeripheral(-75)
    check(recorder.wakes == before + 1, "未离开 -90 亮屏范围，但已从远离区间返回时也应亮屏")
    check(!ble.canUnlockAtCurrentSignal, "返回亮屏不能放宽密码解锁门槛")
}

// 使用临时目录验证退出后读取、轮转、导出与清空，不碰用户的实际诊断日志。
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-100)
    ble.proximityTimer?.fire()
    check(!ble.presence && recorder.wakes == 0, "在亮屏范围以外仍应远离锁定")
    ble.updateMonitoredPeripheral(-90)
    check(recorder.wakes == 1, "返回达到 -90 dBm 必须报告亮屏阶段")
    check(!ble.presence && !ble.canUnlockAtCurrentSignal, "亮屏阶段不能提前满足解锁")
    ble.updateMonitoredPeripheral(-75)
    check(recorder.wakes == 1 && !ble.canUnlockAtCurrentSignal, "继续靠近但未到 -60 时不能重复亮屏或解锁")
    ble.updateMonitoredPeripheral(-60)
    check(ble.presence && ble.canUnlockAtCurrentSignal, "更近达到 -60 dBm 才满足密码解锁距离")
    ble.updateMonitoredPeripheral(-70)
    check(ble.presence && !ble.canUnlockAtCurrentSignal, "已经进入过近处，也不能凭旧状态在距离变远后输入密码")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-85)
    ble.proximityTimer?.fire()
    for _ in 0..<5 { ble.updateMonitoredPeripheral(-85) }
    check(!ble.presence && recorder.wakes == 1, "首次进入可亮屏，但持续停在远离区间不能刚锁定就反复亮屏")
    ble.signalLost()
    check(!ble.withinWakeRange && !ble.canUnlockAtCurrentSignal, "失联必须清除亮屏范围和解锁距离")
    ble.updateMonitoredPeripheral(-85)
    check(recorder.wakes == 2 && !ble.canUnlockAtCurrentSignal, "失联后恢复弱信号只能进入亮屏阶段")
    ble.updateMonitoredPeripheral(-100)
    ble.proximityTimer?.fire()
    for invalid in [0, 127, -128] { ble.updateMonitoredPeripheral(invalid) }
    check(!ble.withinWakeRange && recorder.wakes == 2, "无效信号不能触发亮屏阶段")
    ble.updateMonitoredPeripheral(-90)
    check(recorder.wakes == 3, "真正离开亮屏范围再回来可以再次触发")
    ble.unlockRSSI = ble.UNLOCK_DISABLED
    ble.updateMonitoredPeripheral(-50)
    check(!ble.canUnlockAtCurrentSignal, "关闭靠近动作后强信号也不能允许密码解锁")
}


// 断连的通知、宽限、取消和恢复由真实 BLE 状态机处理，不发送系统锁屏请求。
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50)
    ble.signalLost()
    check(recorder.events.isEmpty && ble.signalLossTimer != nil, "突然断连先进入宽限，不立即锁定")
    check(abs(ble.signalLossTimer!.fireDate.timeIntervalSinceNow - 15) < 1, "默认保留 15 秒供用户取消")
    let episode = ble.signalLossID
    ble.signalLost()
    check(recorder.lossChanges == 1 && ble.signalLossID == episode, "同一次失联只提醒一次")
    let pending = ble.signalLossTimer!
    ble.ignoreCurrentSignalLoss()
    pending.fire()
    check(ble.signalLossIgnored && !pending.isValid && recorder.events.isEmpty, "通知内本次不锁定必须取消真实定时器")
    ble.rearmAfterUnlock(); ble.signalLost()
    check(ble.signalLossIgnored && ble.signalLossTimer == nil, "未恢复信号前手动解锁也不能重新启动已取消的本次锁定")
    for rssi in [0, 127, -128] { ble.updateMonitoredPeripheral(rssi) }
    check(ble.signalLossID == episode && ble.signalLossIgnored, "无效信号不能撤销本次豁免或误称恢复")
    ble.updateMonitoredPeripheral(-50)
    check(ble.signalLossID == nil && !ble.signalLossIgnored, "有效信号恢复后取消本次豁免并恢复保护")
    ble.signalLost(); ble.signalLossTimer?.fire()
    check(recorder.events.last?.1 == "lost", "下一次断连恢复默认锁定保护")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.lockOnSignalLoss = false
    ble.updateMonitoredPeripheral(-50); ble.signalLost()
    check(ble.signalLossTimer == nil && recorder.events.isEmpty && recorder.lossChanges == 1, "不因断连锁定时仍显示提醒")
    ble.updateMonitoredPeripheral(-90); ble.proximityTimer?.fire()
    check(recorder.events.last?.1 == "away", "关闭断连锁定不影响恢复弱信号后的远离锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50); ble.signalLost()
    let pending = ble.signalLossTimer!
    ble.updateMonitoredPeripheral(-85)
    check(!pending.isValid && ble.signalLossID == nil, "恢复任意有效信号都取消旧断连倒计时")
    ble.proximityTimer?.fire()
    check(recorder.events.last?.1 == "away", "恢复信号偏弱时重新按远离规则锁定")
    ble.signalLost(); let old = ble.signalLossTimer!
    ble.startMonitor(uuid: UUID())
    old.fire()
    check(!old.isValid && ble.signalLossID == nil, "换设备不能被旧设备的断连倒计时锁定")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-50); ble.signalLost()
    ble.lockOnSignalLoss = false; ble.configureSignalLossLock()
    check(ble.signalLossTimer == nil, "设置关闭断连锁定应立即取消倒计时")
    ble.lockOnSignalLoss = true; ble.signalLossLockDelay = 30; ble.configureSignalLossLock()
    check(abs(ble.signalLossTimer!.fireDate.timeIntervalSinceNow - 30) < 1, "修改宽限按原断连时间计算")
    ble.lockRSSI = ble.LOCK_DISABLED; ble.configureSignalLossLock()
    check(ble.signalLossTimer == nil && recorder.events.isEmpty, "关闭自动锁定应取消断连计时")
}
do {
    let (ble, recorder) = makeBLE(); defer { clean(ble) }
    ble.updateMonitoredPeripheral(-90)
    ble.lastSampleAt = Date().addingTimeInterval(-5)
    ble.proximityTimer?.fire()
    check(recorder.events.isEmpty && ble.presence, "弱信号后突然中断，不可凭旧采样触发远离锁定")
    ble.signalLost()
    check(recorder.events.isEmpty && ble.signalLossTimer != nil, "旧弱信号转失联后先提醒和宽限")
}
func keepAwake(enabled: Bool = true, healthy: Bool = true, present: Bool = true, raw: Int? = -50,
               average: Int? = -50, age: TimeInterval? = 1, manual: Bool = false,
               sleeping: Bool = false, displaySleep: Bool = false) -> Bool {
    ConnectionStatus.shouldKeepDisplayAwake(enabled: enabled, healthy: healthy, present: present,
        raw: raw, average: average, threshold: -80, age: age, manualLock: manual,
        systemSleep: sleeping, displaySleep: displaySleep)
}
check(keepAwake(), "连续收到附近信号允许防止空闲关屏")
for value in [keepAwake(enabled: false), keepAwake(healthy: false), keepAwake(present: false),
              keepAwake(raw: nil), keepAwake(raw: 127), keepAwake(raw: -90), keepAwake(average: -90),
              keepAwake(age: nil), keepAwake(age: -1), keepAwake(age: 6), keepAwake(manual: true),
              keepAwake(sleeping: true), keepAwake(displaySleep: true)] {
    check(!value, "关闭、离开、断连、锁定或主动休眠时必须释放保持亮屏")
}

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
if !failures.isEmpty {
    for message in failures { print("失败：\(message)") }
    exit(1)
}
print("行为检查通过：\(checks) 项，涵盖灯色、离开锁定、断蓝牙、失联兜底、信号波动、Apple Watch 密码互斥及持久诊断日志。")
