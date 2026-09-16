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
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt = 0.0
    var lastRawRSSI: Int?
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
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
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
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        lastRawRSSI = nil
        delegate?.monitorEvent("已开始监测设备，等待有效信号；失联锁定计时已启用。")
        proximityTimer?.invalidate()
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
        presence = true
        latestRSSIs.removeAll()
        proximityTimer?.invalidate()
        proximityTimer = nil
        resetSignalTimer()
        delegate?.monitorEvent("屏幕重新解锁，重新确认设备距离并启动失联计时。")
    }

    func signalLost() {
        print("设备信号已丢失")
        lastRawRSSI = nil
        delegate?.monitorEvent("连续 \(Int(signalTimeout)) 秒没有有效信号，已触发失联判断。")
        proximityTimer?.invalidate()
        proximityTimer = nil
        latestRSSIs.removeAll()
        delegate?.updateRSSI(rssi: nil, active: false)
        presence = false
        // 即使之前已经远离，重新解锁后的失联计时也必须能够再次锁定。
        delegate?.updatePresence(presence: false, reason: "lost")
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

    func updateMonitoredPeripheral(_ rssi: Int) {
        guard monitoredUUID != nil, ConnectionStatus.validRSSI(rssi) else { return }
        lastRawRSSI = rssi
        let returnThreshold = unlockRSSI == UNLOCK_DISABLED ? -60 : unlockRSSI
        let cameBack = rssi >= returnThreshold && !presence
        if cameBack { latestRSSIs.removeAll() }
        let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
        // 先发布有效信号，再通知靠近，保证解锁门槛读取的是本次采样。
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)
        if cameBack {
            print("设备已靠近")
            delegate?.monitorEvent("信号达到靠近门槛 \(returnThreshold) dBm，判定设备已返回。")
            presence = true
            delegate?.updatePresence(presence: true, reason: "close")
        }
        let departureThreshold = lockRSSI == LOCK_DISABLED ? -80 : lockRSSI
        if estimatedRSSI >= departureThreshold {
            if proximityTimer != nil { delegate?.monitorEvent("信号恢复到远离门槛以上，取消延迟锁定。") }
            proximityTimer?.invalidate()
            proximityTimer = nil
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                print("设备已远离")
                self.delegate?.monitorEvent("信号持续低于远离门槛，远离确认计时已到。")
                self.presence = false
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
