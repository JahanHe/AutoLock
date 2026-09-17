import Cocoa
import Quartz
import ServiceManagement
import CoreBluetooth
import SwiftUI
import Combine
import LocalAuthentication
import UserNotifications
import IOKit.pwr_mgt

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let isPreview = ProcessInfo.processInfo.arguments.contains("--preview")
    let isLocalTest = Bundle.main.object(forInfoDictionaryKey: "AutoLockLocalTest") as? Bool == true
    lazy var ble = BLE(enableBluetooth: !isPreview)
    let objectWillChange = ObservableObjectPublisher()
    var settingsWindow: NSWindow?
    var settingsMinimized = false
    var settingsPage: SettingsPage = .overview
    var settingsScrollTarget: SettingsPage = .overview
    var statusTimer: Timer?
    var scanTimer: Timer?
    var unlockTimer: Timer?
    var scanningForDevices = false
    var bluetoothState: CBManagerState = .unknown
    var lastSignalAt: Date?
    var activeConnection = false
    var feedback = "设置会立即生效，无需另外保存。"
    var hasPassword = false
    var accessibilityGranted = false
    var permissionCheckedAt: Date?
    var loginEnabled = false
    var loginNeedsApproval = false
    var previewScenario = 0
    var showEffectPreview = false
    var expandedSettings = Set<SettingsPage>()
    var settingsScrollRequest = UUID()
    var displayAssertion: IOPMAssertionID = 0
    var displayAssertionError: String?
    var notifiedSignalLoss: UUID?
    var notificationPermission = "等待读取通知权限"
    var ignoreLossMenuItem: NSMenuItem?
    var testingUnlock = false
    var events: [RuntimeEvent] = []
    var diagnosticStatus = "运行记录保存在本机，退出后保留。"
    lazy var diagnosticLog = DiagnosticLog(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "jp.sone.BLEUnlock")/诊断", isDirectory: true))
    var screenLocked = false
    var lockRequestAt: Date?
    var pendingLockReason: String?
    var passwordAttemptedForLock = false
    var lastActionError: String?
    let mainMenu = NSMenu()
    var monitorMenuItem : NSMenuItem?
    var deviceMenuItem: NSMenuItem?
    var quickMenuItems: [String: NSMenuItem] = [:]
    let previewSuite = "local.autolock.preview.\(UUID().uuidString)"
    lazy var prefs: UserDefaults = {
        // ponytail: 预览只使用独立临时设置，不读取或覆盖真实偏好与钥匙串。
        if isPreview { return UserDefaults(suiteName: previewSuite)! }
        return .standard
    }()
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    var signalHistory: [(date: Date, rssi: Int?)] = []

    var screenPresentation: (title: String, symbol: String, lit: Bool) {
        if systemSleep { return ("系统睡眠中", "moon.zzz", false) }
        if displaySleep { return ("屏幕已关闭", "power", false) }
        if screenLocked { return ("已锁定 · 等待解锁", "lock.fill", true) }
        if inScreensaver { return ("屏幕保护程序", "sparkles", true) }
        return ("桌面已解锁", "macwindow", true)
    }

    func refreshSystemScreenState() {
        guard !isPreview else { return }
        // 直接读取系统快照，避免启动时或错过通知后仍显示默认的亮屏／未锁定。
        screenLocked = isScreenLocked()
        displaySleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if screenLocked { confirmLockRequest() }
    }

    func recordSignalSample(_ rssi: Int?, at date: Date = Date()) {
        signalHistory.removeAll { date.timeIntervalSince($0.date) > 60 }
        signalHistory.append((date, rssi.flatMap { ConnectionStatus.validRSSI($0) ? $0 : nil }))
        if signalHistory.count > 240 { signalHistory.removeFirst(signalHistory.count - 240) }
    }

    func newDevice(device: Device) { objectWillChange.send() }
    func updateDevice(device: Device) { objectWillChange.send() }
    func removeDevice(device: Device) { objectWillChange.send() }

    func updateRSSI(rssi: Int?, active: Bool) {
        recordSignalSample(rssi)
        lastRSSI = rssi
        connected = rssi != nil
        if rssi != nil { lastSignalAt = Date() }
        activeConnection = active
        refreshStatus()
    }

    func bluetoothStateChanged(_ state: CBManagerState) {
        bluetoothState = state
        recordEvent(state == .poweredOn ? "Mac 蓝牙已开启。" : "Mac 蓝牙不可用：\(status.title)。失联计时继续。")
        if state != .poweredOn {
            connected = false
            activeConnection = false
            lastRSSI = nil
            unlockTimer?.invalidate()
        }
        refreshStatus()
    }

    func monitorEvent(_ message: String) { recordEvent(message) }

    var keepAwakeThreshold: Int {
        max(ble.wakeRSSI, ble.lockRSSI == ble.LOCK_DISABLED ? (prefs.object(forKey: "lastLockRSSI") as? Int ?? -80) : ble.lockRSSI)
    }

    var shouldKeepDisplayAwake: Bool {
        ConnectionStatus.shouldKeepDisplayAwake(enabled: prefs.bool(forKey: "keepDisplayAwake"),
            healthy: status.healthy, present: ble.presence, raw: ble.lastRawRSSI, average: lastRSSI,
            threshold: keepAwakeThreshold, age: lastSignalAt.map { Date().timeIntervalSince($0) },
            manualLock: manualLock || screenLocked, systemSleep: systemSleep, displaySleep: displaySleep)
    }

    func updateDisplayAssertion() {
        guard !isPreview else { return }
        if shouldKeepDisplayAwake, displayAssertion == 0, displayAssertionError == nil {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "AutoLock：随身设备持续在附近" as CFString, &displayAssertion)
            if result == kIOReturnSuccess { recordEvent("附近保持亮屏已生效：防止空闲关屏，仍可主动锁定或休眠。") }
            else { displayAssertion = 0; displayAssertionError = "保持亮屏失败，系统错误：\(result)"; recordEvent(displayAssertionError!) }
        } else if !shouldKeepDisplayAwake {
            releaseDisplayAssertion()
            displayAssertionError = nil
        }
    }

    func releaseDisplayAssertion() {
        guard displayAssertion != 0 else { return }
        let result = IOPMAssertionRelease(displayAssertion)
        if result == kIOReturnSuccess {
            displayAssertion = 0
            recordEvent("已释放保持亮屏，屏幕继续遵循系统空闲设置。")
        } else { displayAssertionError = "释放保持亮屏失败，系统错误：\(result)"; recordEvent(displayAssertionError!) }
    }

    var signalLossSummary: String {
        guard ble.signalLossID != nil else { return "收到有效信号后，断连倒计时会自动取消。" }
        if ble.signalLossIgnored { return "本次断连不锁定；恢复有效信号后重新启用保护。" }
        if !ble.lockOnSignalLoss || ble.lockRSSI == ble.LOCK_DISABLED { return "设备信号中断，当前设置为不因断连锁定。" }
        if let timer = ble.signalLossTimer, timer.isValid {
            return "请手动连接设备：\(max(0, Int(ceil(timer.fireDate.timeIntervalSinceNow)))) 秒后因断连锁定。"
        }
        return screenLocked ? "断连期间屏幕已锁定。" : "断连宽限已结束，请查看锁定结果。"
    }

    func signalLossChanged() {
        defer { refreshStatus() }
        guard !isPreview else { return }
        let center = UNUserNotificationCenter.current()
        if let previous = notifiedSignalLoss, previous != ble.signalLossID || ble.signalLossIgnored {
            let id = "signal-loss-\(previous.uuidString)"
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
        guard let episode = ble.signalLossID, !ble.signalLossIgnored else {
            notifiedSignalLoss = nil
            return
        }
        guard notifiedSignalLoss != episode else { return }
        notifiedSignalLoss = episode
        recordEvent(signalLossSummary)
        guard prefs.bool(forKey: "disconnectNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "AutoLock · 设备信号中断"
        content.body = signalLossSummary + " 可重新连接，或选择“本次不锁定”。"
        content.categoryIdentifier = "signal-loss"
        center.add(.init(identifier: "signal-loss-\(episode.uuidString)", content: content, trigger: nil)) { error in
            if let error = error { DispatchQueue.main.async { self.recordEvent("断连通知发送失败：\(error.localizedDescription)。仍可在菜单栏取消本次锁定。") } }
        }
    }

    @objc func ignoreCurrentSignalLoss() { ble.ignoreCurrentSignalLoss() }

    var signalLossCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: "signal-loss", actions: [
            UNNotificationAction(identifier: "ignore-signal-loss", title: "本次不锁定", options: []),
            UNNotificationAction(identifier: "reconnect-device", title: "重新连接", options: [.foreground])], intentIdentifiers: [])
    }

    @objc func reconnectDevice() {
        guard !isPreview else { feedback = "演示模式：重新连接不操作蓝牙。"; refreshStatus(); return }
        ble.centralMgr?.stopScan()
        ble.scanForPeripherals()
        if bluetoothState == .poweredOn { ble.connectMonitoredPeripheral() }
        feedback = "已请求重新扫描与连接。未恢复前仍按当前断连策略处理，可点“本次不锁定”。"
        recordEvent(feedback)
        refreshStatus()
    }

    func recordEvent(_ message: String) {
        events.insert(RuntimeEvent(message: message), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        if !isPreview {
            do { try diagnosticLog.append(events[0]) }
            catch { diagnosticStatus = "日志写入失败：\(error.localizedDescription)。当前事件仍可在窗口复制或导出。" }
        }
        objectWillChange.send()
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        guard !isPreview, prefs.bool(forKey: "lockNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "AutoLock"
        content.subtitle = t(reason == "lost" ? "notification_lost_signal" : "notification_device_away")
        content.body = t("notification_locked")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "proximity-lock", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if response.notification.request.identifier == "update" {
                NSWorkspace.shared.open(URL(string: "https://github.com/JahanHe/AutoLock/releases")!)
            } else if response.notification.request.identifier == "test-signal-loss" {
                self.recordEvent(response.actionIdentifier == "ignore-signal-loss" ? "测试通知：已在通知中点击本次不锁定，未操作真实断连策略。" : "测试通知按钮已收到，未操作真实设备。")
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["test-signal-loss"])
            } else if response.notification.request.identifier.hasPrefix("signal-loss-") {
                guard response.notification.request.identifier == self.ble.signalLossID.map({ "signal-loss-\($0.uuidString)" }) else { completionHandler(); return }
                if response.actionIdentifier == "ignore-signal-loss" { self.ignoreCurrentSignalLoss() }
                else { self.reconnectDevice(); self.settingsPage = .lock; self.settingsScrollTarget = .lock; self.settingsScrollRequest = UUID(); self.showSettings() }
            } else { self.showSettings() }
            completionHandler()
        }
    }

    func runScript(_ arg: String) {
        guard !isPreview else { return }
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async { self.recordEvent("事件脚本结束，退出代码：\(process.terminationStatus)。") }
        }
        do { try process.run(); recordEvent("已启动用户配置的事件脚本。") }
        catch { recordEvent("事件脚本启动失败：\(error.localizedDescription)") }
    }

    func pauseNowPlaying() {
        guard !isPreview else { return }
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                self.nowPlayingWasPlaying = playing
                if self.nowPlayingWasPlaying {
                    print("暂停媒体播放")
                    self.recordEvent("检测到媒体正在播放，已发送暂停请求。")
                    MRMediaRemoteSendCommand(MRCommandPause, nil)
                }
            }
        )
    }
    
    func playNowPlaying() {
        guard !isPreview, prefs.bool(forKey: "resumeMedia") else { return }
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("恢复媒体播放")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                guard self.prefs.bool(forKey: "resumeMedia"), !self.isScreenLocked() else { return }
                MRMediaRemoteSendCommand(MRCommandPlay, nil)
                self.recordEvent("已请求恢复先前由本应用暂停的媒体。")
                self.nowPlayingWasPlaying = false
            })
        }
    }

    @discardableResult func lockOrSaveScreen() -> Bool {
        guard !isPreview else { return false }
        guard SACLockScreenImmediate() == 0 else {
            feedback = "系统未接受锁屏请求，请先用“立即锁定”检查兼容性。"
            lastActionError = feedback
            recordEvent(feedback)
            print("锁定屏幕失败")
            refreshStatus()
            return false
        }
        lockRequestAt = Date()
        recordEvent("已向系统请求锁定，等待锁定状态确认。")
        // 先锁屏，再处理显示效果；屏保不能替代锁定。
        if prefs.bool(forKey: "sleepDisplay") { turnOffDisplay() }
        else if prefs.bool(forKey: "screensaver") { startScreensaver() }
        return true
    }

    func updatePresence(presence: Bool, reason: String) {
        refreshStatus()
        guard !isPreview else { return }
        if presence {
            guard !manualLock, ble.unlockRSSI != ble.UNLOCK_DISABLED else {
                recordEvent(manualLock ? "检测到靠近，但手动锁定保护中，暂不执行返回动作。" : "检测到靠近，但靠近动作已关闭。")
                return
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["proximity-lock"])
            reachedWakeRange()
            if prefs.bool(forKey: "watchCompatible") {
                recordEvent("Apple Watch 兼容模式：本应用不输入密码，解锁交给 macOS。")
            } else if !returnPolicy.typePassword {
                recordEvent("密码解锁开关已关闭，不输入密码。")
            }
            tryUnlockScreen()
        } else {
            unlockTimer?.invalidate()
            wakeTimer?.invalidate()
            releaseDisplayAssertion()
            if !isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED {
                if lockOrSaveScreen() {
                    pauseNowPlaying()
                    pendingLockReason = reason
                }
            }
            if ble.lockRSSI == ble.LOCK_DISABLED { recordEvent("已判定远离或失联，但自动锁定开关关闭，未执行锁定。") }
            else if isScreenLocked() { recordEvent("屏幕已经锁定，保持锁定状态。") }
            manualLock = false
        }
    }

    func reachedWakeRange() {
        guard !isPreview, returnPolicy.wake, !manualLock, !systemSleep,
              status.healthy, ble.withinWakeRange, displaySleep || screenLocked else { return }
        recordEvent("信号已达到亮屏门槛 \(ble.wakeRSSI) dBm，已请求亮屏；密码解锁仍需达到 \(ble.unlockRSSI) dBm。")
        wakeDisplay()
        wakeTimer?.invalidate()
        var attempts = 0
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self, self.status.healthy, self.ble.withinWakeRange,
                  self.returnPolicy.wake, !self.manualLock, !self.systemSleep,
                  self.displaySleep, attempts < 3 else { timer.invalidate(); return }
            attempts += 1
            wakeDisplay()
        }
    }

    func fakeKeyStrokes(_ string: String) {
        guard !isPreview else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        // 每次键盘事件最多发送 20 个字符，以适配系统限制。
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            buffer.deallocate()
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        
        // 发送回车键。
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func tryUnlockScreen() {
        guard !isPreview, returnPolicy.typePassword else { return }
        guard ble.canUnlockAtCurrentSignal else {
            if status.healthy { recordEvent("尚未达到密码解锁门槛 \(ble.unlockRSSI) dBm，保持锁定，只允许已开启的亮屏动作。") }
            return
        }
        guard AXIsProcessTrusted() else { recordEvent("未允许辅助功能，跳过密码输入；离开锁定不受影响。"); return }
        guard status.healthy else { recordEvent("没有新的有效设备信号，跳过密码输入。"); return }
        guard !manualLock else { return }
        guard !passwordAttemptedForLock else { recordEvent("本次锁定已尝试过密码输入，不重复输入；可手动解锁后检查设置。"); return }
        guard ble.presence else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }

        if inScreensaver {
            // 屏保运行时，先确保登录界面已经显示。
            let src = CGEventSource(stateID: .hidSystemState)
            // 按下并松开 Esc 键。
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { return }

        unlockTimer?.invalidate()
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            // 设置或设备状态可能在等待期间变化，输入密码前再次检查。
            guard self.returnPolicy.typePassword, !self.manualLock, self.ble.presence, self.status.healthy,
                  self.ble.canUnlockAtCurrentSignal,
                  !self.prefs.bool(forKey: "wakeWithoutUnlocking"),
                  !self.systemSleep, !self.displaySleep, AXIsProcessTrusted(),
                  self.isScreenLocked() else { return }
            guard let password = self.fetchPassword() else {
                self.lastActionError = "无法读取登录密码，未执行密码输入。请在设置中检查钥匙串或重新保存。"
                self.recordEvent(self.lastActionError!)
                self.refreshStatus()
                return
            }
            guard self.isScreenLocked(), self.returnPolicy.typePassword,
                  self.status.healthy, self.ble.presence, self.ble.canUnlockAtCurrentSignal, !self.manualLock else { return }
            
            print("正在输入登录密码")
            self.recordEvent("条件满足，正在尝试密码解锁；等待系统解锁事件确认。")
            self.passwordAttemptedForLock = true
            self.unlockedAt = Date().timeIntervalSince1970
            self.fakeKeyStrokes(password)
        })
    }

    @objc func onDisplayWake() {
        print("显示器已唤醒")
        recordEvent("系统确认显示器已唤醒。")
        displaySleep = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen()
        refreshStatus()
    }

    @objc func onDisplaySleep() {
        print("显示器已休眠")
        recordEvent("系统确认显示器已休眠。")
        displaySleep = true
        refreshStatus()
    }

    @objc func onSystemWake() {
        print("系统已唤醒")
        recordEvent("系统已从睡眠恢复，正在恢复设备扫描。")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("执行系统唤醒后的延迟任务")
            self.updateDockVisibility()
            self.systemSleep = false
            self.ble.scanForPeripherals()
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("系统已休眠")
        recordEvent("系统进入睡眠；深度睡眠期间无法保证蓝牙监测。")
        systemSleep = true
        releaseDisplayAssertion()
        lastRSSI = nil
        lastSignalAt = nil
        ble.latestRSSIs.removeAll()
        unlockTimer?.invalidate()
        wakeTimer?.invalidate()
        updateDockVisibility()
    }

    @objc func onLock() {
        screenLocked = true
        confirmLockRequest()
        refreshStatus()
    }

    func confirmLockRequest() {
        guard lockRequestAt != nil else { return }
        recordEvent("系统已确认屏幕锁定。")
        lastActionError = nil
        lockRequestAt = nil
        if let reason = pendingLockReason {
            pendingLockReason = nil
            notifyUser(reason)
            runScript(reason)
        }
    }

    @objc func onUnlock() {
        passwordAttemptedForLock = false
        screenLocked = false
        lockRequestAt = nil
        pendingLockReason = nil
        recordEvent("系统已确认屏幕解锁。Apple Watch、Touch ID 或手动解锁的具体来源由系统决定。")
        lastActionError = nil
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("收到屏幕解锁事件")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        if Date().timeIntervalSince1970 < unlockedAt + 10 { runScript("unlocked") }
        playNowPlaying()
        if !ble.presence { ble.rearmAfterUnlock() }
        manualLock = false
        testingUnlock = false
        refreshStatus()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func onScreensaverStart() {
        print("屏幕保护程序已启动")
        inScreensaver = true
        refreshStatus()
    }

    @objc func onScreensaverStop() {
        print("屏幕保护程序已停止")
        inScreensaver = false
        refreshStatus()
    }

    func selectDevice(_ uuid: UUID) {
        recordEvent("已选择随身设备：\(ble.devices[uuid]?.description ?? uuid.uuidString)。")
        prefs.set(uuid.uuidString, forKey: "device")
        prefs.set(ble.devices[uuid]?.description ?? "所选设备", forKey: "deviceName")
        connected = false
        lastRSSI = nil
        lastSignalAt = nil
        signalHistory.removeAll()
        if isPreview { ble.monitoredUUID = uuid }
        else { ble.startMonitor(uuid: uuid) }
        signalLossChanged()
        refreshStatus()
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "AutoLock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        guard !isPreview else { return }
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "jp.sone.BLEUnlock",
            String(kSecAttrLabel): "AutoLock",
            String(kSecValueData): pw,
        ]
        // 先更新已有条目，避免保存失败时删掉原来的密码。
        var lookup = query
        lookup.removeValue(forKey: String(kSecValueData))
        lookup.removeValue(forKey: String(kSecAttrLabel))
        var status = SecItemUpdate(lookup as CFDictionary, [String(kSecValueData): pw, String(kSecAttrLabel): "AutoLock"] as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query as CFDictionary, nil) }
        guard status == errSecSuccess else {
            errorModal(t("password_store_failed"), info: String(format: t("keychain_error"), status))
            return
        }
        hasPassword = true
        passwordAttemptedForLock = false
        lastActionError = nil
        recordEvent("登录密码已保存到系统钥匙串；记录不包含密码内容。")
        refreshStatus()
    }

    func fetchPassword(warn: Bool = false) -> String? {
        guard !isPreview else { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            String(kSecUseAuthenticationContext): context,
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "jp.sone.BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("尚未保存登录密码")
            if warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            if warn { errorModal(t("password_read_failed"), info: String(format: t("keychain_error"), status)) }
            return nil
        }
        guard let data = item as? Data else {
            if warn { errorModal(t("password_decode_failed")) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    @objc func askPassword() {
        guard !isPreview else { feedback = "演示预览不会读取或保存真实密码。"; refreshStatus(); return }
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "AutoLock"

        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            guard !pw.isEmpty else { feedback = "密码不能为空。"; refreshStatus(); return }
            storePassword(pw)
        }
    }
    
    @objc func lockNow() {
        guard !isPreview else { previewScenario = 1; feedback = "演示：已预览锁屏，没有锁定你的 Mac。"; refreshStatus(); return }
        guard !isScreenLocked() else { return }
        manualLock = true
        recordEvent("用户点击立即锁定，设备未离开前抑制自动返回动作。")
        unlockTimer?.invalidate()
        if lockOrSaveScreen() { pauseNowPlaying() }
    }

    @objc func showAboutBox() { AboutBox.showAboutBox() }

    func constructMenu() {
        // ponytail: 复用 AppKit 标准命令，让普通窗口支持最小化和文本复制粘贴。
        let applicationMenu = NSMenu()
        let appMenu = NSMenu(title: "AutoLock")
        appMenu.addItem(withTitle: "隐藏 AutoLock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 AutoLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; applicationMenu.addItem(appItem)
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; applicationMenu.addItem(editItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(minimizeSettings), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; applicationMenu.addItem(windowItem)
        NSApp.mainMenu = applicationMenu
        NSApp.windowsMenu = windowMenu
        mainMenu.removeAllItems()
        mainMenu.autoenablesItems = false
        mainMenu.delegate = self
        quickMenuItems.removeAll()
        monitorMenuItem = mainMenu.addItem(withTitle: "等待设备信号", action: nil, keyEquivalent: "")
        monitorMenuItem?.isEnabled = false
        deviceMenuItem = mainMenu.addItem(withTitle: "尚未选择设备", action: nil, keyEquivalent: "")
        deviceMenuItem?.isEnabled = false
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: "打开 AutoLock…", action: #selector(showSettings), keyEquivalent: ",")
        for (key, title) in [("automaticLock", "离开自动锁定"), ("lockOnSignalLoss", "断连后自动锁定"),
                             ("returnEnabled", "靠近动作"), ("wakeOnProximity", "靠近亮屏"),
                             ("keepDisplayAwake", "附近保持亮屏"), ("watchCompatible", "Apple Watch 兼容模式")] {
            addQuickMenuItem(key, title: title, to: mainMenu)
        }
        let more = NSMenu(title: "更多设置"); more.autoenablesItems = false
        for (key, title) in [("passiveMode", "被动模式"), ("disconnectNotifications", "断连通知"),
                             ("sleepDisplay", "锁定后关闭屏幕"), ("pauseItunes", "离开暂停播放"), ("resumeMedia", "解锁恢复播放"),
                             ("showDockIcon", "显示 Dock 图标"), ("hideDockWhenClosed", "关窗隐藏 Dock 图标"),
                             ("showStatusRSSI", "菜单栏显示信号"), ("loginEnabled", "登录时启动")] {
            addQuickMenuItem(key, title: title, to: more)
        }
        let moreItem = mainMenu.addItem(withTitle: "更多设置", action: nil, keyEquivalent: ""); moreItem.submenu = more
        mainMenu.addItem(NSMenuItem.separator())
        for (title, page) in [("设备与扫描…", SettingsPage.device), ("运行记录…", .activity), ("效果测试…", .tests), ("权限与窗口…", .extras)] {
            let item = mainMenu.addItem(withTitle: title, action: #selector(openMenuSection(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = page.rawValue
        }
        mainMenu.addItem(withTitle: "重新连接随身设备", action: #selector(reconnectDevice), keyEquivalent: "")
        ignoreLossMenuItem = mainMenu.addItem(withTitle: "本次断连不锁定", action: #selector(ignoreCurrentSignalLoss), keyEquivalent: "")
        mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = mainMenu
    }

    func addQuickMenuItem(_ key: String, title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: #selector(toggleQuickSetting(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = key
        quickMenuItems[key] = item
    }

    func refreshQuickMenu() {
        deviceMenuItem?.title = "\(prefs.string(forKey: "deviceName") ?? "尚未选择设备") · \(status.healthy ? lastRSSI.map { "\($0) dBm" } ?? "无信号" : "无有效信号")"
        for (key, item) in quickMenuItems {
            let enabled: Bool
            switch key {
            case "automaticLock": enabled = ble.lockRSSI != ble.LOCK_DISABLED
            case "returnEnabled": enabled = ble.unlockRSSI != ble.UNLOCK_DISABLED
            case "loginEnabled": enabled = loginEnabled
            default: enabled = prefs.bool(forKey: key)
            }
            item.state = enabled ? .on : .off
            item.isEnabled = key == "wakeOnProximity" ? ble.unlockRSSI != ble.UNLOCK_DISABLED :
                (key == "hideDockWhenClosed" ? prefs.bool(forKey: "showDockIcon") : true)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshStatus() }

    @objc func toggleQuickSetting(_ sender: NSMenuItem) {
        refreshQuickMenu()
        guard sender.isEnabled, let key = sender.representedObject as? String else { return }
        let enabled = sender.state != .on
        switch key {
        case "automaticLock": setAutomaticLock(enabled)
        case "returnEnabled": setReturnEnabled(enabled)
        case "loginEnabled": setLogin(enabled)
        default: setOption(key, enabled)
        }
    }

    @objc func openMenuSection(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let page = SettingsPage(rawValue: name) else { return }
        expandedSettings.insert(page)
        showSettings()
        settingsPage = page; settingsScrollTarget = page; settingsScrollRequest = UUID(); refreshStatus()
    }

    func checkAccessibility() {
        guard !isPreview else { return }
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSystemSettings("Privacy_Accessibility")
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        prefs.register(defaults: ["lockRSSI": -80, "unlockRSSI": -60, "wakeRSSI": -90, "timeout": 6,
                                  "keepDisplayAwake": true, "lockOnSignalLoss": true, "signalLossLockDelay": 15,
                                  "disconnectNotifications": true,
                                  "lockDelay": 5, "thresholdRSSI": -70, "showSettingsOnLaunch": true,
                                  "wakeOnProximity": true, "sleepDisplay": true,
                                  "wakeWithoutUnlocking": true, "watchCompatible": true,
                                  "showStatusLight": true, "showStatusIcon": true, "showStatusRSSI": false,
                                  "colorStatusIcon": true, "showDockIcon": true, "hideDockWhenClosed": true,
                                  "healthyColor": "green", "unhealthyColor": "red", "lightSize": 8, "lightGap": 3,
                                  "resumeMedia": true, "lockNotifications": true, "checkUpdates": true])
        if !prefs.bool(forKey: "returnPolicyV1") {
            // 升级时默认交给系统解锁，用户可在新窗口中明确开启密码输入。
            prefs.set(true, forKey: "wakeWithoutUnlocking")
            prefs.set(true, forKey: "watchCompatible")
            prefs.set(true, forKey: "returnPolicyV1")
        }
        constructMenu()
        if !isPreview {
            do { events = try diagnosticLog.recentEvents() }
            catch { diagnosticStatus = "历史日志读取失败：\(error.localizedDescription)" }
        }
        recordEvent(isPreview ? "已进入隔离演示模式，不执行真实系统操作。" : "应用已启动，版本 \(buildDescription)，源码 \(sourceRevision)；正在初始化设备监测。")
        ble.delegate = self
        ble.lockRSSI = prefs.integer(forKey: "lockRSSI")
        ble.unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        ble.wakeRSSI = min(prefs.integer(forKey: "wakeRSSI"), (ble.unlockRSSI == ble.UNLOCK_DISABLED ? -60 : ble.unlockRSSI) - 5)
        ble.signalTimeout = Double(prefs.integer(forKey: "timeout"))
        ble.lockOnSignalLoss = prefs.bool(forKey: "lockOnSignalLoss")
        ble.signalLossLockDelay = Double(max(1, min(600, prefs.integer(forKey: "signalLossLockDelay"))))
        ble.proximityTimeout = Double(prefs.integer(forKey: "lockDelay"))
        ble.thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if isPreview {
            let device = Device(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            device.blName = "演示 iPhone"
            device.macAddr = "00-00-00-00-00-01"
            device.rssi = -52
            ble.devices[device.uuid] = device
            ble.monitoredUUID = device.uuid
            prefs.set("演示 iPhone", forKey: "deviceName")
            bluetoothState = .poweredOn
            lastRSSI = -52
            ble.lastRawRSSI = -52
            ble.withinWakeRange = true
            lastSignalAt = Date()
            for offset in stride(from: 58, through: 0, by: -2) {
                recordSignalSample(-52 + Int(sin(Double(offset) / 7) * 7), at: Date().addingTimeInterval(-Double(offset)))
            }
            connected = true
            ble.presence = true
            hasPassword = true
            feedback = "演示预览：不连接蓝牙、不访问密码、不执行真实系统操作。"
            refreshStatus()
            showSettings()
            configurePreviewCapture()
            return
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        if let value = prefs.string(forKey: "device"), let uuid = UUID(uuidString: value) {
            ble.startMonitor(uuid: uuid)
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([signalLossCategory])
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationPermission = settings.authorizationStatus == .authorized ? "系统通知已允许" : "系统通知未允许，可在系统设置中开启；窗口和菜单栏仍显示提醒"
                self.refreshStatus()
            }
        }
        if prefs.bool(forKey: "lockNotifications") || prefs.bool(forKey: "disconnectNotifications") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refreshPermissions()
        checkStoredPassword()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshSystemScreenState()
            self?.refreshPermissions()
            self?.refreshStatus()
        }
        if let timer = statusTimer { RunLoop.main.add(timer, forMode: .common) }

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onLock), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        checkUpdate()
        refreshSystemScreenState()
        refreshStatus()
        if prefs.bool(forKey: "showSettingsOnLaunch") { showSettings() }

        updateDockVisibility()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshSystemScreenState()
        refreshPermissions(report: true)
        if !isPreview { checkStoredPassword() }
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ aNotification: Notification) {
        releaseDisplayAssertion()
        ble.signalLossTimer?.invalidate()
        statusTimer?.invalidate()
        scanTimer?.invalidate()
        unlockTimer?.invalidate()
        wakeTimer?.invalidate()
        if isPreview { prefs.removePersistentDomain(forName: previewSuite) }
    }
}
