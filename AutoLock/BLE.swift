import Foundation
import CoreBluetooth
import Accelerate

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    
    override var description: String {
        get {
            if macAddr == nil || blName == nil {
                if let info = getLEDeviceInfoFromUUID(uuid.description) {
                    blName = info.name
                    macAddr = info.macAddr
                }
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
                if let name = blName {
                    // 名称只有 iPhone 或 iPad 时，继续尝试获取具体机型。
                    if name != "iPhone" && name != "iPad" {
                        return name
                    }
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // 解析 iBeacon 信标。
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // 优先显示比 UUID 更易识别的地址。
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func reachedWakeRange()
    func signalLossChanged()
    func bluetoothStateChanged(_ state: CBManagerState)
    func monitorEvent(_ message: String)
    func bluetoothPowerWarn()
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var scanAdvertisementCount = 0
    var scanSeenDevices = Set<UUID>()
    var scanFilteredDevices = Set<UUID>()
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var signalLossTimer: Timer?
    var signalLossID: UUID?
    var signalLossBeganAt: Date?
    var signalLossIgnored = false
    var lockOnSignalLoss = true
    var signalLossLockDelay = 15.0
    var pauseAfterManualUnlock = true
    private(set) var waitingForDeviceAfterUnlock = false
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    var wakeRSSI = -90
    var withinWakeRange = false
    private var wakeReportedSinceDeparture = false
    private var wakeOnNextNearSample = false
    var canUnlockAtCurrentSignal: Bool {
        unlockRSSI != UNLOCK_DISABLED && lastRawRSSI.map { ConnectionStatus.validRSSI($0) && $0 >= unlockRSSI } == true
    }
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt = 0.0
    var lastRawRSSI: Int?
    var lastSampleAt: Date?
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestRSSIs: [Double] = []
    var latestN: Int = 5
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil

    func scanForPeripherals() {
        guard let centralMgr = centralMgr, centralMgr.state == .poweredOn, !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func startScanning() {
        for device in devices.values { device.scanTimer?.invalidate() }
        devices = devices.filter { $0.key == monitoredUUID }
        scanAdvertisementCount = 0
        scanSeenDevices.removeAll()
        scanFilteredDevices.removeAll()
        scanMode = true
        // 用户点重新扫描时重建扫描请求，避免一直复用没有返回广播的旧请求。
        centralMgr?.stopScan()
        scanForPeripherals()
        delegate?.monitorEvent("设备扫描开始：门槛 \(thresholdRSSI) dBm；系统扫描状态：\(centralMgr?.isScanning == true ? "已开启" : "未开启")。")
    }

    func stopScanning() {
        scanMode = false
        // 扫描结果保留到下一次扫描；列表清理不能妨碍用户选择，也不能取消监测设备的计时。
        for device in devices.values {
            device.scanTimer?.invalidate()
            if let peripheral = device.peripheral, peripheral != monitoredPeripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
        }
        if activeModeTimer != nil {
            centralMgr?.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        delegate?.monitorEvent(mode ? "已选择被动监听，只接收广播。" : "已选择主动优先模式，连接失败时会监听广播。")
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            if let p = monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        clearSignalLoss()
        waitingForDeviceAfterUnlock = false
        wakeReportedSinceDeparture = false
        wakeOnNextNearSample = false
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        lastRawRSSI = nil
        lastSampleAt = nil
        withinWakeRange = false
        delegate?.monitorEvent("已开始监测设备，等待有效信号；失联锁定计时已启用。")
        proximityTimer?.invalidate()
        proximityTimer = nil
        resetSignalTimer()
        presence = true
        latestRSSIs.removeAll()
        lastReadAt = 0
        delegate?.updateRSSI(rssi: nil, active: false)
        connectionTimer?.invalidate()
        monitoredPeripheral = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        scanForPeripherals()
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        guard monitoredUUID != nil else { return }
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false) { [weak self] _ in
            self?.signalLost()
        }
        RunLoop.main.add(signalTimer!, forMode: .common)
    }

    func rearmAfterUnlock() {
        guard monitoredUUID != nil else { return }
        let departureThreshold = lockRSSI == LOCK_DISABLED ? -80 : lockRSSI
        let nearby = (centralMgr?.state ?? .poweredOn) == .poweredOn && presence && lastRawRSSI.map { ConnectionStatus.validRSSI($0) && $0 >= departureThreshold } == true
            && lastSampleAt.map { Date().timeIntervalSince($0) < signalTimeout } == true
        guard !nearby else { return }
        waitingForDeviceAfterUnlock = pauseAfterManualUnlock
        if !signalLossIgnored && !waitingForDeviceAfterUnlock { clearSignalLoss() }
        presence = !waitingForDeviceAfterUnlock
        latestRSSIs.removeAll()
        proximityTimer?.invalidate()
        proximityTimer = nil
        configureSignalLossLock()
        resetSignalTimer()
        delegate?.monitorEvent(waitingForDeviceAfterUnlock
            ? "设备不在附近时屏幕已解锁：暂停自动锁定，等待所选设备下一次有效信号；扫描继续。"
            : "屏幕重新解锁，按设置重新确认距离并启动失联计时。")
        delegate?.signalLossChanged()
    }

    func setPauseAfterManualUnlock(_ enabled: Bool) {
        pauseAfterManualUnlock = enabled
        if !enabled && waitingForDeviceAfterUnlock {
            waitingForDeviceAfterUnlock = false
            rearmAfterUnlock()
        }
    }

    func signalLost() {
        guard signalLossID == nil else { return }
        signalLossID = UUID()
        signalLossBeganAt = Date()
        print("设备信号已丢失")
        lastRawRSSI = nil
        withinWakeRange = false
        delegate?.monitorEvent("连续 \(Int(signalTimeout)) 秒没有有效信号，已触发失联判断。")
        proximityTimer?.invalidate()
        proximityTimer = nil
        latestRSSIs.removeAll()
        delegate?.updateRSSI(rssi: nil, active: false)
        presence = false
        configureSignalLossLock()
        delegate?.signalLossChanged()
    }

    func configureSignalLossLock() {
        signalLossTimer?.invalidate()
        signalLossTimer = nil
        guard let started = signalLossBeganAt, lockOnSignalLoss, !signalLossIgnored,
              !waitingForDeviceAfterUnlock, lockRSSI != LOCK_DISABLED else { return }
        let episode = signalLossID
        let remaining = max(0.1, started.addingTimeInterval(signalLossLockDelay).timeIntervalSinceNow)
        signalLossTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self = self, self.signalLossID == episode, self.lockOnSignalLoss,
                  !self.signalLossIgnored, !self.waitingForDeviceAfterUnlock, self.lockRSSI != self.LOCK_DISABLED else { return }
            self.signalLossTimer = nil
            self.delegate?.monitorEvent("断连宽限时间已到，按当前设置请求锁定。")
            self.delegate?.updatePresence(presence: false, reason: "lost")
        }
        RunLoop.main.add(signalLossTimer!, forMode: .common)
    }

    func ignoreCurrentSignalLoss() {
        guard signalLossID != nil else { return }
        signalLossIgnored = true
        signalLossTimer?.invalidate()
        signalLossTimer = nil
        delegate?.monitorEvent("用户取消本次断连锁定；恢复有效信号后自动恢复保护，不改变远离锁定设置。")
        delegate?.signalLossChanged()
    }

    func clearSignalLoss() {
        signalLossTimer?.invalidate()
        signalLossTimer = nil
        signalLossID = nil
        signalLossBeganAt = nil
        signalLossIgnored = false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }

    func handleBluetoothState(_ state: CBManagerState) {
        delegate?.bluetoothStateChanged(state)
        if state == .poweredOn {
            print("蓝牙已开启")
            scanForPeripherals()
        } else {
            print("蓝牙暂不可用，继续等待失联锁定计时")
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            monitoredPeripheral = nil
            // 不清除 presence、不取消失联计时，否则关蓝牙会绕过离开锁定。
            if signalTimer == nil || signalTimer?.isValid == false { resetSignalTimer() }
        }
    }

    func getEstimatedRSSI(rssi: Int) -> Int {
        if latestRSSIs.count >= latestN {
            latestRSSIs.removeFirst()
        }
        latestRSSIs.append(Double(rssi))
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(latestRSSIs, 1, nil, 1, &mean, &sddev, vDSP_Length(latestRSSIs.count))
        return Int(mean)
    }

    func displayDidSleep() { wakeOnNextNearSample = true }

    func updateMonitoredPeripheral(_ rssi: Int) {
        guard monitoredUUID != nil, ConnectionStatus.validRSSI(rssi) else { return }
        lastSampleAt = Date()
        let recovered = signalLossID != nil || waitingForDeviceAfterUnlock
        waitingForDeviceAfterUnlock = false
        if recovered {
            clearSignalLoss()
            // 恢复弱信号也要重新判断远离，不能被“本次不锁定”永久停用。
            presence = true
            delegate?.monitorEvent("有效信号已恢复，取消断连倒计时并恢复距离保护。")
            delegate?.signalLossChanged()
        }
        lastRawRSSI = rssi
        let enteredWakeRange = rssi >= wakeRSSI && !withinWakeRange
        withinWakeRange = rssi >= wakeRSSI
        if !withinWakeRange { wakeReportedSinceDeparture = false }
        let departureThreshold = lockRSSI == LOCK_DISABLED ? -80 : lockRSSI
        // ponytail: 用现有门槛加 5 dBm 回差确认返回，避免在远离区间持续亮屏。
        let returnedFromDeparture = !presence && !wakeReportedSinceDeparture
            && rssi >= max(wakeRSSI, departureThreshold + 5)
        let returnThreshold = unlockRSSI == UNLOCK_DISABLED ? -60 : unlockRSSI
        let wakeAfterDisplaySleep = wakeOnNextNearSample && rssi >= max(wakeRSSI, returnThreshold)
        if wakeAfterDisplaySleep { wakeOnNextNearSample = false }
        let cameBack = rssi >= returnThreshold && (!presence || recovered)
        if cameBack { latestRSSIs.removeAll() }
        let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
        // 先发布有效信号，再通知靠近，保证解锁门槛读取的是本次采样。
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)
        if cameBack {
            print("设备已靠近")
            delegate?.monitorEvent("信号达到靠近门槛 \(returnThreshold) dBm，判定设备已返回。")
            presence = true
            wakeReportedSinceDeparture = true
            delegate?.updatePresence(presence: true, reason: "close")
        } else if enteredWakeRange || returnedFromDeparture || wakeAfterDisplaySleep {
            wakeReportedSinceDeparture = true
            delegate?.reachedWakeRange()
        }
        if estimatedRSSI >= departureThreshold {
            if proximityTimer != nil { delegate?.monitorEvent("信号恢复到远离门槛以上，取消延迟锁定。") }
            proximityTimer?.invalidate()
            proximityTimer = nil
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false) { [weak self] _ in
                guard let self = self, !self.waitingForDeviceAfterUnlock else { return }
                self.proximityTimer = nil
                guard let sample = self.lastSampleAt, Date().timeIntervalSince(sample) < min(3, self.signalTimeout) else {
                    self.delegate?.monitorEvent("远离确认到期但没有持续的新采样，等待断连确认，不凭旧的弱信号立即锁定。")
                    return
                }
                print("设备已远离")
                self.delegate?.monitorEvent("信号持续低于远离门槛，远离确认计时已到。")
                self.presence = false
                self.wakeReportedSinceDeparture = false
                self.proximityTimer = nil
                self.delegate?.updatePresence(presence: false, reason: "away")
            }
            RunLoop.main.add(proximityTimer!, forMode: .common)
            print("已开始延迟锁定计时")
            delegate?.monitorEvent("平均信号 \(estimatedRSSI) dBm 低于 \(departureThreshold) dBm，开始 \(Int(proximityTimeout)) 秒远离确认。")
        }
        resetSignalTimer()
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            guard self.devices[device.uuid] === device else { return }
            self.delegate?.removeDevice(device: device)
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // 当 didConnect 回调没有触发时，预先读取信号可帮助恢复连接。
        // 原因尚不明确，此操作可能产生系统警告日志。
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("正在连接设备")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            if p.state == .connecting {
                print("设备连接超时")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connectionTimer!, forMode: .common)
    }

    // MARK: - 蓝牙中心管理器回调

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue
        if scanMode {
            scanAdvertisementCount += 1
            scanSeenDevices.insert(peripheral.identifier)
            if !ConnectionStatus.validRSSI(rssi) || rssi < thresholdRSSI {
                scanFilteredDevices.insert(peripheral.identifier)
            } else { scanFilteredDevices.remove(peripheral.identifier) }
        }
        guard ConnectionStatus.validRSSI(rssi) else { return }
        if let uuid = monitoredUUID {
            if peripheral.identifier.description == uuid.description {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                if activeModeTimer == nil {
                    updateMonitoredPeripheral(rssi)
                    if !passiveMode {
                        connectMonitoredPeripheral()
                    }
                }
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                guard rssi >= thresholdRSSI else { return }
                device = Device(uuid: peripheral.identifier)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    devices[peripheral.identifier] = device
                    if !passiveMode { central.connect(peripheral, options: nil) }
                    delegate?.newDevice(device: device)
                }
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        if peripheral == monitoredPeripheral && !passiveMode {
            print("设备已连接")
            delegate?.monitorEvent("主动蓝牙连接已建立，正在读取设备信号。")
            connectionTimer?.invalidate()
            connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == monitoredUUID else { return }
        delegate?.monitorEvent("主动连接失败，继续监听广播：\(error?.localizedDescription ?? "设备没有响应")")
        scanForPeripherals()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == monitoredUUID else { return }
        delegate?.monitorEvent("主动连接已断开，将重试连接或监听广播。失联锁定计时继续。")
        scanForPeripherals()
    }

    // MARK: - 蓝牙外设回调

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, peripheral == monitoredPeripheral else { return }
        let rssi = RSSI.intValue
        guard ConnectionStatus.validRSSI(rssi) else { return }
        updateMonitoredPeripheral(rssi)
        lastReadAt = Date().timeIntervalSince1970

        if activeModeTimer == nil && !passiveMode {
            print("已进入主动模式")
            delegate?.monitorEvent("正在主动读取信号，每 2 秒采样一次。")
            if !scanMode {
                centralMgr?.stopScan()
            }
            activeModeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { _ in
                if Date().timeIntervalSince1970 > self.lastReadAt + 10 {
                    print("已回退到被动模式")
                    self.delegate?.monitorEvent("主动读取连续 10 秒无响应，已回退到广播监听。")
                    self.centralMgr.cancelPeripheralConnection(peripheral)
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral()
                }
            })
            RunLoop.main.add(activeModeTimer!, forMode: .common)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        delegate?.updateDevice(device: device)
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        delegate?.updateDevice(device: device)
                    }
                    if device.model != nil && device.manufacture != nil && device.peripheral != monitoredPeripheral {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }

    init(enableBluetooth: Bool = true) {
        super.init()
        if enableBluetooth { centralMgr = CBCentralManager(delegate: self, queue: nil) }
    }
}
