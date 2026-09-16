import Cocoa
import SwiftUI
import CoreBluetooth
import ServiceManagement
import UserNotifications
import LocalAuthentication

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
        objectWillChange.send()
        let value = status
        monitorMenuItem?.title = value.title
        guard let button = statusItem.button else { return }
        let showLight = prefs.bool(forKey: "showStatusLight")
        let showIcon = prefs.bool(forKey: "showStatusIcon") || !showLight
        let diameter = CGFloat(max(6, min(12, prefs.integer(forKey: "lightSize"))))
        let gap = CGFloat(max(0, min(8, prefs.integer(forKey: "lightGap"))))
        let width: CGFloat = (showIcon ? 18 : 0) + (showLight ? diameter + (showIcon ? gap : 0) : 0) + 2
        let colorName = prefs.string(forKey: value.healthy ? "healthyColor" : "unhealthyColor") ?? (value.healthy ? "green" : "red")
        let color = statusColor(colorName)
        let icon = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            if showIcon {
                let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "自动锁定")!
                let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? symbol
                tinted.draw(in: NSRect(x: 1, y: 1, width: 17, height: 16))
            }
            if showLight {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: showIcon ? 19 + gap : 1, y: (18 - diameter) / 2, width: diameter, height: diameter)).fill()
            }
            return true
        }
        icon.isTemplate = !showLight
        button.image = icon
        button.title = prefs.bool(forKey: "showStatusRSSI") ? (lastRSSI.map { " \($0)" } ?? " —") : ""
        button.toolTip = "MacAutolock：\(value.title)\n\(value.detail)"
        button.setAccessibilityLabel("MacAutolock，\(value.title)")
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
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MacAutolock · 设置与测试"
            window.minSize = NSSize(width: 980, height: 690)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(app: self))
            if !isPreview { window.setFrameAutosaveName("MacAutolockSettings") }
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    func windowWillClose(_ notification: Notification) { stopDeviceScan() }

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
        scanTimer?.invalidate()
        scanningForDevices = false
        if !isPreview { ble.stopScanning() }
        refreshStatus()
    }

    func setOption(_ key: String, _ enabled: Bool) {
        prefs.set(enabled, forKey: key)
        if !prefs.bool(forKey: "showStatusIcon") && !prefs.bool(forKey: "showStatusLight") {
            prefs.set(true, forKey: key == "showStatusIcon" ? "showStatusLight" : "showStatusIcon")
        }
        if key == "passiveMode", !isPreview { ble.setPassiveMode(enabled) }
        if key == "lockNotifications", enabled, !isPreview {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                DispatchQueue.main.async { self.recordEvent(allowed ? "锁定通知权限已允许。" : "通知权限未允许，锁定功能仍正常工作。") }
            }
        }
        if key == "watchCompatible", enabled { prefs.set(true, forKey: "wakeWithoutUnlocking") }
        if key == "wakeWithoutUnlocking" || key == "watchCompatible" { unlockTimer?.invalidate() }
        if key == "wakeOnProximity", !enabled { wakeTimer?.invalidate() }
        feedback = "设置已保存，立即生效。"
        recordEvent("设置已更新：\(optionName(key))，\(enabled ? "开启" : "关闭")。")
        refreshStatus()
    }

    func optionName(_ key: String) -> String {
        ["passiveMode": "被动模式", "wakeWithoutUnlocking": "仅唤醒不输入密码", "watchCompatible": "Apple Watch 兼容模式",
         "wakeOnProximity": "靠近唤醒", "showStatusLight": "状态灯", "showStatusIcon": "锁图标", "showStatusRSSI": "菜单栏信号值",
         "sleepDisplay": "锁定后关屏", "screensaver": "锁定后屏保", "pauseItunes": "离开暂停媒体", "resumeMedia": "解锁后恢复媒体",
         "lockNotifications": "锁定通知", "checkUpdates": "版本检查", "showSettingsOnLaunch": "启动时显示窗口"][key] ?? "选项"
    }

    func setAutomaticLock(_ enabled: Bool) {
        if !enabled, ble.lockRSSI != ble.LOCK_DISABLED { prefs.set(ble.lockRSSI, forKey: "lastLockRSSI") }
        ble.lockRSSI = enabled ? (prefs.object(forKey: "lastLockRSSI") as? Int ?? -80) : ble.LOCK_DISABLED
        prefs.set(ble.lockRSSI, forKey: "lockRSSI")
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
        case "lockDelay":
            ble.proximityTimeout = Double(max(1, min(300, number)))
            prefs.set(ble.proximityTimeout, forKey: key)
            ble.proximityTimer?.invalidate(); ble.proximityTimer = nil
        case "timeout":
            ble.signalTimeout = Double(max(1, min(600, number)))
            prefs.set(ble.signalTimeout, forKey: key)
            if !isPreview { ble.resetSignalTimer() }
        case "thresholdRSSI":
            ble.thresholdRSSI = max(-95, min(-30, number)); prefs.set(ble.thresholdRSSI, forKey: key)
        case "lightSize": prefs.set(max(6, min(12, number)), forKey: key)
        case "lightGap": prefs.set(max(0, min(8, number)), forKey: key)
        default: return
        }
        refreshStatus()
    }

    func refreshPermissions() {
        guard !isPreview else { accessibilityGranted = true; return }
        accessibilityGranted = AXIsProcessTrusted()
        screenLocked = isScreenLocked()
        if let requested = lockRequestAt {
            if screenLocked {
                recordEvent("系统已确认屏幕锁定。")
                lastActionError = nil
                lockRequestAt = nil
            } else if Date().timeIntervalSince(requested) > 3 {
                lastActionError = "锁定请求发出后未观察到锁定状态；请使用立即锁定检查当前系统。"
                recordEvent(lastActionError!)
                lockRequestAt = nil
            }
        }
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
                                   String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
                                   String(kSecReturnAttributes): true,
                                   String(kSecUseAuthenticationContext): context]
        hasPassword = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setLogin(_ enabled: Bool) {
        if isPreview { loginEnabled = enabled; refreshStatus(); return }
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
        case "通知":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                if allowed {
                    let content = UNMutableNotificationContent()
                    content.title = "MacAutolock · 测试通知"; content.body = "通知功能可用。这次测试没有锁定屏幕。"
                    UNUserNotificationCenter.current().add(.init(identifier: "test", content: content, trigger: nil))
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
        let oldLock = ble.lockRSSI, oldUnlock = ble.unlockRSSI
        let oldTimeout = ble.signalTimeout, oldDelay = ble.proximityTimeout
        defer {
            prefs.setPersistentDomain(saved, forName: previewSuite)
            ble.lockRSSI = oldLock; ble.unlockRSSI = oldUnlock
            ble.signalTimeout = oldTimeout; ble.proximityTimeout = oldDelay
            events = savedEvents; previewScenario = 0
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
        for effect in ["锁定", "关闭屏幕", "唤醒屏幕", "屏保", "暂停播放", "恢复播放", "通知", "锁定后测试靠近"] {
            testEffect(effect)
            check(lockRequestAt == nil && unlockTimer == nil && !testingUnlock, "预览按钮不得发出系统请求")
        }
        check(fetchPassword() == nil, "预览不得读取密码")
        return count
    }

    func configurePreviewCapture() {
        guard isPreview else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--capture"), args.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checks = verifyPreviewSettings()
        let report: [String: Any] = ["设置检查通过": checks, "隔离预览": isPreview,
                                    "系统版本": ProcessInfo.processInfo.operatingSystemVersionString]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("预览检查.json"))
        }
        // ponytail: 复用真实设置窗口截图，演示模式隔离所有系统操作，无需维护第二套界面。
        let scenes: [(String, SettingsPage)] = [("浅色", .overview), ("深色", .overview), ("设备", .device),
            ("离开锁定", .lock), ("靠近与解锁", .returning), ("菜单栏外观", .appearance), ("其他设置", .extras), ("效果测试", .tests), ("运行记录", .activity), ("失联", .overview)]
        for (offset, scene) in scenes.enumerated() {
            let (name, page) = scene
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset * 3 + 2)) {
                self.settingsWindow?.appearance = NSAppearance(named: offset == 1 ? .darkAqua : .aqua)
                self.settingsPage = page
                if name == "失联" { self.lastRSSI = nil; self.lastSignalAt = nil; self.previewScenario = 2 }
                self.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let view = self.settingsWindow?.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("设置窗口-\(name).png"))
                    if let data = self.statusItem.button?.image?.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: data) {
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("菜单灯-\(name).png"))
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(scenes.count * 3 + 2)) { NSApp.terminate(nil) }
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
    var subtitle: String {
        switch self {
        case .overview: return "离开安心锁定，回来按你的方式继续。"
        case .device: return "选择随身设备，让信号告诉 Mac 你是否在附近。"
        case .lock: return "优先守住离开后的屏幕锁定。"
        case .returning: return "唤醒与密码解锁分别控制，兼容系统 Apple Watch 解锁。"
        case .activity: return "每一步判断和动作都留下可见记录，最近 100 条保留在本次运行中。"
        case .appearance: return "状态灯的位置、颜色和信息密度，由你选择。"
        case .extras: return "启动、权限和播放行为，在这里统一管理。"
        case .tests: return "先看模拟预览，再按需测试真实系统效果。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppDelegate
    private var page: SettingsPage {
        get { app.settingsPage }
        nonmutating set { app.settingsPage = newValue; app.refreshStatus() }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 27)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacAutolock").font(.headline)
                        Text("蓝牙自动锁定").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 20)
                VStack(spacing: 6) {
                    ForEach(SettingsPage.allCases, id: \.self) { item in
                        Button { page = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .foregroundStyle(page == item ? Color.white : Color.primary)
                                .background(page == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label(app.isPreview ? "演示预览" : "设置即时保存", systemImage: app.isPreview ? "eye" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("版本 1.13.0 · 中文测试版").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).frame(width: 166).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.rawValue).font(.system(size: 25, weight: .bold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if app.isPreview {
                            Label("演示模式：所有按钮仅预览，不操作你的 Mac。", systemImage: "eye")
                                .font(.callout).foregroundStyle(.blue)
                        }
                        pageContent
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text(app.feedback).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 452).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            previewPanel.frame(width: 242).padding(20).background(Color(nsColor: .controlBackgroundColor))
        }.frame(minHeight: 620).environment(\.locale, Locale(identifier: "zh_Hans_CN"))
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
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
        VStack(alignment: .leading, spacing: 18) {
            card("实时监测", icon: "dot.radiowaves.left.and.right") {
                HStack(spacing: 10) {
                    Circle().fill(Color(nsColor: app.statusColor(app.prefs.string(forKey: app.status.healthy ? "healthyColor" : "unhealthyColor") ?? "green"))).frame(width: 11, height: 11)
                    Text(app.status.title).font(.headline)
                    Spacer()
                    if let value = app.lastRSSI { Text("\(value) dBm").monospacedDigit().foregroundStyle(.secondary) }
                }
                Text(app.status.detail).font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("随身设备：\(app.prefs.string(forKey: "deviceName") ?? "尚未选择")").font(.callout)
                Text(app.lastRSSI == nil ? "距离判断：尚无有效信号" : (app.ble.presence ? "距离判断：在附近" : "距离判断：已远离")).font(.callout).foregroundStyle(.secondary)
                Text("采样方式：\(app.monitorModeDescription)").font(.caption).foregroundStyle(.secondary)
                Text(app.lastSignalAt.map { "最近有效信号：\(max(0, Int(Date().timeIntervalSince($0)))) 秒前" } ?? "最近有效信号：尚未收到").font(.caption).foregroundStyle(.secondary)
                Button("选择或更换设备") { page = .device }
            }
            card("运行状态与下一步", icon: "waveform.path.ecg") {
                Text(runtimeSummary).font(.system(size: 13, weight: .medium))
                Text("屏幕状态：\(app.isPreview ? "演示画面，不读取实际锁屏" : (app.screenLocked ? "已锁定" : "未锁定"))")
                    .font(.callout).foregroundStyle(.secondary)
                if let timer = app.ble.proximityTimer, timer.isValid {
                    Text("远离锁定倒计时：\(max(0, Int(ceil(timer.fireDate.timeIntervalSinceNow)))) 秒")
                        .font(.callout).monospacedDigit().foregroundStyle(.orange)
                }
                if let timer = app.ble.signalTimer, timer.isValid {
                    Text("若没有新信号：\(max(0, Int(ceil(timer.fireDate.timeIntervalSinceNow)))) 秒后触发失联判断")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let error = app.lastActionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
                if let event = app.events.first { Text("最近事件：\(event.message)").font(.caption).foregroundStyle(.secondary) }
                Button("查看完整运行记录") { page = .activity }
            }
            card("保护与返回", icon: "lock.shield") {
                switchRow("离开自动锁定", "信号变弱持续一段时间，或信号丢失达到超时后，锁定屏幕。", binding: Binding(get: { app.ble.lockRSSI != app.ble.LOCK_DISABLED }, set: app.setAutomaticLock))
                Divider()
                switchRow("靠近后执行动作", "与离开锁定独立；关闭后，回来时由你手动唤醒和解锁。", binding: Binding(get: { app.ble.unlockRSSI != app.ble.UNLOCK_DISABLED }, set: app.setReturnEnabled))
                Text(app.prefs.bool(forKey: "watchCompatible") ? "当前：Apple Watch 兼容模式，应用不输入密码。" : (app.returnPolicy.typePassword ? "当前：允许应用尝试输入登录密码。" : "当前：应用不会输入登录密码。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("调整唤醒与解锁") { page = .returning }
            }
            card("开始测试", icon: "checkmark.seal") {
                Text("先选设备并确认绿灯，再带手机离开。回来后可仅唤醒屏幕，由 Apple Watch 或你自己完成解锁。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("进入效果测试") { page = .tests }
            }
        }
    }

    private var runtimeSummary: String {
        if app.ble.monitoredUUID == nil { return "等待选择设备，尚未开始自动锁定。" }
        if app.ble.lockRSSI == app.ble.LOCK_DISABLED { return "自动锁定已关闭；设备监测仍在运行。" }
        if app.lockRequestAt != nil { return "正在请求系统锁定，等待确认。" }
        if app.lastActionError != nil { return "最近操作存在异常，请查看下方原因。" }
        if app.systemSleep { return "系统休眠中，等待恢复扫描。" }
        if app.screenLocked { return "屏幕已锁定，继续监测返回条件。" }
        if app.ble.proximityTimer?.isValid == true { return "信号持续偏弱，正在确认是否离开。" }
        if !app.status.healthy { return "监测信号异常，失联锁定计时仍有效。" }
        return "自动锁定正常待命，等待远离或失联条件。"
    }

    private var activitySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("当前运行情况", icon: "waveform.path.ecg") {
                Text(runtimeSummary).font(.headline)
                Text("设备连接：\(app.status.title) · \(app.monitorModeDescription)").font(.callout)
                Text("原始信号：\(app.ble.lastRawRSSI.map { "\($0) dBm" } ?? "暂无")；平均信号：\(app.lastRSSI.map { "\($0) dBm" } ?? "暂无")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("远离门槛：\(app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "自动锁定已关闭" : "\(app.ble.lockRSSI) dBm")；靠近门槛：\(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? "动作已关闭" : "\(app.ble.unlockRSSI) dBm")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("辅助功能：\(app.accessibilityGranted ? "已允许" : "未允许")；密码：\(app.hasPassword ? "已保存" : "未保存")；本应用密码输入：\(app.returnPolicy.typePassword ? "已开启" : "已关闭")")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = app.lastActionError { Text(error).font(.callout).foregroundStyle(.red) }
            }
            card("事件记录", icon: "list.bullet.rectangle") {
                HStack {
                    Text("最近 \(app.events.count) 条 · 退出后清空").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制记录") {
                        let text = app.events.reversed().map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        app.feedback = "运行记录已复制，不包含密码。"; app.refreshStatus()
                    }
                    Button("清空") { app.events.removeAll(); app.refreshStatus() }
                }
                ForEach(app.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.date, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        Text(event.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                }
            }
        }
    }

    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("选择设备", icon: "iphone") {
                Picker("随身设备", selection: Binding(get: { app.ble.monitoredUUID?.uuidString ?? "" }, set: { if let id = UUID(uuidString: $0) { app.selectDevice(id) } })) {
                    Text("请选择设备").tag("")
                    if let selected = app.ble.monitoredUUID, app.ble.devices[selected] == nil {
                        Text(app.prefs.string(forKey: "deviceName") ?? "已保存的设备").tag(selected.uuidString)
                    }
                    ForEach(app.ble.devices.values.sorted { $0.rssi > $1.rssi }, id: \.uuid) { device in
                        Text("\(device.description) · \(device.rssi) dBm").tag(device.uuid.uuidString)
                    }
                }
                Button(app.scanningForDevices ? "停止扫描" : "扫描附近设备（15 秒）") {
                    if app.scanningForDevices { app.stopDeviceScan() } else { app.startDeviceScan() }
                }
                Text("优先选随身携带的 iPhone。Apple Watch 的系统解锁在 macOS 中单独开启，不需要把手表选为这里的监测设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("信号与连接", icon: "antenna.radiowaves.left.and.right") {
                option("passiveMode", "被动模式", "只接收设备广播，不主动建立连接。更少占用蓝牙连接，但手机广播间隔可能较长；离开锁定测试建议先用默认主动模式。")
                Divider()
                number("thresholdRSSI", "扫描显示门槛", "只影响新设备列表，不影响已选设备的监测。数值越接近 0，只显示越近的设备。", value: app.ble.thresholdRSSI, range: -95 ... -30, unit: "dBm")
                Text("信号强度不能准确换算成米数；墙体、口袋、手机朝向都会影响数值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("打开系统蓝牙权限设置") { app.openSystemSettings("Privacy_Bluetooth") }
        }
    }

    private var lockSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("离开自动锁定", icon: "lock.fill") {
                switchRow("启用自动锁定", "这是主要保护功能。无需保存登录密码，也不依赖 Apple Watch。", binding: Binding(get: { app.ble.lockRSSI != app.ble.LOCK_DISABLED }, set: app.setAutomaticLock))
                Divider()
                number("lockRSSI", "远离信号门槛", "平均信号低于此值时开始计时。若走很远才锁定，可适当提高这个数值。", value: app.ble.lockRSSI == app.ble.LOCK_DISABLED ? -80 : app.ble.lockRSSI, range: -99 ... -6, unit: "dBm")
                    .disabled(app.ble.lockRSSI == app.ble.LOCK_DISABLED)
                number("lockDelay", "远离确认时间", "持续远离达到此时间才锁定，短暂信号波动会取消计时。", value: Int(app.ble.proximityTimeout), range: 1 ... 300, unit: "秒")
                number("timeout", "信号丢失后锁定", "设备不再发送有效信号，或 Mac 蓝牙被关闭时的兜底计时。被动模式可适当调长以减少误锁。", value: Int(app.ble.signalTimeout), range: 1 ... 600, unit: "秒")
            }
            card("锁定后的显示", icon: "display") {
                option("sleepDisplay", "锁定后关闭屏幕", "先锁定，再关闭屏幕。开启后更适合测试靠近唤醒与 Apple Watch 解锁。")
                Divider()
                option("screensaver", "锁定后启动屏幕保护程序", "始终先执行锁定，不再用屏保替代锁定；关闭屏幕开启时优先关闭屏幕。")
            }
            Text("手动点击“立即锁定”后，设备仍在身边时不会马上被本应用重新解锁；离开再回来才会触发靠近动作。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var returnSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("靠近动作", icon: "sun.max") {
                switchRow("启用靠近动作", "只影响回来之后的行为，不会关闭离开自动锁定。", binding: Binding(get: { app.ble.unlockRSSI != app.ble.UNLOCK_DISABLED }, set: app.setReturnEnabled))
                number("unlockRSSI", "靠近信号门槛", "信号达到此值才认定回来。与远离门槛至少保留 5 dBm 间隔，避免反复切换。", value: app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED ? -60 : app.ble.unlockRSSI, range: -94 ... -1, unit: "dBm")
                    .disabled(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
                option("wakeOnProximity", "靠近唤醒屏幕", "检测到重新靠近时点亮屏幕。Mac 深度睡眠、关机或合盖时，应用无法保证继续接收蓝牙信号。")
                    .disabled(app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
            }
            card("解锁方式", icon: "applewatch") {
                option("watchCompatible", "Apple Watch 兼容模式（推荐）", "本应用只负责锁定和可选唤醒，绝不输入密码、按 Esc 或代替系统验证。请在系统设置中开启 Apple Watch 解锁。")
                Button("打开系统解锁设置") { app.openSystemSettings("watch") }
                Divider()
                switchRow("由本应用输入密码解锁", "默认关闭。启用前需要关闭 Apple Watch 兼容模式、保存登录密码，并允许辅助功能权限。蓝牙信号本身不验证持有人身份。", binding: Binding(get: { !app.prefs.bool(forKey: "wakeWithoutUnlocking") && !app.prefs.bool(forKey: "watchCompatible") }, set: { app.setOption("wakeWithoutUnlocking", !$0) }))
                    .disabled(app.prefs.bool(forKey: "watchCompatible") || app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED)
                HStack {
                    Button(app.hasPassword ? "更换登录密码…" : "保存登录密码…") { app.askPassword() }
                    Text(app.hasPassword ? "已保存到钥匙串" : "尚未保存").font(.caption).foregroundStyle(.secondary)
                }
                Text("Apple Watch 是否允许解锁由 macOS 决定。首次开机、重启或注销后仍需要手动输入密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("菜单栏显示", icon: "menubar.rectangle") {
                option("showStatusLight", "显示状态灯", "默认开启，紧贴锁图标显示设备监测状态。关闭后仍可在窗口查看完整状态。")
                option("showStatusIcon", "显示锁图标", "可以只留状态灯；图标和状态灯至少保留一个，确保能重新打开设置。")
                option("showStatusRSSI", "同时显示信号数值", "在菜单栏显示最近的平均 RSSI。没有有效信号时显示横线。")
                Divider()
                number("lightSize", "状态灯直径", "调整灯点大小。", value: app.prefs.integer(forKey: "lightSize"), range: 6 ... 12, unit: "点")
                number("lightGap", "图标与灯的间距", "默认 3 点，保持紧凑；可以按喜好调整。", value: app.prefs.integer(forKey: "lightGap"), range: 0 ... 8, unit: "点")
            }
            card("状态颜色", icon: "paintpalette") {
                colorPicker("healthyColor", "正常信号")
                colorPicker("unhealthyColor", "异常或失联")
                Text("默认绿灯表示正常、红灯表示异常。可换为适合自己的颜色；文字状态始终保留，避免只依赖颜色辨认。")
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
        VStack(alignment: .leading, spacing: 18) {
            card("启动与窗口", icon: "power") {
                switchRow("登录时启动", "由 macOS 登录项管理；建议安装到“应用程序”后再开启。", binding: Binding(get: { app.loginEnabled }, set: app.setLogin))
                if app.loginNeedsApproval { Button("需要在系统登录项中批准") { app.openSystemSettings("login") } }
                Divider()
                option("showSettingsOnLaunch", "启动时显示设置窗口", "关闭后仅在菜单栏运行；点击菜单仍可随时打开此窗口。")
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
                Text("辅助功能只用于本应用输入密码；离开锁定、靠近唤醒与 Apple Watch 模式不需要它。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("允许辅助功能…") { app.checkAccessibility() }
            }
        }
    }

    private var effectTests: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("真实系统效果", icon: "play.circle") {
                Text("下列按钮会立即操作这台 Mac。锁屏测试前请确保你知道自己的登录密码。右侧预览不会操作系统。")
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

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("效果预览", systemImage: "eye").font(.headline)
            Text("仅模拟画面，切换状态不会锁屏。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("模拟场景", selection: Binding(get: { app.previewScenario }, set: { app.previewScenario = $0; app.refreshStatus() })) {
                Text("靠近").tag(0); Text("远离").tag(1); Text("失联").tag(2)
            }.pickerStyle(.segmented)
            VStack(spacing: 0) {
                HStack(spacing: CGFloat(app.prefs.integer(forKey: "lightGap"))) {
                    Spacer()
                    if app.prefs.bool(forKey: "showStatusIcon") { Image(systemName: "lock.fill") }
                    if app.prefs.bool(forKey: "showStatusLight") {
                        Circle().fill(Color(nsColor: app.statusColor(app.prefs.string(forKey: app.previewScenario == 2 ? "unhealthyColor" : "healthyColor") ?? "green")))
                            .frame(width: CGFloat(app.prefs.integer(forKey: "lightSize")), height: CGFloat(app.prefs.integer(forKey: "lightSize")))
                    }
                    if app.prefs.bool(forKey: "showStatusRSSI") { Text(app.previewScenario == 2 ? "—" : "-52") }
                    Text("09:41").font(.system(size: 10)).padding(.leading, 5)
                }.font(.system(size: 11)).padding(10).background(.black.opacity(0.14))
                Spacer()
                Image(systemName: previewSymbol).font(.system(size: 36, weight: .light))
                Text(previewTitle).font(.headline).padding(.top, 10)
                Text(app.previewScenario == 0 ? "欢迎回来" : "MacAutolock").font(.caption).opacity(0.65).padding(.top, 3)
                Spacer()
            }.foregroundStyle(.white).frame(height: 196)
                .background(LinearGradient(colors: [.init(red: 0.12, green: 0.22, blue: 0.34), .init(red: 0.18, green: 0.39, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
            Text(previewExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("正常：有效信号仍在更新", systemImage: "circle.fill").foregroundStyle(Color(nsColor: app.statusColor(app.prefs.string(forKey: "healthyColor") ?? "green")))
                Label("异常：未选设备或信号异常", systemImage: "circle.fill").foregroundStyle(Color(nsColor: app.statusColor(app.prefs.string(forKey: "unhealthyColor") ?? "red")))
            }.font(.caption)
            Text("灯色表示监测是否正常。远离但仍能收到信号时也可以是绿灯；是否锁定由距离和计时决定。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("原生 macOS 窗口\n支持浅色与深色外观").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 7)
    }
    private var previewSymbol: String {
        if app.previewScenario != 0 { return app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "lock.open" : "lock.fill" }
        return app.returnPolicy.typePassword ? "lock.open" : (app.returnPolicy.wake ? "sun.max" : "moon")
    }
    private var previewTitle: String {
        if app.previewScenario != 0 { return app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "自动锁定已关闭" : "等待后锁定" }
        if app.ble.unlockRSSI == app.ble.UNLOCK_DISABLED { return "靠近动作已关闭" }
        return app.returnPolicy.typePassword ? "尝试密码解锁" : (app.returnPolicy.wake ? "点亮屏幕" : "不主动唤醒")
    }
    private var previewExplanation: String {
        if app.previewScenario == 2 { return "连续 \(Int(app.ble.signalTimeout)) 秒收不到信号后，\(app.ble.lockRSSI == app.ble.LOCK_DISABLED ? "自动锁定已关闭，只显示异常状态。" : "执行锁定，菜单灯显示异常颜色。")" }
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
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).padding(.vertical, 3).accessibilityHint(detail)
    }
    private var integerFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0; formatter.usesGroupingSeparator = false
        return formatter
    }
    private func number(_ key: String, _ title: String, _ detail: String, value: Int, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                TextField(title, value: Binding(get: { value }, set: { app.setNumber(key, Double($0)) }), formatter: integerFormatter)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:  66)
                    .accessibilityLabel(title)
                Text(unit).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { app.setNumber(key, $0) }), in: range, step: 1)
                .accessibilityLabel(title).accessibilityValue("\(value) \(unit)")
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13)).padding(.vertical, 4)
    }
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary)
            content()
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}
