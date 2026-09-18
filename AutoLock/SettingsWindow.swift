import Cocoa
import SwiftUI
import CoreBluetooth
import ServiceManagement
import UserNotifications
import LocalAuthentication
import UniformTypeIdentifiers

extension AppDelegate {
    var status: ConnectionStatus {
        ConnectionStatus.evaluate(selected: ble.monitoredUUID != nil, bluetooth: bluetoothState,
                                  rssi: lastRSSI, age: lastSignalAt.map { Date().timeIntervalSince($0) },
                                  timeout: ble.signalTimeout)
    }
    var returnPolicy: ReturnPolicy {
        ReturnPolicy.evaluate(enabled: ble.unlockRSSI != ble.UNLOCK_DISABLED,
                              wake: prefs.bool(forKey: "wakeOnProximity"),
                              wakeOnly: prefs.bool(forKey: "wakeWithoutUnlocking"),
                              watchCompatible: prefs.bool(forKey: "watchCompatible"))
    }
    var monitorModeDescription: String {
        if ble.monitoredUUID == nil { return "尚未选择设备" }
        if bluetoothState != .poweredOn { return "蓝牙不可用，等待恢复" }
        if ble.passiveMode { return "被动模式，监听广播" }
        if ble.monitoredPeripheral?.state == .connected && ble.activeModeTimer != nil { return "主动连接，每 2 秒读取" }
        if ble.monitoredPeripheral?.state == .connecting { return "正在连接，同时监听广播" }
        return "监听广播，等待主动读取"
    }
    var loginService: SMAppService { .loginItem(identifier: "jp.sone.BLEUnlock.Launcher") }

    func refreshStatus() {
        updateDisplayAssertion()
        refreshQuickMenu()
        ignoreLossMenuItem?.isHidden = ble.signalLossID == nil || ble.signalLossIgnored || ble.waitingForDeviceAfterUnlock
        objectWillChange.send()
        let value = status
        monitorMenuItem?.title = (ble.signalLossID != nil || ble.waitingForDeviceAfterUnlock) ? signalLossSummary : value.title
        guard let button = statusItem.button else { return }
        let colorLock = prefs.bool(forKey: "colorStatusIcon")
        let showLight = prefs.bool(forKey: "showStatusLight") && !colorLock
        let showIcon = colorLock || prefs.bool(forKey: "showStatusIcon") || !showLight
        let diameter = CGFloat(max(6, min(12, prefs.integer(forKey: "lightSize"))))
        let gap = CGFloat(max(0, min(8, prefs.integer(forKey: "lightGap"))))
        let width: CGFloat = (showIcon ? 18 : 0) + (showLight ? diameter + (showIcon ? gap : 0) : 0) + 2
        let colorName = prefs.string(forKey: value.healthy ? "healthyColor" : "unhealthyColor") ?? (value.healthy ? "green" : "red")
        let color = statusColor(colorName)
        let icon = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            if showIcon {
                let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "自动锁定")!
                let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [colorLock ? color : .labelColor])) ?? symbol
                tinted.draw(in: NSRect(x: 1, y: 1, width: 17, height: 16))
            }
            if showLight {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: showIcon ? 19 + gap : 1, y: (18 - diameter) / 2, width: diameter, height: diameter)).fill()
            }
            return true
        }
        icon.isTemplate = !showLight && !colorLock
        button.image = icon
        button.title = prefs.bool(forKey: "showStatusRSSI") ? (lastRSSI.map { " \($0)" } ?? " —") : ""
        button.toolTip = "AutoLock：\(value.title)\n\((ble.signalLossID != nil || ble.waitingForDeviceAfterUnlock) ? signalLossSummary : value.detail)"
        button.setAccessibilityLabel("AutoLock，\(value.title)")
    }

    func statusColor(_ name: String) -> NSColor {
        switch name {
        case "green": return .systemGreen
        case "red": return .systemRed
        case "blue": return .systemBlue
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        default: return .labelColor
        }
    }

    @objc func showSettings() {
        refreshPermissions()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = isLocalTest ? "AutoLock · 本地测试版" : "AutoLock"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "AutoLockToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.minSize = NSSize(width: 880, height: 690)
            window.level = .normal
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.standardWindowButton(.miniaturizeButton)?.target = self
            window.standardWindowButton(.miniaturizeButton)?.action = #selector(minimizeSettings)
            // ponytail: 原生窗口后方混合直接透出桌面，无需截图权限或自制模糊算法。
            let glass = NSVisualEffectView()
            glass.material = .sidebar
            glass.blendingMode = .behindWindow
            glass.state = .active
            let content = NSHostingView(rootView: SettingsView(app: self))
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
            window.contentView = glass
            if !isPreview { window.setFrameAutosaveName("MacAutolockSettings") }
            window.center()
            settingsWindow = window
        }
        updateDockVisibility(windowVisible: true)
        settingsMinimized = false
        settingsWindow?.deminiaturize(nil)
        NSApp.unhide(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeFirstResponder(nil)
        refreshStatus()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("AutoLockTitle"), .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "AutoLockTitle" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let title = NSTextField(labelWithString: isPreview ? "AutoLock · 演示模式" : (isLocalTest ? "AutoLock · 本地测试版" : "AutoLock"))
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        item.view = title
        item.label = "AutoLock"
        return item
    }

    func shouldShowDock(windowVisible: Bool) -> Bool {
        prefs.bool(forKey: "showDockIcon") && (windowVisible || !prefs.bool(forKey: "hideDockWhenClosed"))
    }

    func updateDockVisibility(windowVisible: Bool? = nil) {
        guard !isPreview else { return }
        let visible = windowVisible ?? (settingsWindow?.isVisible == true || settingsMinimized)
        let policy: NSApplication.ActivationPolicy = shouldShowDock(windowVisible: visible) ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsMinimized = false
        stopDeviceScan()
        updateDockVisibility(windowVisible: false)
        recordEvent("设置窗口已关闭，继续后台监测；可从菜单栏重新打开。")
    }

    func windowDidMiniaturize(_ notification: Notification) {
        recordEvent("设置窗口已最小化，继续后台监测。")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        settingsMinimized = false
        recordEvent("设置窗口已从最小化恢复。")
    }

    @objc func minimizeSettings() {
        guard let window = settingsWindow, window.isVisible else { return }
        settingsMinimized = true
        window.miniaturize(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
            guard let self = self, let window = window, self.settingsMinimized else { return }
            // ponytail: 当前 macOS 若忽略原生最小化请求，收起窗口仍保留后台和恢复入口。
            if !window.isMiniaturized && window.isVisible {
                window.orderOut(nil)
                self.recordEvent("系统未执行原生最小化，已将窗口收起到后台；可从菜单栏或已开启的 Dock 图标恢复。")
            }
            self.updateDockVisibility()
        }
    }

    func startDeviceScan() {
        guard !scanningForDevices else { return }
        guard bluetoothState == .poweredOn else {
            feedback = "请先打开蓝牙并允许蓝牙权限，再扫描设备。"; refreshStatus(); return
        }
        scanningForDevices = true
        if !isPreview { ble.startScanning() }
        feedback = "正在扫描附近设备，请让手机保持在 Mac 旁边。"
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.stopDeviceScan() }
        refreshStatus()
    }

    func stopDeviceScan() {
        let wasScanning = scanningForDevices
        scanTimer?.invalidate()
        scanningForDevices = false
        if !isPreview { ble.stopScanning() }
        if wasScanning {
            feedback = ble.scanAdvertisementCount == 0 ? "扫描结束：系统没有返回蓝牙广播。请查看下方扫描状态，或重新扫描。" :
                "扫描结束：收到 \(ble.scanAdvertisementCount) 次广播，列表中有 \(ble.devices.count) 台设备。请展开设备列表选择。"
            recordEvent(feedback)
        }
        refreshStatus()
    }

    func setOption(_ key: String, _ enabled: Bool) {
        prefs.set(enabled, forKey: key)
        if !prefs.bool(forKey: "showStatusIcon") && !prefs.bool(forKey: "showStatusLight") {
            prefs.set(true, forKey: key == "showStatusIcon" ? "showStatusLight" : "showStatusIcon")
        }
        if key == "pauseAfterManualUnlock" { ble.setPauseAfterManualUnlock(enabled) }
        if key == "passiveMode" {
            if isPreview { ble.passiveMode = enabled } else { ble.setPassiveMode(enabled) }
        }
        if ["lockNotifications", "disconnectNotifications"].contains(key), enabled, !isPreview {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                DispatchQueue.main.async { self.recordEvent(allowed ? "锁定通知权限已允许。" : "通知权限未允许，锁定功能仍正常工作。") }
            }
        }
        if key == "watchCompatible", enabled { prefs.set(true, forKey: "wakeWithoutUnlocking") }
        if key == "wakeWithoutUnlocking" || key == "watchCompatible" { unlockTimer?.invalidate() }
        if key == "wakeOnProximity", !enabled { wakeTimer?.invalidate() }
        if key == "showDockIcon" || key == "hideDockWhenClosed" { updateDockVisibility() }
        if key == "lockOnSignalLoss" {
            ble.lockOnSignalLoss = enabled
            ble.configureSignalLossLock()
            if ble.signalLossID != nil { notifiedSignalLoss = nil; signalLossChanged() }
        }
        feedback = "设置已保存，立即生效。"
        recordEvent("设置已更新：\(optionName(key))，\(enabled ? "开启" : "关闭")。")
        refreshStatus()
    }

    func optionName(_ key: String) -> String {
        ["passiveMode": "被动模式", "wakeWithoutUnlocking": "仅唤醒不输入密码", "watchCompatible": "Apple Watch 兼容模式",
         "wakeOnProximity": "靠近唤醒", "showStatusLight": "状态灯", "showStatusIcon": "锁图标", "showStatusRSSI": "菜单栏信号值",
         "sleepDisplay": "锁定后关屏", "screensaver": "锁定后屏保", "pauseItunes": "离开暂停媒体", "resumeMedia": "解锁后恢复媒体",
         "lockNotifications": "锁定通知", "checkUpdates": "版本检查", "showSettingsOnLaunch": "启动时显示窗口",
         "colorStatusIcon": "状态颜色融入锁图标", "showDockIcon": "显示 Dock 图标", "hideDockWhenClosed": "关窗后隐藏 Dock 图标",
         "pauseAfterManualUnlock": "手动解锁后等待设备", "keepDisplayAwake": "附近保持亮屏", "lockOnSignalLoss": "断连后自动锁定", "disconnectNotifications": "断连通知"][key] ?? "选项"
    }

    func setAutomaticLock(_ enabled: Bool) {
        if !enabled, ble.lockRSSI != ble.LOCK_DISABLED { prefs.set(ble.lockRSSI, forKey: "lastLockRSSI") }
        ble.lockRSSI = enabled ? (prefs.object(forKey: "lastLockRSSI") as? Int ?? -80) : ble.LOCK_DISABLED
        prefs.set(ble.lockRSSI, forKey: "lockRSSI")
        ble.configureSignalLossLock()
        if ble.signalLossID != nil { notifiedSignalLoss = nil; signalLossChanged() }
        if enabled { setNumber("lockRSSI", Double(ble.lockRSSI)) }
        if enabled, !isPreview { ble.resetSignalTimer() }
        recordEvent(enabled ? "自动锁定已开启。" : "自动锁定已关闭，远离或失联时不会锁屏。")
        refreshStatus()
    }

    func setReturnEnabled(_ enabled: Bool) {
        if !enabled, ble.unlockRSSI != ble.UNLOCK_DISABLED { prefs.set(ble.unlockRSSI, forKey: "lastUnlockRSSI") }
        ble.unlockRSSI = enabled ? (prefs.object(forKey: "lastUnlockRSSI") as? Int ?? -60) : ble.UNLOCK_DISABLED
        prefs.set(ble.unlockRSSI, forKey: "unlockRSSI")
        if enabled { setNumber("unlockRSSI", Double(ble.unlockRSSI)) }
        if !enabled { unlockTimer?.invalidate(); wakeTimer?.invalidate() }
        recordEvent(enabled ? "靠近动作已开启。" : "靠近动作已关闭，离开锁定保持独立。")
        refreshStatus()
    }

    func setNumber(_ key: String, _ value: Double) {
        guard value.isFinite, abs(value) < 1_000_000 else { return }
        let number = Int(value.rounded())
        switch key {
        case "lockRSSI":
            ble.lockRSSI = min(-6, max(-99, number))
            if ble.unlockRSSI != ble.UNLOCK_DISABLED, ble.unlockRSSI < ble.lockRSSI + 5 {
                ble.unlockRSSI = ble.lockRSSI + 5; prefs.set(ble.unlockRSSI, forKey: "unlockRSSI")
            }
            prefs.set(ble.lockRSSI, forKey: key)
        case "unlockRSSI":
            ble.unlockRSSI = max(-94, min(-1, number))
            if ble.lockRSSI != ble.LOCK_DISABLED, ble.lockRSSI > ble.unlockRSSI - 5 {
                ble.lockRSSI = ble.unlockRSSI - 5; prefs.set(ble.lockRSSI, forKey: "lockRSSI")
            }
            prefs.set(ble.unlockRSSI, forKey: key)
        case "wakeRSSI":
            ble.wakeRSSI = min(-6, max(-99, number))
        case "lockDelay":
            ble.proximityTimeout = Double(max(1, min(300, number)))
            prefs.set(ble.proximityTimeout, forKey: key)
            ble.proximityTimer?.invalidate(); ble.proximityTimer = nil
        case "timeout":
            ble.signalTimeout = Double(max(1, min(600, number)))
            prefs.set(ble.signalTimeout, forKey: key)
            if !isPreview { ble.resetSignalTimer() }
        case "signalLossLockDelay":
            ble.signalLossLockDelay = Double(max(1, min(600, number)))
            prefs.set(ble.signalLossLockDelay, forKey: key)
            ble.configureSignalLossLock()
            if ble.signalLossID != nil { notifiedSignalLoss = nil; signalLossChanged() }
            recordEvent("断连提醒后的锁定等待时间设为 \(Int(ble.signalLossLockDelay)) 秒；未选择本次跳过时立即应用。")
        case "thresholdRSSI":
            ble.thresholdRSSI = max(-95, min(-30, number)); prefs.set(ble.thresholdRSSI, forKey: key)
        case "lightSize": prefs.set(max(6, min(12, number)), forKey: key)
        case "lightGap": prefs.set(max(0, min(8, number)), forKey: key)
        default: return
        }
        if ["wakeRSSI", "unlockRSSI", "lockRSSI"].contains(key) {
            let unlock = ble.unlockRSSI == ble.UNLOCK_DISABLED ? (prefs.object(forKey: "lastUnlockRSSI") as? Int ?? -60) : ble.unlockRSSI
            ble.wakeRSSI = min(ble.wakeRSSI, unlock - 5)
            prefs.set(ble.wakeRSSI, forKey: "wakeRSSI")
            wakeTimer?.invalidate(); unlockTimer?.invalidate()
            recordEvent("距离门槛已保存：远离 \(ble.lockRSSI) dBm；亮屏 \(ble.wakeRSSI) dBm；密码解锁 \(unlock) dBm。")
        }
        refreshStatus()
    }

    func refreshPermissions(report: Bool = false) {
        guard !isPreview else { accessibilityGranted = true; return }
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        permissionCheckedAt = Date()
        if report || wasGranted != accessibilityGranted {
            recordEvent(accessibilityGranted ? "辅助功能权限复查：当前运行进程已获得授权。" : "辅助功能权限复查：当前运行进程未获得授权；请核对系统列表中的应用与当前版本。")
        }
        screenLocked = isScreenLocked()
        if let requested = lockRequestAt {
            if screenLocked {
                confirmLockRequest()
            } else if Date().timeIntervalSince(requested) > 3 {
                lastActionError = "锁定请求发出后未观察到锁定状态；请使用立即锁定检查当前系统。"
                recordEvent(lastActionError!)
                lockRequestAt = nil
                pendingLockReason = nil
            }
        }
        if isLocalTest { loginEnabled = false; loginNeedsApproval = false; return }
        let value = loginService.status
        loginEnabled = value == .enabled || value == .requiresApproval
        loginNeedsApproval = value == .requiresApproval
    }

    func checkStoredPassword() {
        guard !isPreview else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                   String(kSecAttrAccount): NSUserName(),
                                   String(kSecAttrService): Bundle.main.bundleIdentifier ?? "jp.sone.BLEUnlock",
                                   String(kSecReturnAttributes): true,
                                   String(kSecUseAuthenticationContext): context]
        hasPassword = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setLogin(_ enabled: Bool) {
        if isPreview { loginEnabled = enabled; refreshStatus(); return }
        guard !isLocalTest else { feedback = "本地测试版不注册登录项，确认后在安装版中设置。"; refreshStatus(); return }
        do {
            if enabled { try loginService.register() } else { try loginService.unregister() }
            prefs.set(enabled, forKey: "launchAtLogin")
            feedback = enabled ? "已提交登录启动设置；如系统要求批准，请在登录项中允许。" : "已关闭登录时启动。"
        } catch { feedback = "无法修改登录启动：\(error.localizedDescription)" }
        recordEvent(feedback)
        refreshPermissions(); refreshStatus()
    }

    func openSystemSettings(_ anchor: String) {
        guard !isPreview else { feedback = "演示预览不会打开或修改系统设置。"; refreshStatus(); return }
        if anchor == "login" { SMAppService.openSystemSettingsLoginItems(); return }
        let url = anchor == "watch" ? "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension" :
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    func startScreensaver() {
        guard !isPreview else { return }
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { self.feedback = "屏幕保护程序启动失败，请检查系统屏保设置。"; self.refreshStatus() } }
        }
    }

    func turnOffDisplay() {
        guard !isPreview else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                self.recordEvent(process.terminationStatus == 0 ? "系统已接受关闭显示器命令。" : "关闭显示器命令失败，退出代码：\(process.terminationStatus)。")
            }
        }
        do { try process.run() } catch { feedback = "关闭屏幕失败：\(error.localizedDescription)"; recordEvent(feedback); refreshStatus() }
    }

    func testEffect(_ effect: String) {
        if isPreview {
            previewScenario = ["锁定", "关闭屏幕", "屏保", "锁定后测试靠近"].contains(effect) ? 1 : 0
            feedback = "演示：\(effect)效果已预览，没有执行真实系统操作。"; recordEvent(feedback); refreshStatus(); return
        }
        feedback = "已请求\(effect)，请观察系统实际效果。"
        recordEvent("用户发起效果测试：\(effect)。")
        switch effect {
        case "锁定": lockNow()
        case "关闭屏幕": turnOffDisplay()
        case "唤醒屏幕": wakeDisplay()
        case "屏保": startScreensaver()
        case "暂停播放": MRMediaRemoteSendCommand(MRCommandPause, nil)
        case "恢复播放": MRMediaRemoteSendCommand(MRCommandPlay, nil)
        case "通知", "断连通知":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                if allowed {
                    let content = UNMutableNotificationContent()
                    content.title = "AutoLock · 测试通知"; content.body = "通知功能可用。这次测试没有锁定屏幕。"
                    if effect == "断连通知" {
                        content.body = "模拟设备断连：可在通知中选择“本次不锁定”。这次仅测试通知按钮，不会断开蓝牙或锁屏。"
                        content.categoryIdentifier = "signal-loss"
                    }
                    UNUserNotificationCenter.current().add(.init(identifier: effect == "断连通知" ? "test-signal-loss" : "test", content: content, trigger: nil)) { error in
                        if let error = error { DispatchQueue.main.async { self.recordEvent("测试通知发送失败：\(error.localizedDescription)") } }
                    }
                }
                DispatchQueue.main.async {
                    self.feedback = allowed ? "测试通知已提交；显示方式取决于通知设置和专注模式。" : "通知权限未允许，请在系统设置中打开。"
                    self.refreshStatus()
                }
            }
        case "锁定后测试靠近":
            guard status.healthy, ble.presence, ble.unlockRSSI != ble.UNLOCK_DISABLED else {
                feedback = "需要设备在附近、信号正常，并开启靠近动作。"; refreshStatus(); return
            }
            if returnPolicy.typePassword && (!accessibilityGranted || !hasPassword) {
                feedback = "密码解锁测试需要辅助功能权限和已保存的登录密码。"; refreshStatus(); return
            }
            testingUnlock = true
            lockNow()
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.testingUnlock = false
                guard self.status.healthy, self.ble.presence else { return }
                self.manualLock = false
                if self.returnPolicy.wake { wakeDisplay() }
                self.tryUnlockScreen()
            }
        default: break
        }
        refreshStatus()
    }

    func verifyPreviewSettings() -> Int {
        precondition(isPreview, "设置联动检查只能在隔离预览中运行")
        let saved = prefs.persistentDomain(forName: previewSuite) ?? [:]
        let savedEvents = events
        let savedHistory = signalHistory
        let oldLock = ble.lockRSSI, oldUnlock = ble.unlockRSSI
        let oldWake = ble.wakeRSSI
        let oldRSSI = lastRSSI, oldSignalAt = lastSignalAt
        let oldScreen = (screenLocked, displaySleep, systemSleep, inScreensaver)
        let oldTimeout = ble.signalTimeout, oldDelay = ble.proximityTimeout
        let oldLossDelay = ble.signalLossLockDelay, oldLossLock = ble.lockOnSignalLoss
        defer {
            prefs.setPersistentDomain(saved, forName: previewSuite)
            ble.lockRSSI = oldLock; ble.unlockRSSI = oldUnlock
            ble.wakeRSSI = oldWake; lastRSSI = oldRSSI; lastSignalAt = oldSignalAt
            (screenLocked, displaySleep, systemSleep, inScreensaver) = oldScreen
            ble.signalTimeout = oldTimeout; ble.proximityTimeout = oldDelay
            ble.signalLossLockDelay = oldLossDelay; ble.lockOnSignalLoss = oldLossLock
            events = savedEvents; previewScenario = 0; signalHistory = savedHistory
            expandedSettings.removeAll(); settingsPage = .overview; settingsScrollTarget = .overview; settingsScrollRequest = UUID()
            feedback = "演示预览：不连接蓝牙、不访问密码、不执行真实系统操作。"
            recordEvent("设置联动与预览隔离检查已通过。")
        }
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        setReturnEnabled(false)
        check(ble.lockRSSI == oldLock && !returnPolicy.wake && !returnPolicy.typePassword, "关闭返回不能关闭锁定")
        setAutomaticLock(false); setReturnEnabled(true)
        check(ble.lockRSSI == ble.LOCK_DISABLED && returnPolicy.wake, "关闭锁定不能关闭返回")
        setAutomaticLock(true)
        check(ble.lockRSSI == oldLock, "重启开关必须恢复旧门槛")
        setOption("watchCompatible", false); setOption("wakeWithoutUnlocking", false)
        check(returnPolicy.typePassword, "主动选择密码解锁应生效")
        setOption("watchCompatible", true)
        check(!returnPolicy.typePassword && prefs.bool(forKey: "wakeWithoutUnlocking"), "手表兼容必须阻止密码输入")
        setOption("showStatusIcon", false); setOption("showStatusLight", false)
        check(prefs.bool(forKey: "showStatusIcon") || prefs.bool(forKey: "showStatusLight"), "必须保留设置入口")
        setNumber("lockDelay", 300); setNumber("timeout", 600)
        check(ble.proximityTimeout == 300 && ble.signalTimeout == 600, "保留原来的最长计时")
        setNumber("lockRSSI", -40)
        check(ble.unlockRSSI >= ble.lockRSSI + 5, "调整远离门槛必须保持迟滞间隔")
        setReturnEnabled(false); setNumber("lockRSSI", -20); setReturnEnabled(true)
        check(ble.unlockRSSI >= ble.lockRSSI + 5, "重新打开返回仍需保持门槛间隔")
        check(ble.centralMgr == nil, "预览不得创建蓝牙管理器")
        for effect in ["锁定", "关闭屏幕", "唤醒屏幕", "屏保", "暂停播放", "恢复播放", "通知", "断连通知", "锁定后测试靠近"] {
            testEffect(effect)
            check(lockRequestAt == nil && unlockTimer == nil && !testingUnlock, "预览按钮不得发出系统请求")
        }
        check(fetchPassword() == nil, "预览不得读取密码")
        setNumber("unlockRSSI", -60); setNumber("wakeRSSI", -90)
        check(ble.wakeRSSI == -90 && ble.unlockRSSI == -60, "亮屏与密码解锁门槛可以分开设置")
        let protectedLock = ble.lockRSSI
        setNumber("wakeRSSI", -40)
        check(ble.wakeRSSI == -65 && ble.lockRSSI == protectedLock, "亮屏门槛自动保持顺序，不改变离开锁定门槛")
        setNumber("unlockRSSI", -90)
        check(ble.wakeRSSI <= ble.unlockRSSI - 5, "修改密码门槛后亮屏仍须更早")
        setOption("showDockIcon", true); setOption("hideDockWhenClosed", true)
        check(shouldShowDock(windowVisible: true) && !shouldShowDock(windowVisible: false), "关窗隐藏 Dock，打开窗口恢复")
        setOption("hideDockWhenClosed", false)
        check(shouldShowDock(windowVisible: false), "可以选择关窗后继续显示 Dock")
        setOption("showDockIcon", false)
        check(!shouldShowDock(windowVisible: true) && !shouldShowDock(windowVisible: false), "可以选择始终隐藏 Dock")
        setOption("colorStatusIcon", true)
        lastRSSI = -52; lastSignalAt = Date(); refreshStatus()
        check(statusItem.button?.image?.size.width == 20 && statusItem.button?.image?.isTemplate == false, "颜色融入锁图标时不占用独立圆点空间")
        func containsColor(green: Bool) -> Bool {
            guard let data = statusItem.button?.image?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else { return false }
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                    if green ? (c.greenComponent > c.redComponent * 1.3 && c.greenComponent > c.blueComponent * 1.1) : (c.redComponent > c.greenComponent * 1.3) { return true }
                }
            }
            return false
        }
        check(containsColor(green: true), "真实菜单图像必须绘制出绿色锁")
        lastRSSI = nil; lastSignalAt = nil; refreshStatus()
        check(containsColor(green: false), "失联时真实菜单图像必须绘制出红色锁")
        check(settingsWindow?.styleMask.contains([.closable, .miniaturizable, .resizable]) == true, "应用窗口必须可关闭、最小化和调整大小")
        check(settingsWindow?.level == .normal, "窗口必须使用普通层级，不可始终置顶")
        check(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "关闭最后一个窗口不能退出后台监测")
        check(!showEffectPreview, "模拟预览必须默认收起，不常驻替代真实状态")
        check(expandedSettings.isEmpty, "连续设置页的详细内容默认收起")
        setNumber("signalLossLockDelay", 15)
        check(ble.signalLossLockDelay == 15, "断连等待可以独立设为 15 秒")
        setNumber("signalLossLockDelay", 0)
        check(ble.signalLossLockDelay == 1, "通知必须至少留 1 秒处理时间")
        setNumber("signalLossLockDelay", 999)
        check(ble.signalLossLockDelay == 600, "断连等待不能超出可选范围")
        setOption("lockOnSignalLoss", false)
        check(!ble.lockOnSignalLoss && ble.lockRSSI != ble.LOCK_DISABLED, "关闭断连锁定不能关闭远离保护")
        setOption("lockOnSignalLoss", true)
        check(ble.lockOnSignalLoss, "断连保护可以重新打开")
        setOption("pauseAfterManualUnlock", false)
        check(!ble.pauseAfterManualUnlock, "等待设备选项应同步到实际判断器")
        setOption("pauseAfterManualUnlock", true)
        ble.presence = false; ble.rearmAfterUnlock()
        check(ble.waitingForDeviceAfterUnlock && monitorMenuItem?.title.contains("暂停") == true, "暂停锁定必须同步显示到菜单")
        check(signalLossSummary.contains("等待设备"), "暂停时不能显示仍在倒计时")
        ble.updateMonitoredPeripheral(-50)
        check(!ble.waitingForDeviceAfterUnlock, "下一次有效采样恢复保护")
        ble.signalTimer?.invalidate(); ble.proximityTimer?.invalidate()
        setOption("keepDisplayAwake", true)
        check(displayAssertion == 0, "隔离预览不得申请真实保持亮屏")
        setOption("keepDisplayAwake", false)
        check(!shouldKeepDisplayAwake, "关闭开关立即停止保持亮屏")
        check(signalLossCategory.actions.first?.title == "本次不锁定", "断连通知首先提供不锁定按钮")
        check(signalLossCategory.actions.first?.options.contains(.foreground) == false, "通知取消操作不必打开应用窗口")
        check(signalLossCategory.actions.last?.identifier == "reconnect-device", "通知也提供重新连接入口")
        check(settingsWindow?.styleMask.contains(.fullSizeContentView) == true && settingsWindow?.titlebarAppearsTransparent == true, "窗口顶部必须与内容融合")
        check(settingsWindow?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "AutoLockTitle" } == true, "统一工具栏显示 AutoLock")
        check([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { settingsWindow?.standardWindowButton($0) != nil }, "必须保留三个原生窗口按钮")
        setAutomaticLock(true)
        toggleQuickSetting(quickMenuItems["automaticLock"]!)
        check(ble.lockRSSI == ble.LOCK_DISABLED && quickMenuItems["automaticLock"]?.state == .off, "菜单关闭自动锁定必须同步真实设置")
        toggleQuickSetting(quickMenuItems["automaticLock"]!)
        check(ble.lockRSSI != ble.LOCK_DISABLED && quickMenuItems["automaticLock"]?.state == .on, "菜单可恢复自动锁定")
        setReturnEnabled(true); toggleQuickSetting(quickMenuItems["returnEnabled"]!)
        check(!returnPolicy.wake && quickMenuItems["wakeOnProximity"]?.isEnabled == false, "关闭靠近动作时菜单亮屏开关禁用")
        setReturnEnabled(true); setOption("wakeOnProximity", true)
        toggleQuickSetting(quickMenuItems["wakeOnProximity"]!)
        check(!returnPolicy.wake && !prefs.bool(forKey: "wakeOnProximity"), "菜单亮屏与窗口开关共用设置")
        setOption("watchCompatible", false); setOption("wakeWithoutUnlocking", false)
        toggleQuickSetting(quickMenuItems["watchCompatible"]!)
        check(!returnPolicy.typePassword && prefs.bool(forKey: "watchCompatible"), "菜单开启手表兼容同样禁止密码输入")
        let section = NSMenuItem(); section.representedObject = SettingsPage.activity.rawValue
        openMenuSection(section)
        check(expandedSettings.contains(.activity) && settingsScrollTarget == .activity, "菜单日志入口直接展开并定位运行记录")
        signalHistory.removeAll()
        let sampleTime = Date()
        recordSignalSample(-55, at: sampleTime.addingTimeInterval(-70)); recordSignalSample(127, at: sampleTime)
        check(signalHistory.count == 1, "信号曲线只保留最近 60 秒")
        check(signalHistory.last?.rssi == nil, "无效信号在曲线中保留为断点")
        for _ in 0..<300 { recordSignalSample(-55, at: sampleTime) }
        check(signalHistory.count == 240, "广播密集时曲线样本也必须有界")
        check(settingsWindow?.isOpaque == false && settingsWindow?.backgroundColor == .clear, "窗口底层必须透明，不能遮住桌面")
        check((settingsWindow?.contentView as? NSVisualEffectView)?.blendingMode == .behindWindow, "毛玻璃必须混合窗口后方内容")
        screenLocked = false; displaySleep = false; systemSleep = false; inScreensaver = false
        check(screenPresentation.title == "桌面已解锁" && screenPresentation.lit, "桌面状态必须来自系统状态")
        lockRequestAt = Date()
        check(screenPresentation.title == "桌面已解锁", "锁定请求发出不能提前显示已锁定")
        lockRequestAt = nil; screenLocked = true
        check(screenPresentation.title == "已锁定 · 等待解锁" && screenPresentation.lit, "锁定不等于关屏")
        displaySleep = true
        check(screenPresentation.title == "屏幕已关闭" && !screenPresentation.lit && screenLocked, "关屏要变暗并保留独立锁定状态")
        systemSleep = true
        check(screenPresentation.title == "系统睡眠中" && !screenPresentation.lit, "整机睡眠与关屏分开显示")
        systemSleep = false; displaySleep = false; screenLocked = false; inScreensaver = true
        check(screenPresentation.title == "屏幕保护程序" && screenPresentation.lit, "屏保不能冒充已锁定")
        refreshSystemScreenState()
        check(inScreensaver && !screenLocked, "隔离演示不能读取真实屏幕状态覆盖演示数据")
        return count
    }

    var sourceRevision: String { Bundle.main.object(forInfoDictionaryKey: "AutoLockSourceRevision") as? String ?? "未记录（本地构建）" }
    var sourceFingerprint: String { Bundle.main.object(forInfoDictionaryKey: "AutoLockSourceFingerprint") as? String ?? "未记录" }
    var buildDescription: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")（构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")）"
    }

    func clearDiagnosticLog() {
        do {
            if !isPreview { try diagnosticLog.clear() }
            events.removeAll()
            diagnosticStatus = "运行记录已清空。后续事件将继续记录。"
            refreshStatus()
        } catch { diagnosticStatus = "无法清空日志：\(error.localizedDescription)"; refreshStatus() }
    }

    func exportDiagnostics() {
        guard !isPreview else { feedback = "演示模式不读取真实运行日志；安装后的运行记录页面可以导出诊断包。"; refreshStatus(); return }
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.message = "包含中文事件、系统版本、功能设置和源码版本，不包含密码；设备名称可能出现在事件中。文件不会自动上传。"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "AutoLock-诊断.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var settings: [String: Any] = [:]
        for key in ["passiveMode", "wakeWithoutUnlocking", "watchCompatible", "wakeOnProximity", "sleepDisplay", "screensaver", "pauseItunes", "resumeMedia", "lockNotifications", "checkUpdates", "showSettingsOnLaunch", "showStatusLight", "showStatusIcon", "showStatusRSSI", "colorStatusIcon", "showDockIcon", "hideDockWhenClosed", "keepDisplayAwake", "lockOnSignalLoss", "disconnectNotifications", "pauseAfterManualUnlock"] {
            settings[optionName(key)] = prefs.bool(forKey: key)
        }
        settings["自动锁定"] = ble.lockRSSI != ble.LOCK_DISABLED
        settings["靠近动作"] = ble.unlockRSSI != ble.UNLOCK_DISABLED
        settings["远离门槛"] = ble.lockRSSI
        settings["靠近门槛"] = ble.unlockRSSI
        settings["亮屏门槛"] = ble.wakeRSSI
        settings["远离确认秒数"] = ble.proximityTimeout
        settings["失联超时秒数"] = ble.signalTimeout
        settings["断连提醒后等待秒数"] = ble.signalLossLockDelay
        let summary: [String: Any] = ["应用版本": buildDescription, "源码提交": sourceRevision, "本地源码校验值": sourceFingerprint,
            "源码仓库": "https://github.com/JahanHe/AutoLock", "系统版本": ProcessInfo.processInfo.operatingSystemVersionString,
            "监测状态": status.title, "采样方式": monitorModeDescription, "屏幕已锁定": screenLocked,
            "辅助功能权限": accessibilityGranted, "密码是否已保存": hasPassword,
            "附近保持亮屏已生效": displayAssertion != 0, "保持亮屏错误": displayAssertionError ?? "暂无",
            "解锁后等待设备": ble.waitingForDeviceAfterUnlock, "最近亮屏结果": lastWakeResult,
            "断连策略状态": signalLossSummary, "通知权限": notificationPermission,
            "最近操作错误": lastActionError ?? "暂无", "日志状态": diagnosticStatus, "功能设置": settings]
        do {
            try diagnosticLog.export(to: destination, summary: summary, events: events)
            feedback = "诊断包已导出。请把包和复现过程带回这个 Codex 任务，即可对照源码继续排查。"
            recordEvent("用户已导出诊断包，文件未自动上传。")
        } catch { feedback = "诊断包导出失败：\(error.localizedDescription)"; recordEvent(feedback) }
        refreshStatus()
    }

    private func capturePreviewWindow(to path: URL, composited: Bool) -> [CGFloat]? {
        precondition(isPreview)
        guard let window = settingsWindow else { return nil }
        if !composited {
            guard let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
            return nil
        }
        window.orderFrontRegardless()
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        let info = windows?.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        guard let bounds = info?[kCGWindowBounds as String] as? [String: NSNumber],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              width.intValue > 0, height.intValue > 0 else { preconditionFailure("无法获取测试窗口区域") }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let region = "\(x.intValue),\(y.intValue),\(width.intValue),\(height.intValue)"
        capture.arguments = ["-x", "-R", region, path.path]
        print("正在合成截图：\(path.lastPathComponent)，区域 \(region)")
        fflush(stdout)
        do { try capture.run(); capture.waitUntilExit() }
        catch { preconditionFailure("窗口合成截图失败：\(error)") }
        precondition(capture.terminationStatus == 0, "窗口合成截图失败，请确认屏幕已解锁和截图权限")
        guard let data = try? Data(contentsOf: path), let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: 24)?.usingColorSpace(.deviceRGB) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    func configurePreviewCapture() {
        guard isPreview else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--check-window") {
            NSApp.setActivationPolicy(.regular)
            settingsWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = self.settingsWindow else { exit(1) }
                window.standardWindowButton(.miniaturizeButton)?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    precondition(window.isMiniaturized || !window.isVisible, "黄色按钮必须将窗口最小化或收起")
                    self.showSettings()
                    precondition(window.isVisible && !window.isMiniaturized, "收起后必须可以重新打开")
                    window.performClose(nil)
                    precondition(!window.isVisible, "红色按钮必须关闭窗口")
                    self.showSettings()
                    precondition(window.isVisible, "关闭后菜单入口必须可重新打开")
                    print("窗口操作检查通过：4 项，最小化／收起、恢复、关闭、重新打开。")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        guard let index = args.firstIndex(of: "--capture"), args.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let composited = args.contains("--capture-composited")
        if composited { precondition(!isScreenLocked() && CGDisplayIsAsleep(CGMainDisplayID()) == 0, "合成截图需要先解锁 Mac 并保持亮屏；普通隔离检查不需要") }
        if composited, let window = settingsWindow, let screen = window.screen {
            // 演示窗口靠左，避免右上角系统通知进入对外发布的截图区域。
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: window.frame.minY))
        }
        // 可选的原生合成截图使用本应用的彩色衬底，不截取用户桌面或其他应用内容。
        let backdrop = composited ? NSWindow(contentRect: settingsWindow!.frame.insetBy(dx: -30, dy: -30), styleMask: .borderless, backing: .buffered, defer: false) : nil
        backdrop?.isReleasedWhenClosed = false
        backdrop?.backgroundColor = .systemBlue
        backdrop?.ignoresMouseEvents = true
        let checks = verifyPreviewSettings()
        if composited {
            settingsWindow?.level = .floating
            settingsWindow?.ignoresMouseEvents = true
            backdrop?.level = .floating
        }
        let report: [String: Any] = ["设置检查通过": checks, "隔离预览": isPreview,
                                    "系统版本": ProcessInfo.processInfo.operatingSystemVersionString]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("预览检查.json"))
        }
        // ponytail: 复用真实设置窗口截图，演示模式隔离所有系统操作，无需维护第二套界面。
        var glassColors: [String: [CGFloat]] = [:]
        let scenes: [(String, SettingsPage)] = [("浅色", .overview), ("深色", .overview), ("设备", .device),
            ("离开锁定", .lock), ("靠近与解锁", .returning), ("分段亮屏", .tests), ("菜单栏外观", .appearance), ("其他设置", .extras), ("效果测试", .tests), ("运行记录", .activity), ("失联", .overview), ("已锁定", .overview), ("已关屏", .overview), ("屏保", .overview), ("透明对照", .overview), ("解锁暂停", .overview)]
        for (offset, scene) in scenes.enumerated() {
            let (name, page) = scene
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset * 3 + 2)) {
                self.settingsWindow?.appearance = NSAppearance(named: offset == 1 ? .darkAqua : .aqua)
                if let backdrop = backdrop, let window = self.settingsWindow {
                    backdrop.backgroundColor = name == "透明对照" ? .systemOrange : .systemBlue
                    backdrop.order(.below, relativeTo: window.windowNumber)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.settingsPage = page
                self.settingsScrollTarget = page
                self.settingsWindow?.makeFirstResponder(nil)
                self.settingsScrollRequest = UUID()
                self.expandedSettings = page == .overview ? [] : [page]
                self.previewScenario = name == "分段亮屏" ? 3 : 0
                self.showEffectPreview = name == "分段亮屏"
                self.lastSignalAt = Date()
                self.lastRSSI = -52
                self.screenLocked = ["已锁定", "已关屏"].contains(name)
                self.displaySleep = name == "已关屏"
                self.inScreensaver = name == "屏保"
                self.recordSignalSample(name == "失联" ? nil : self.lastRSSI)
                if name == "失联" { self.lastRSSI = nil; self.lastSignalAt = nil; self.previewScenario = 2 }
                if name == "解锁暂停" {
                    self.lastRSSI = nil; self.lastSignalAt = nil; self.ble.presence = false
                    self.ble.rearmAfterUnlock()
                    self.ble.signalTimer?.invalidate()
                }
                self.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let path = directory.appendingPathComponent("设置窗口-\(name).png")
                    if let color = self.capturePreviewWindow(to: path, composited: composited) { glassColors[name] = color }
                    if name == "靠近与解锁" {
                        let result = ["目标分组": page.rawValue, "当前分组": self.settingsPage.rawValue]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: directory.appendingPathComponent("导航检查.json"))
                        }
                        precondition(self.settingsPage == page, "展开后必须滚到目标分组")
                    }
                    if let data = self.statusItem.button?.image?.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: data) {
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("菜单灯-\(name).png"))
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(scenes.count * 3 + 2)) {
            if composited {
                let difference = zip(glassColors["浅色"] ?? [], glassColors["透明对照"] ?? []).map { abs($0 - $1) }.max() ?? 0
                let result: [String: Any] = ["标题区域背景色差": difference, "透背景检查通过": difference > 0.05, "采样颜色": glassColors]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("透明检查.json"))
                }
                precondition(difference > 0.05, "切换窗口后方背景时，标题区必须有可见颜色变化")
            }
            backdrop?.close(); NSApp.terminate(nil)
        }
    }
}

enum SettingsPage: String, CaseIterable {
    case overview = "状态总览", device = "随身设备", lock = "离开锁定", returning = "靠近与解锁", appearance = "菜单栏外观", activity = "运行记录", extras = "其他设置", tests = "效果测试"
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .device: return "iphone.radiowaves.left.and.right"
        case .lock: return "lock.shield"
        case .returning: return "sun.max"
        case .activity: return "list.bullet.rectangle"
        case .appearance: return "menubar.rectangle"
        case .extras: return "slider.horizontal.3"
        case .tests: return "play.rectangle"
        }
    }

}

struct SettingsView: View {
    @ObservedObject var app: AppDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var page: SettingsPage {
        get { app.settingsPage }
        nonmutating set {
            app.settingsWindow?.makeFirstResponder(nil)
            app.settingsPage = newValue; app.settingsScrollTarget = newValue
            app.settingsScrollRequest = UUID(); app.refreshStatus()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(SettingsPage.allCases, id: \.self) { item in
                            settingSection(item)
                                .id(item)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SettingsPositionKey.self,
                                        value: [item: geometry.frame(in: .named("settings-scroll")).minY])
                                })
                        }
                    } .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
                .coordinateSpace(name: "settings-scroll")
                .onPreferenceChange(SettingsPositionKey.self) { positions in
                    let visible = positions.filter { $0.value <= 20 }.max { $0.value < $1.value }?.key ?? .overview
                    if app.settingsPage != visible { app.settingsPage = visible; app.objectWillChange.send() }
                }
                .onChange(of: app.settingsScrollRequest) { _ in
                    let target = app.settingsScrollTarget
                    let request = app.settingsScrollRequest
                    // 折叠内容需完成下一轮布局再定位；新请求到来时丢弃旧跳转。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard app.settingsScrollRequest == request else { return }
                        app.settingsWindow?.contentView?.layoutSubtreeIfNeeded()
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                }
            }.frame(minWidth: 452)
            Divider()
            liveStatusPanel.frame(width: 300).padding(20)
        }.frame(minHeight: 620)
            .background {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.72), location: 0.16),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.9), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
    }

    private func settingSection(_ item: SettingsPage) -> some View {
        let expanded = app.expandedSettings.contains(item)
        let toggleDetails = {
            if expanded { app.expandedSettings.remove(item) } else { app.expandedSettings.insert(item) }
            app.objectWillChange.send()
        }
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: toggleDetails) {
                HStack {
                    Label(item.rawValue, systemImage: item.symbol).font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(item.rawValue)，\(expanded ? "收起详细设置" : "展开详细设置")")
            if expanded {
                pageContent(item)
                Divider()
                Text(app.feedback).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            else { compactContent(item) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.showSettingExplanations, expanded)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle()).onTapGesture(perform: toggleDetails))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }

    @ViewBuilder private func compactContent(_ item: SettingsPage) -> some View {
        switch item {
        case .overview:
            HStack {
                Text(app.status.title).foregroundStyle(app.status.healthy ? .green : .red)
                Spacer()
                Text(app.lastRSSI.map { "\($0) dBm" } ?? "暂无信号").monospacedDigit()
            }
        case .device:
            HStack {
                Text(app.prefs.string(forKey: "deviceName") ?? "尚未选择设备").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(app.status.healthy ? "信号正常" : "等待信号").foregroundStyle(.secondary)
            }
            option("passiveMode", "被动模式", "")
        case .lock:
            switchRow("自动锁定", "", binding: Binding(get: { app.ble.lockRSSI != app.ble.LOCK_DISABLED }, set: app.setAutomaticLock))
            option("pauseAfterManualUnlock", "手动解锁后等待设备", "")
            option("disconnectNotifications", "断连通知", "")
            option("lockOnSignalLoss", "断连后自动锁定", "")
        case .returning:
            switchRow("靠近动作", "", binding: Binding(get: { app.ble.unlockRSSI != app.ble.UNLOCK_DISABLED }, set: app.setReturnEnabled))
            option("wakeOnProximity", "靠近亮屏", "").disabled(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
            option("keepDisplayAwake", "附近保持亮屏", "")
            option("watchCompatible", "Apple Watch 兼容", "")
            switchRow("密码解锁", "", binding: Binding(get: { !app.prefs.bool(forKey: "wakeWithoutUnlocking") && !app.prefs.bool(forKey: "watchCompatible") }, set: { app.setOption("wakeWithoutUnlocking", !$0) }))
                .disabled(app.prefs.bool(forKey: "watchCompatible") || app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
        case .appearance:
            option("colorStatusIcon", "彩色状态锁", "")
            option("showStatusRSSI", "显示信号数值", "")
        case .activity:
            Text("\(app.events.count) 条记录").monospacedDigit()
        case .extras:
            switchRow("登录时启动", "", binding: Binding(get: { app.loginEnabled }, set: app.setLogin))
            option("showDockIcon", "显示 Dock 图标", "")
            option("hideDockWhenClosed", "关窗隐藏 Dock 图标", "").disabled(!app.prefs.bool(forKey: "showDockIcon"))
        case .tests:
            EmptyView()
        }
    }

    @ViewBuilder private func pageContent(_ item: SettingsPage) -> some View {
        switch item {
        case .overview: overview
        case .device: deviceSettings
        case .lock: lockSettings
        case .returning: returnSettings
        case .activity: activitySettings
        case .appearance: appearanceSettings
        case .extras: extraSettings
        case .tests: effectTests
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(app.status.title, systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(app.status.healthy ? .green : .red)
                Spacer()
                Text(app.lastRSSI.map { "\($0) dBm" } ?? "暂无信号").monospacedDigit()
            }.font(.callout.weight(.medium))
            Text(runtimeSummary).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(app.monitorModeDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("运行记录") { app.expandedSettings.insert(.activity); page = .activity }
                Button("效果测试") { app.expandedSettings.insert(.tests); page = .tests }
            }
            SettingExplanation(text: "绿色表示正在收到有效信号，不代表屏幕是否锁定。距离、锁定倒计时和系统确认结果显示在右侧；详细事件会保存到本机日志。")
        }.padding(.top, 5)
    }

    private var runtimeSummary: String {
        if app.ble.monitoredUUID == nil { return "等待选择设备，尚未开始自动锁定。" }
        if app.ble.lockRSSI == app.ble.LOCK_DISABLED { return "自动锁定已关闭；设备监测仍在运行。" }
        if app.lockRequestAt != nil { return "正在请求系统锁定，等待确认。" }
        if app.lastActionError != nil { return "最近操作存在异常，请查看下方原因。" }
        if app.systemSleep { return "系统休眠中，等待恢复扫描。" }
        if app.screenLocked && app.manualLock { return "手动锁定保护中，设备离开再回来才执行返回动作。" }
        if app.screenLocked { return "屏幕已锁定，继续监测返回条件。" }
        if app.ble.waitingForDeviceAfterUnlock { return app.signalLossSummary }
        if app.ble.proximityTimer?.isValid == true { return "信号持续偏弱，正在确认是否离开。" }
        if app.ble.signalLossID != nil { return app.signalLossSummary }
        if !app.status.healthy { return "监测信号异常，等待断连确认与所选处理策略。" }
        return "自动锁定正常待命，等待远离或失联条件。"
    }

    private var activitySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("当前运行情况", icon: "waveform.path.ecg") {
                Text(runtimeSummary).font(.headline)
                Text("设备连接：\(app.status.title) · \(app.monitorModeDescription)").font(.callout)
                Text("原始信号：\(app.ble.lastRawRSSI.map { "\($0) dBm" } ?? "暂无")；平均信号：\(app.lastRSSI.map { "\($0) dBm" } ?? "暂无")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("远离门槛：\(app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "自动锁定已关闭" : "\(app.ble.lockRSSI) dBm")；靠近门槛：\(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? "动作已关闭" : "\(app.ble.unlockRSSI) dBm")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("分段靠近：\(app.ble.wakeRSSI) dBm 允许亮屏，\(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? "密码解锁已关闭" : "\(app.ble.unlockRSSI) dBm 才允许本应用解锁")。当前\(app.ble.canUnlockAtCurrentSignal ? "已达到" : "未达到")密码解锁距离。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("辅助功能：\(app.accessibilityGranted ? "已允许" : "未允许")；密码：\(app.hasPassword ? "已保存" : "未保存")；本应用密码输入：\(app.returnPolicy.typePassword ? "已开启" : "已关闭")")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = app.lastActionError { Text(error).font(.callout).foregroundStyle(.red) }
            }
            card("版本与诊断", icon: "doc.zipper") {
                Text("应用：\(app.buildDescription)").font(.callout)
                Text("源码：\(app.sourceRevision)").font(.caption).textSelection(.enabled)
                if app.sourceFingerprint != "未记录" {
                    Text("本地源码：\(app.sourceFingerprint)").font(.caption).textSelection(.enabled)
                    SettingExplanation(text: "本地修改包含在随安装包交付的源码 ZIP 中。下方仓库链接是修改前的源码基线；诊断包会记录本地源码校验值。")
                }
                Text(app.diagnosticStatus).font(.caption).foregroundStyle(.secondary)
                SettingExplanation(text: "日志在本机滚动保留两份，每份约 1 MiB。退出后保留，不包含密码，也不会自动上传。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("导出诊断包…") { app.exportDiagnostics() }
                    Link(app.sourceFingerprint == "未记录" ? "查看本版本源码" : "查看源码基线", destination: URL(string: "https://github.com/JahanHe/AutoLock/tree/\(app.sourceRevision.count == 40 ? app.sourceRevision : "master")")!)
                }
            }
            card("事件记录", icon: "list.bullet.rectangle") {
                HStack {
                    Text("最近 \(app.events.count) 条 · 本机持久保存").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制记录") {
                        let text = app.events.reversed().map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        app.feedback = "运行记录已复制，不包含密码。"; app.refreshStatus()
                    }
                    Button("清空本机记录") { app.clearDiagnosticLog() }
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                ForEach(app.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.date, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        Text(event.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                }
                }
                }.frame(height: 180)
            }
        }
    }

    private var devicePicker: some View {
        Picker("随身设备", selection: Binding(get: { app.ble.monitoredUUID?.uuidString ?? "" }, set: { if let id = UUID(uuidString: $0) { app.selectDevice(id) } })) {
                    Text("请选择设备").tag("")
                    if let selected = app.ble.monitoredUUID, app.ble.devices[selected] == nil {
                        Text("\(app.prefs.string(forKey: "deviceName") ?? "旧版保存的设备")（\(app.status.healthy ? "实时监测中" : "等待信号")）").tag(selected.uuidString)
                    }
                    ForEach(app.ble.devices.values.sorted { $0.rssi > $1.rssi }, id: \.uuid) { device in
                        Text("\(device.description) · \(device.rssi) dBm").tag(device.uuid.uuidString)
                    }
                }
    }

    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("选择设备", icon: "iphone") {
                devicePicker
                HStack {
                Button(app.scanningForDevices ? "停止扫描" : "扫描附近设备（15 秒）") {
                    if app.scanningForDevices { app.stopDeviceScan() } else { app.startDeviceScan() }
                }.accessibilityLabel(app.scanningForDevices ? "停止扫描" : "扫描附近设备")
                Button("重新连接") { app.reconnectDevice() }
                }
                Text("\(app.scanningForDevices ? "正在扫描" : "等待扫描或选择") · 系统扫描：\(app.ble.centralMgr?.isScanning == true ? "已开启" : "未开启")")
                    .font(.callout)
                Text("收到广播 \(app.ble.scanAdvertisementCount) 次 · 发现 \(app.ble.scanSeenDevices.count) 台 · 低于门槛或信号无效 \(app.ble.scanFilteredDevices.count) 台 · 列表 \(app.ble.devices.count) 台")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !app.scanningForDevices && !app.ble.devices.isEmpty {
                    SettingExplanation(text: "扫描结果保留到下一次扫描。列表数值是最后一次收到的信号，选中后请在状态总览确认实时信号正常。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if app.ble.devices.isEmpty {
                    Text(app.scanningForDevices ? "等待设备广播。找到设备后会出现在上方下拉列表。" : "当前没有扫描结果。点击扫描后展开上方列表；若收到广播但列表为空，可降低扫描显示门槛。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SettingExplanation(text: "优先选随身携带的 iPhone。Apple Watch 的系统解锁在 macOS 中单独开启，不需要把手表选为这里的监测设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("信号与连接", icon: "antenna.radiowaves.left.and.right") {
                option("passiveMode", "被动模式", "只接收设备广播，不主动建立连接。更少占用蓝牙连接，但手机广播间隔可能较长；离开锁定测试建议先用默认主动模式。")
                Divider()
                number("thresholdRSSI", "扫描显示门槛", "只影响新设备列表，不影响已选设备的监测。数值越接近 0，只显示越近的设备。", value: app.ble.thresholdRSSI, range: -95 ... -30, unit: "dBm")
                SettingExplanation(text: "信号强度不能准确换算成米数；墙体、口袋、手机朝向都会影响数值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("打开系统蓝牙权限设置") { app.openSystemSettings("Privacy_Bluetooth") }
        }
    }

    private var lockSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("离开自动锁定", icon: "lock.fill") {
                switchRow("启用自动锁定", "这是主要保护功能。无需保存登录密码，也不依赖 Apple Watch。", binding: Binding(get: { app.ble.lockRSSI != app.ble.LOCK_DISABLED }, set: app.setAutomaticLock))
                Divider()
                number("lockRSSI", "远离信号门槛", "平均信号低于此值时开始计时。若走很远才锁定，可适当提高这个数值。", value: app.ble.lockRSSI == app.ble.LOCK_DISABLED ? -80 : app.ble.lockRSSI, range: -99 ... -6, unit: "dBm")
                    .disabled(app.ble.lockRSSI == app.ble.LOCK_DISABLED)
                option("pauseAfterManualUnlock", "手动解锁后等待设备", "默认开启。设备不在附近时由手动、Touch ID 或 Apple Watch 解锁后，暂停自动锁定并继续扫描；直到所选设备再次提供有效信号才恢复。无效信号或重开蓝牙不结束暂停。关闭后恢复原来的自动锁定策略；重启应用或更换设备会开启新的监测周期。")
                number("lockDelay", "远离确认时间", "持续远离达到此时间才锁定，短暂信号波动会取消计时。", value: Int(app.ble.proximityTimeout), range: 1 ... 300, unit: "秒")

            }
            card("突然断连时", icon: "wifi.exclamationmark") {
                option("disconnectNotifications", "断连时发送通知", "先提醒请手动连接。通知、右侧状态和菜单栏都可以取消本次断连锁定；恢复有效信号后自动恢复保护。")
                Text(app.notificationPermission).font(.caption).foregroundStyle(.secondary)
                Button("打开系统通知设置") { if !app.isPreview { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) } }
                number("timeout", "无信号确认时间", "连续没有有效采样达到此时间，才视为断连并开始提醒。默认 6 秒；被动广播间隔较长时可适当增加。", value: Int(app.ble.signalTimeout), range: 1 ... 600, unit: "秒")
                option("lockOnSignalLoss", "断连提醒后自动锁定", "开启后再等待下方时间锁定；关闭后只提醒，不因断连锁定。它不会关闭信号持续变弱时的远离锁定。蓝牙无法区分手机在旁边还是已经离开。")
                number("signalLossLockDelay", "提醒后等待锁定", "默认 15 秒，从确认断连时开始。重新连接成功会取消倒计时；更改时间会按本次断连开始时间重新计算。", value: Int(app.ble.signalLossLockDelay), range: 1 ... 600, unit: "秒")
                Text(app.signalLossSummary).font(.callout).foregroundStyle(.orange)
                HStack {
                    Button("重新连接") { app.reconnectDevice() }
                    Button("本次不锁定") { app.ignoreCurrentSignalLoss() }.disabled(app.ble.signalLossID == nil || app.ble.signalLossIgnored)
                }
                SettingExplanation(text: "总等待时间＝无信号确认时间＋提醒后的等待时间。取消本次只持续到设备恢复信号，不会永久关闭自动保护。").font(.caption).foregroundStyle(.secondary)
            }
            card("锁定后的显示", icon: "display") {
                option("sleepDisplay", "锁定后关闭屏幕", "先锁定，再关闭屏幕。开启后更适合测试靠近唤醒与 Apple Watch 解锁。")
                Divider()
                option("screensaver", "锁定后启动屏幕保护程序", "始终先执行锁定，不再用屏保替代锁定；关闭屏幕开启时优先关闭屏幕。")
            }
            SettingExplanation(text: "手动点击“立即锁定”后，设备仍在身边时不会马上被本应用重新解锁；离开再回来才会触发靠近动作。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var returnSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("持续在附近", icon: "display") {
                option("keepDisplayAwake", "附近保持亮屏", "收到连续有效的附近信号时，防止空闲关屏。离开、超过 6 秒没有新信号、锁定或主动休眠后释放，不修改 macOS 的电源设置。与靠近唤醒分开控制。")
                Text("当前：\(app.displayAssertion != 0 ? "正在保持亮屏" : "未保持亮屏") · 附近门槛 \(app.keepAwakeThreshold) dBm。取亮屏和远离门槛中较近的一档，保证远离锁定优先。").font(.caption).foregroundStyle(.secondary)
                if let error = app.displayAssertionError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            card("靠近动作", icon: "sun.max") {
                switchRow("启用靠近动作", "只影响回来之后的行为，不会关闭离开自动锁定。", binding: Binding(get: { app.ble.unlockRSSI != app.ble.UNLOCK_DISABLED }, set: app.setReturnEnabled))
                option("wakeOnProximity", "第一步：靠近亮屏", "进入亮屏范围、失联后恢复，或从远离区间回到远离门槛加 5 dBm 时点亮屏幕。熄屏后再次收到达到密码门槛的近处信号也可亮屏，仍遵守手动锁定保护。不会因持续弱信号反复亮屏。深度睡眠、关机或合盖时无法保证扫描。")
                    .disabled(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
                number("wakeRSSI", "亮屏信号门槛", "例如 -90 dBm：收到这个强度或更强的信号，先亮屏。与密码解锁门槛至少间隔 5 dBm，调整时会自动保持顺序。", value: app.ble.wakeRSSI, range: -99 ... -6, unit: "dBm")
                    .disabled(!app.returnPolicy.wake)
                Divider()
                number("unlockRSSI", "第二步：密码解锁门槛", "例如 -60 dBm：再靠近到这个强度，才允许本应用尝试输入密码。亮屏本身不会提前满足此门槛。与远离门槛至少间隔 5 dBm。", value: app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? -60 : app.ble.unlockRSSI, range: -94 ... -1, unit: "dBm")
                    .disabled(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
            }
            card("解锁方式", icon: "applewatch") {
                option("watchCompatible", "Apple Watch 兼容模式（推荐）", "本应用只负责锁定和可选唤醒，绝不输入密码、按 Esc 或代替系统验证。请在系统设置中开启 Apple Watch 解锁。")
                SettingExplanation(text: "Apple Watch 可能在亮屏后由 macOS 直接解锁，不受上方密码解锁门槛限制。若要严格分两段解锁，需在系统设置中关闭 Apple Watch 自动解锁，再按需启用本应用密码输入。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开系统解锁设置") { app.openSystemSettings("watch") }
                Divider()
                switchRow("由本应用输入密码解锁", "默认关闭。启用前需要关闭 Apple Watch 兼容模式、保存登录密码，并允许辅助功能权限。蓝牙信号本身不验证持有人身份。", binding: Binding(get: { !app.prefs.bool(forKey: "wakeWithoutUnlocking") && !app.prefs.bool(forKey: "watchCompatible") }, set: { app.setOption("wakeWithoutUnlocking", !$0) }))
                    .disabled(app.prefs.bool(forKey: "watchCompatible") || app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
                HStack {
                    Button(app.hasPassword ? "更换登录密码…" : "保存登录密码…") { app.askPassword() }
                    Text(app.hasPassword ? "已保存到钥匙串" : "尚未保存").font(.caption).foregroundStyle(.secondary)
                }
                SettingExplanation(text: "Apple Watch 是否允许解锁由 macOS 决定。首次开机、重启或注销后仍需要手动输入密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("菜单栏显示", icon: "menubar.rectangle") {
                option("colorStatusIcon", "状态颜色融入锁图标", "绿色锁表示信号正常，红色锁表示信号异常。开启后不再单独显示圆点；关闭后可使用原来的图标与状态灯。")
                option("showStatusLight", "显示状态灯", "默认开启，紧贴锁图标显示设备监测状态。关闭后仍可在窗口查看完整状态。")
                    .disabled(app.prefs.bool(forKey: "colorStatusIcon"))
                option("showStatusIcon", "显示锁图标", "可以只留状态灯；图标和状态灯至少保留一个，确保能重新打开设置。")
                    .disabled(app.prefs.bool(forKey: "colorStatusIcon"))
                option("showStatusRSSI", "同时显示信号数值", "在菜单栏显示最近的平均 RSSI。没有有效信号时显示横线。")
                Divider()
                number("lightSize", "状态灯直径", "调整灯点大小。", value: app.prefs.integer(forKey: "lightSize"), range: 6 ... 12, unit: "点")
                    .disabled(app.prefs.bool(forKey: "colorStatusIcon"))
                number("lightGap", "图标与灯的间距", "默认 3 点，保持紧凑；可以按喜好调整。", value: app.prefs.integer(forKey: "lightGap"), range: 0 ... 8, unit: "点")
                    .disabled(app.prefs.bool(forKey: "colorStatusIcon"))
            }
            card("状态颜色", icon: "paintpalette") {
                colorPicker("healthyColor", "正常信号")
                colorPicker("unhealthyColor", "异常或失联")
                SettingExplanation(text: "默认绿灯表示正常、红灯表示异常。可换为适合自己的颜色；文字状态始终保留，避免只依赖颜色辨认。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复默认灯色与大小") {
                    app.prefs.set("green", forKey: "healthyColor"); app.prefs.set("red", forKey: "unhealthyColor")
                    app.prefs.set(8, forKey: "lightSize"); app.prefs.set(3, forKey: "lightGap"); app.refreshStatus()
                }
            }
        }
    }
    private func colorPicker(_ key: String, _ title: String) -> some View {
        Picker(title, selection: Binding(get: { app.prefs.string(forKey: key) ?? "green" }, set: { app.prefs.set($0, forKey: key); app.refreshStatus() })) {
            Text("绿色").tag("green"); Text("红色").tag("red"); Text("蓝色").tag("blue")
            Text("橙色").tag("orange"); Text("紫色").tag("purple"); Text("系统文字色").tag("label")
        }
    }

    private var extraSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            card("启动与窗口", icon: "power") {
                switchRow("登录时启动", "由 macOS 登录项管理；建议安装到“应用程序”后再开启。", binding: Binding(get: { app.loginEnabled }, set: app.setLogin))
                if app.loginNeedsApproval { Button("需要在系统登录项中批准") { app.openSystemSettings("login") } }
                Divider()
                option("showSettingsOnLaunch", "启动时显示设置窗口", "关闭后仅在菜单栏运行；点击菜单仍可随时打开此窗口。")
                Divider()
                option("showDockIcon", "在 Dock 显示应用图标", "开启时可从底部 Dock 打开窗口；关闭时从顶部菜单栏打开。监测功能持续运行。")
                option("hideDockWhenClosed", "关闭窗口后隐藏 Dock 图标", "默认开启。关闭设置窗口后仅保留顶部菜单栏；再次打开窗口时恢复 Dock 图标。关闭此选项可一直保留。")
                    .disabled(!app.prefs.bool(forKey: "showDockIcon"))
            }
            card("媒体播放", icon: "music.note") {
                option("pauseItunes", "离开锁定时暂停播放", "控制支持系统“正在播放”的应用。第三方播放器能否响应取决于其系统集成。")
                Divider()
                option("resumeMedia", "解锁后恢复播放", "仅恢复由本应用暂停的媒体，可以独立关闭；不会主动播放原本已暂停的内容。")
            }
            card("通知与更新", icon: "bell") {
                option("lockNotifications", "自动锁定时发送通知", "提醒锁定是由设备远离还是信号丢失触发。关闭不会影响锁定。")
                Divider()
                option("checkUpdates", "检查新版本", "定期检查本仓库的正式版本并提醒；不会自动下载或安装。")
            }
            card("权限检查", icon: "hand.raised") {
                Label(app.bluetoothState == .poweredOn ? "蓝牙已就绪" : "蓝牙需要检查", systemImage: app.bluetoothState == .poweredOn ? "checkmark.circle" : "exclamationmark.circle")
                Button("蓝牙权限设置") { app.openSystemSettings("Privacy_Bluetooth") }
                Divider()
                Label(app.accessibilityGranted ? "辅助功能已允许" : "辅助功能尚未允许", systemImage: app.accessibilityGranted ? "checkmark.circle" : "info.circle")
                Text("检测对象：\(app.isLocalTest ? "AutoLock测试（本地测试版）" : "AutoLock") · 当前运行进程")
                    .font(.caption).foregroundStyle(.secondary)
                if let checked = app.permissionCheckedAt { Text("最近检测：\(checked.formatted(date: .omitted, time: .standard))；每秒和回到窗口时自动复查。")
                        .font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("重新检测权限") { app.refreshPermissions(report: true); app.refreshStatus() }
                    Button("查看当前应用位置") { if !app.isPreview { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) } }
                }
                if !app.accessibilityGranted {
                    Text("以当前进程的实际授权为准。如果系统开关已经开启，请核对是否选中了 AutoLock测试而非旧安装版。临时签名更新也可能使旧授权失效；重新加入当前应用后再检测。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingExplanation(text: "辅助功能只用于本应用输入密码；离开锁定、靠近唤醒与 Apple Watch 模式不需要它。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("允许辅助功能…") { app.checkAccessibility() }
            }
        }
    }

    private var effectTests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("测试断连通知（不锁屏）") { app.testEffect("断连通知") }
            DisclosureGroup("展开模拟预览（不操作系统）", isExpanded: Binding(get: { app.showEffectPreview }, set: { app.showEffectPreview = $0; app.refreshStatus() })) {
                previewPanel.padding(.top, 14)
            }
            card("真实系统效果", icon: "play.circle") {
                Text("下列按钮会立即操作这台 Mac。锁屏测试前请确保你知道自己的登录密码。上方折叠区是模拟预览；右侧始终显示当前运行状态。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { testButton("立即锁定", "锁定"); testButton("关闭屏幕", "关闭屏幕"); testButton("唤醒屏幕", "唤醒屏幕") }
                HStack { testButton("启动屏保", "屏保"); testButton("测试通知", "通知") }
                HStack { testButton("暂停播放", "暂停播放"); testButton("恢复播放", "恢复播放") }
                Divider()
                Button("锁定，5 秒后测试靠近动作") { app.testEffect("锁定后测试靠近") }
                Text("设备必须仍在附近。使用 Apple Watch 模式时只唤醒，由系统决定是否解锁；关闭靠近动作或设备失联会取消后续动作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("建议验收顺序", icon: "checklist") {
                Text("1. 确认状态绿灯，点击“立即锁定”检查锁屏。\n\n2. 正常解锁，携带所选设备离开，等待远离确认或失联超时。\n\n3. 开启“锁定后关闭屏幕”和“靠近唤醒”，再次离开再回来。\n\n4. 保持 Apple Watch 兼容模式开启，佩戴已解锁的手表，观察系统解锁。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var liveStatusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("当前运行状态", systemImage: "waveform.path.ecg").font(.headline)
            if app.ble.signalLossID != nil || app.ble.waitingForDeviceAfterUnlock {
                if let timer = app.ble.signalLossTimer, timer.isValid {
                    lockCountdown("断连后锁定", timer: timer, total: app.ble.signalLossLockDelay)
                }
                Text(app.signalLossSummary).font(.callout).foregroundStyle(.orange)
                HStack {
                    Button("重新连接") { app.reconnectDevice() }
                    Button("本次不锁定") { app.ignoreCurrentSignalLoss() }.disabled(app.ble.signalLossID == nil || app.ble.signalLossIgnored || app.ble.waitingForDeviceAfterUnlock)
                }
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    liveScreen
                    signalGauge
                    signalChart
                    statusRow("离开保护", app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "已关闭" : (app.ble.waitingForDeviceAfterUnlock ? "暂停 · 等待设备" : "已开启"))
                    statusRow("系统锁定", app.screenLocked ? "已锁定" : "未锁定")
                    statusRow("监测方式", app.prefs.bool(forKey: "passiveMode") ? "被动广播" : "主动优先")
                    Divider()
                    if app.lockRequestAt != nil { statusRow("锁定请求", "等待系统确认") }
                    statusRow("保持亮屏", app.prefs.bool(forKey: "keepDisplayAwake") ? (app.displayAssertion != 0 ? "生效中" : "待命") : "已关闭")
                    if let error = app.displayAssertionError { Text(error).foregroundStyle(.red) }
                    if app.ble.lockRSSI != app.ble.LOCK_DISABLED, let timer = app.ble.proximityTimer, timer.isValid {
                        lockCountdown("远离倒计时", timer: timer, total: app.ble.proximityTimeout)
                    }
                    Divider()
                    statusRow("靠近亮屏", app.returnPolicy.wake ? "\(app.ble.wakeRSSI) dBm" : "已关闭")
                    Text(app.lastWakeResult).font(.caption).foregroundStyle(.secondary)
                    statusRow("密码解锁", passwordStatusText)
                    statusRow("辅助功能", app.accessibilityGranted ? "已授权" : "未授权")
                        .foregroundStyle(app.accessibilityGranted ? .green : .orange)
                    Button("重新检测权限") { app.refreshPermissions(report: true); app.refreshStatus() }
                    if let error = app.lastActionError {
                        Divider()
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Divider()
                    Button("查看运行记录") { app.expandedSettings.insert(.activity); page = .activity }
                }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var signalColor: Color {
        Color(nsColor: app.statusColor(app.prefs.string(forKey: app.status.healthy ? "healthyColor" : "unhealthyColor") ?? (app.status.healthy ? "green" : "red")))
    }

    private var liveScreen: some View {
        let screen = app.screenPresentation
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("这台 Mac")
                    Spacer()
                    Image(systemName: "lock.fill").foregroundStyle(signalColor)
                    Text(Date(), style: .time).monospacedDigit()
                }.font(.system(size: 10, weight: .medium)).padding(10)
                    .background(.black.opacity(screen.lit ? 0.12 : 0))
                Spacer(minLength: 8)
                Image(systemName: screen.symbol).font(.system(size: 32, weight: .light))
                Text(screen.title).font(.system(size: 15, weight: .medium)).padding(.top, 9)
                if app.lockRequestAt != nil {
                    Text("锁定请求已发出 · 等待系统确认").font(.system(size: 10)).padding(.top, 5)
                }
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Image(systemName: screen.lit ? "sun.max.fill" : "moon.fill")
                    Text(screen.lit ? (app.displayAssertion != 0 ? "保持亮屏中" : "屏幕已亮") : "屏幕已暗")
                }.font(.system(size: 10)).opacity(0.8).padding(.bottom, 12)
            }.foregroundStyle(screen.lit ? .white : Color(white: 0.62)).frame(height: 178)
                .frame(maxWidth: .infinity)
                .background {
                    if screen.lit {
                        LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.46), Color(red: 0.16, green: 0.48, blue: 0.57)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else { Color(white: 0.055) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .padding(5).background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.15)))
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 34, height: 12)
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 90, height: 4)
            HStack(spacing: 8) {
                Image(systemName: "iphone").font(.system(size: 22, weight: .light))
                Text(app.prefs.string(forKey: "deviceName") ?? "尚未选择设备").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: app.status.healthy ? "wave.3.right" : "wifi.slash").foregroundStyle(signalColor)
            }.padding(.top, 14)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("屏幕状态示意，\(screen.title)，\(app.screenLocked ? "系统已锁定" : "系统未锁定")，\(app.status.title)")
    }

    private var signalGauge: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(signalColor.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: app.status.healthy ? CGFloat(max(0, min(1, Double((app.lastRSSI ?? -100) + 100) / 70))) : 0)
                    .stroke(signalColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: app.lastRSSI)
                Image(systemName: app.status.healthy ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                    .font(.system(size: 19, weight: .light)).foregroundStyle(signalColor)
            }.frame(width: 48, height: 48).padding(3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.status.healthy ? app.lastRSSI.map { "\($0)" } ?? "—" : "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    + Text(" dBm").font(.system(size: 13)).foregroundColor(.secondary)
                Text(app.status.title).font(.system(size: 13, weight: .medium)).foregroundStyle(signalColor)
                HStack(spacing: 5) {
                    Circle().fill(signalColor).frame(width: 5, height: 5)
                    Text(app.lastSignalAt.map { "\(max(0, Int(Date().timeIntervalSince($0)))) 秒前更新" } ?? "等待设备信号")
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signalChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("信号趋势").fontWeight(.medium)
                Spacer()
                if app.ble.lockRSSI != app.ble.LOCK_DISABLED {
                    Text("远离 \(app.ble.lockRSSI)").foregroundStyle(.orange)
                }
            }
            Canvas { context, size in
                let now = Date()
                func y(_ rssi: Int) -> CGFloat { size.height * (1 - CGFloat(max(-127, min(0, rssi)) + 127) / 127) }
                for value in [-120, -80, -40] {
                    var grid = Path(); grid.move(to: CGPoint(x: 0, y: y(value))); grid.addLine(to: CGPoint(x: size.width, y: y(value)))
                    context.stroke(grid, with: .color(.secondary.opacity(0.13)), lineWidth: 1)
                    context.draw(Text("\(value)").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 1, y: y(value)-7), anchor: .leading)
                }
                if app.ble.lockRSSI != app.ble.LOCK_DISABLED {
                    var threshold = Path(); threshold.move(to: CGPoint(x: 0, y: y(app.ble.lockRSSI))); threshold.addLine(to: CGPoint(x: size.width, y: y(app.ble.lockRSSI)))
                    context.stroke(threshold, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                var curve = Path()
                var previous: Date?
                var latest: CGPoint?
                for sample in app.signalHistory {
                    let age = now.timeIntervalSince(sample.date)
                    guard (0...60).contains(age) else { continue }
                    guard let value = sample.rssi else { previous = nil; latest = nil; continue }
                    let point = CGPoint(x: size.width * (1 - age / 60), y: y(value))
                    if let last = previous, sample.date.timeIntervalSince(last) <= 6 { curve.addLine(to: point) }
                    else { curve.move(to: point) }
                    previous = sample.date; latest = point
                }
                context.stroke(curve, with: .color(signalColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let point = latest {
                    context.fill(Path(ellipseIn: CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6)), with: .color(signalColor))
                }
            }.frame(height: 72).accessibilityLabel("最近 60 秒的平均信号趋势，橙色虚线为远离锁定门槛")
            HStack {
                Text("60 秒前")
                Spacer()
                Text(app.signalHistory.isEmpty ? "等待采样" : "现在")
            }.foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(.vertical, 8)
    }

    private func lockCountdown(_ title: String, timer: Timer, total: TimeInterval) -> some View {
        let remaining = max(0, timer.fireDate.timeIntervalSinceNow)
        return VStack(spacing: 8) {
            statusRow(title, "\(Int(ceil(remaining))) 秒")
            ProgressView(value: min(1, remaining / max(1, total))).tint(.orange)
        }.foregroundStyle(.orange)
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordStatusText: String {
        if app.prefs.bool(forKey: "watchCompatible") { return "系统接管" }
        if !app.returnPolicy.typePassword { return "已关闭" }
        if app.manualLock { return "手动锁定保护" }
        if !app.status.healthy { return "等待信号" }
        if !app.ble.canUnlockAtCurrentSignal { return "等待靠近" }
        if !app.accessibilityGranted { return "等待授权" }
        if !app.hasPassword { return "未保存密码" }
        if !app.screenLocked { return "已解锁" }
        if app.passwordAttemptedForLock { return "等待系统确认" }
        return "等待锁屏界面"
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("效果预览", systemImage: "eye").font(.headline)
            Text("仅模拟画面，切换状态不会锁屏。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("模拟场景", selection: Binding(get: { app.previewScenario }, set: { app.previewScenario = $0; app.refreshStatus() })) {
                Text("亮屏").tag(3); Text("更近").tag(0); Text("远离").tag(1); Text("失联").tag(2)
            }.pickerStyle(.segmented)
            VStack(spacing: 0) {
                HStack(spacing: CGFloat(app.prefs.integer(forKey: "lightGap"))) {
                    Spacer()
                    if app.prefs.bool(forKey: "showStatusIcon") || app.prefs.bool(forKey: "colorStatusIcon") {
                        Image(systemName: "lock.fill").foregroundStyle(app.prefs.bool(forKey: "colorStatusIcon") ? Color(nsColor: app.statusColor(app.prefs.string(forKey: app.previewScenario == 2 ? "unhealthyColor" : "healthyColor") ?? "green")) : .white)
                    }
                    if app.prefs.bool(forKey: "showStatusLight") && !app.prefs.bool(forKey: "colorStatusIcon") {
                        Circle().fill(Color(nsColor: app.statusColor(app.prefs.string(forKey: app.previewScenario == 2 ? "unhealthyColor" : "healthyColor") ?? "green")))
                            .frame(width: CGFloat(app.prefs.integer(forKey: "lightSize")), height: CGFloat(app.prefs.integer(forKey: "lightSize")))
                    }
                    if app.prefs.bool(forKey: "showStatusRSSI") { Text(app.previewScenario == 2 ? "—" : "-52") }
                    Text("09:41").font(.system(size: 10)).padding(.leading, 5)
                }.font(.system(size: 11)).padding(10).background(.black.opacity(0.14))
                Spacer()
                Image(systemName: previewSymbol).font(.system(size: 36, weight: .light))
                Text(previewTitle).font(.headline).padding(.top, 10)
                Text(app.previewScenario == 0 ? "欢迎回来" : "AutoLock").font(.caption).opacity(0.65).padding(.top, 3)
                Spacer()
            }.foregroundStyle(.white).frame(height: 196)
                .background(LinearGradient(colors: [.init(red: 0.12, green: 0.22, blue: 0.34), .init(red: 0.18, green: 0.39, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
            Text(previewExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("正常：有效信号仍在更新", systemImage: app.prefs.bool(forKey: "colorStatusIcon") ? "lock.fill" : "circle.fill").foregroundStyle(Color(nsColor: app.statusColor(app.prefs.string(forKey: "healthyColor") ?? "green")))
                Label("异常：未选设备或信号异常", systemImage: app.prefs.bool(forKey: "colorStatusIcon") ? "lock.fill" : "circle.fill").foregroundStyle(Color(nsColor: app.statusColor(app.prefs.string(forKey: "unhealthyColor") ?? "red")))
            }.font(.caption)
            Text("灯色表示监测是否正常。远离但仍能收到信号时也可以是绿灯；是否锁定由距离和计时决定。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("原生 macOS 窗口\n支持浅色与深色外观").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 7)
    }
    private var previewSymbol: String {
        if app.previewScenario == 3 { return app.returnPolicy.wake ? "sun.max" : "moon" }
        if app.previewScenario != 0 { return app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "lock.open" : "lock.fill" }
        return app.returnPolicy.typePassword ? "lock.open" : (app.returnPolicy.wake ? "sun.max" : "moon")
    }
    private var previewTitle: String {
        if app.previewScenario == 3 { return app.returnPolicy.wake ? "先亮屏，等待更靠近" : "靠近亮屏已关闭" }
        if app.previewScenario != 0 { return app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "自动锁定已关闭" : "等待后锁定" }
        if app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED { return "靠近动作已关闭" }
        return app.returnPolicy.typePassword ? "尝试密码解锁" : (app.returnPolicy.wake ? "点亮屏幕" : "不主动唤醒")
    }
    private var previewExplanation: String {
        if app.previewScenario == 3 { return "从更远处重新达到 \(app.ble.wakeRSSI) dBm，\(app.returnPolicy.wake ? "先点亮屏幕" : "亮屏开关关闭，不点亮屏幕")。本应用密码输入仍需达到 \(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? -60 : app.ble.unlockRSSI) dBm，且相关开关和权限允许。Apple Watch 解锁由系统决定。" }
        if app.previewScenario == 2 { return "连续 \(Int(app.ble.signalTimeout)) 秒收不到信号后先提醒。\(app.ble.lockOnSignalLoss && app.ble.lockRSSI != app.ble.LOCK_DISABLED ? "再等待 \(Int(app.ble.signalLossLockDelay)) 秒锁定，可选择本次不锁定。" : "当前不因断连锁定。")" }
        if app.previewScenario == 1 { return "平均信号低于 \(app.ble.lockRSSI == app.ble.LOCK_DISABLED ? -80 : app.ble.lockRSSI) dBm 并持续 \(Int(app.ble.proximityTimeout)) 秒后，\(app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "因自动锁定关闭，不执行锁定。" : "锁定 Mac。")" }
        if app.prefs.bool(forKey: "watchCompatible") { return app.returnPolicy.wake ? "回来后只点亮屏幕。Apple Watch 解锁由系统接管，本应用不会输入密码。" : "本应用不唤醒、不输入密码。可手动唤醒屏幕，让系统处理 Apple Watch 解锁。" }
        return app.returnPolicy.typePassword ? "确认设备在附近且屏幕已锁定后，应用尝试输入保存在钥匙串中的密码。" : "本应用不输入密码，你可以使用系统解锁方式。"
    }

    private func testButton(_ title: String, _ effect: String) -> some View {
        Button(title) { app.testEffect(effect) }.controlSize(.regular)
    }
    private func option(_ key: String, _ title: String, _ detail: String) -> some View {
        switchRow(title, detail, binding: Binding(get: { app.prefs.bool(forKey: key) }, set: { app.setOption(key, $0) }))
    }
    private func switchRow(_ title: String, _ detail: String, binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).accessibilityHint(detail)
            }
            SettingExplanation(text: detail)
        }.padding(.vertical, 2)
    }
    private var integerFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0; formatter.usesGroupingSeparator = false
        return formatter
    }
    private func number(_ key: String, _ title: String, _ detail: String, value: Int, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                TextField(title, value: Binding(get: { value }, set: { app.setNumber(key, Double($0)) }), formatter: integerFormatter)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 62)
                    .accessibilityLabel(title)
                Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                Stepper(title, value: Binding(get: { Double(value) }, set: { app.setNumber(key, $0) }), in: range, step: 1)
                    .labelsHidden().frame(width: 18).accessibilityLabel(title)
            }
            SettingExplanation(text: detail)
        }.font(.system(size: 13)).padding(.vertical, 2)
    }
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 3)
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

// 使用原生滚动位置同步导航，点击导航才主动跳转，不打断用户连续滚动。
private struct SettingsPositionKey: PreferenceKey {
    static var defaultValue: [SettingsPage: CGFloat] = [:]
    static func reduce(value: inout [SettingsPage: CGFloat], nextValue: () -> [SettingsPage: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SettingExplanationKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var showSettingExplanations: Bool {
        get { self[SettingExplanationKey.self] }
        set { self[SettingExplanationKey.self] = newValue }
    }
}
private struct SettingExplanation: View {
    @Environment(\.showSettingExplanations) private var expanded
    let text: String
    var body: some View {
        if expanded { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
