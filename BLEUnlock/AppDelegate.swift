import Cocoa
import Quartz
import ServiceManagement
import CoreBluetooth
import SwiftUI
import Combine
import LocalAuthentication
import UserNotifications

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, UNUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let isPreview = ProcessInfo.processInfo.arguments.contains("--preview")
    lazy var ble = BLE(enableBluetooth: !isPreview)
    let objectWillChange = ObservableObjectPublisher()
    var settingsWindow: NSWindow?
    var settingsPage: SettingsPage = .overview
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
    var loginEnabled = false
    var loginNeedsApproval = false
    var previewScenario = 0
    var testingUnlock = false
    var events: [RuntimeEvent] = []
    var screenLocked = false
    var lockRequestAt: Date?
    var pendingLockReason: String?
    var passwordAttemptedForLock = false
    var lastActionError: String?
    let mainMenu = NSMenu()
    var monitorMenuItem : NSMenuItem?
    let previewSuite = "local.macautolock.preview.\(UUID().uuidString)"
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

    func newDevice(device: Device) { objectWillChange.send() }
    func updateDevice(device: Device) { objectWillChange.send() }
    func removeDevice(device: Device) { objectWillChange.send() }

    func updateRSSI(rssi: Int?, active: Bool) {
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

    func recordEvent(_ message: String) {
        events.insert(RuntimeEvent(message: message), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        objectWillChange.send()
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        guard !isPreview, prefs.bool(forKey: "lockNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "MacAutolock"
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
                NSWorkspace.shared.open(URL(string: "https://github.com/JahanHe/MacAutolock/releases")!)
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
            if returnPolicy.wake && !systemSleep {
                recordEvent("检测到返回，已请求唤醒屏幕。")
                wakeDisplay()
                wakeTimer?.invalidate()
                var attempts = 0
                wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard let self = self, self.status.healthy, self.ble.presence,
                          self.returnPolicy.wake, !self.manualLock, !self.systemSleep,
                          self.displaySleep, attempts < 3 else { timer.invalidate(); return }
                    attempts += 1
                    wakeDisplay()
                }
            }
            if prefs.bool(forKey: "watchCompatible") {
                recordEvent("Apple Watch 兼容模式：本应用不输入密码，解锁交给 macOS。")
            } else if !returnPolicy.typePassword {
                recordEvent("密码解锁开关已关闭，不输入密码。")
            }
            tryUnlockScreen()
        } else {
            unlockTimer?.invalidate()
            wakeTimer?.invalidate()
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
                  self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED,
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
                  self.status.healthy, self.ble.presence, !self.manualLock else { return }
            
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
    }

    @objc func onDisplaySleep() {
        print("显示器已休眠")
        recordEvent("系统确认显示器已休眠。")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("系统已唤醒")
        recordEvent("系统已从睡眠恢复，正在恢复设备扫描。")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("执行系统唤醒后的延迟任务")
            NSApp.setActivationPolicy(.accessory) // 再次隐藏程序坞图标。
            self.systemSleep = false
            self.ble.scanForPeripherals()
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("系统已休眠")
        recordEvent("系统进入睡眠；深度睡眠期间无法保证蓝牙监测。")
        systemSleep = true
        lastRSSI = nil
        lastSignalAt = nil
        ble.latestRSSIs.removeAll()
        unlockTimer?.invalidate()
        wakeTimer?.invalidate()
        // 临时设为常规应用，让蓝牙重新开启后 CBCentralManager 能继续扫描设备。
        // 这会显示程序坞图标，但此时屏幕已经关闭。
        NSApp.setActivationPolicy(.regular)
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
    }

    @objc func onScreensaverStop() {
        print("屏幕保护程序已停止")
        inScreensaver = false
    }

    func selectDevice(_ uuid: UUID) {
        recordEvent("已选择随身设备：\(ble.devices[uuid]?.description ?? uuid.uuidString)。")
        prefs.set(uuid.uuidString, forKey: "device")
        prefs.set(ble.devices[uuid]?.description ?? "所选设备", forKey: "deviceName")
        connected = false
        lastRSSI = nil
        lastSignalAt = nil
        if isPreview { ble.monitoredUUID = uuid }
        else { ble.startMonitor(uuid: uuid) }
        refreshStatus()
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        guard !isPreview else { return }
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        // 先更新已有条目，避免保存失败时删掉原来的密码。
        var lookup = query
        lookup.removeValue(forKey: String(kSecValueData))
        lookup.removeValue(forKey: String(kSecAttrLabel))
        var status = SecItemUpdate(lookup as CFDictionary, [String(kSecValueData): pw] as CFDictionary)
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
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
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
        msg.window.title = "BLEUnlock"

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
        mainMenu.removeAllItems()
        monitorMenuItem = mainMenu.addItem(withTitle: "等待设备信号", action: nil, keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: "打开设置与测试窗口…", action: #selector(showSettings), keyEquivalent: ",")
        mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        guard !isPreview else { return }
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSystemSettings("Privacy_Accessibility")
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        prefs.register(defaults: ["lockRSSI": -80, "unlockRSSI": -60, "timeout": 60,
                                  "lockDelay": 5, "thresholdRSSI": -70, "showSettingsOnLaunch": true,
                                  "wakeOnProximity": true, "sleepDisplay": true,
                                  "wakeWithoutUnlocking": true, "watchCompatible": true,
                                  "showStatusLight": true, "showStatusIcon": true, "showStatusRSSI": false,
                                  "healthyColor": "green", "unhealthyColor": "red", "lightSize": 8, "lightGap": 3,
                                  "resumeMedia": true, "lockNotifications": true, "checkUpdates": true])
        if !prefs.bool(forKey: "returnPolicyV1") {
            // 升级时默认交给系统解锁，用户可在新窗口中明确开启密码输入。
            prefs.set(true, forKey: "wakeWithoutUnlocking")
            prefs.set(true, forKey: "watchCompatible")
            prefs.set(true, forKey: "returnPolicyV1")
        }
        constructMenu()
        recordEvent(isPreview ? "已进入隔离演示模式，不执行真实系统操作。" : "应用已启动，正在初始化设备监测。")
        ble.delegate = self
        ble.lockRSSI = prefs.integer(forKey: "lockRSSI")
        ble.unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        ble.signalTimeout = Double(prefs.integer(forKey: "timeout"))
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
            lastSignalAt = Date()
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
        if prefs.bool(forKey: "lockNotifications") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refreshPermissions()
        checkStoredPassword()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
            self?.refreshStatus()
        }

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
        refreshStatus()
        if prefs.bool(forKey: "showSettingsOnLaunch") { showSettings() }

        // 启动后隐藏程序坞图标。
        // 不能直接在 Info.plist 中启用 LSUIElement，否则蓝牙设备扫描无法工作。
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        statusTimer?.invalidate()
        scanTimer?.invalidate()
        unlockTimer?.invalidate()
        wakeTimer?.invalidate()
        if isPreview { prefs.removePersistentDomain(forName: previewSuite) }
    }
}
