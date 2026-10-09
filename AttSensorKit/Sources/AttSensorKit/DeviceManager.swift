import Combine
import CoreBluetooth
import Foundation

/// F1：扫描并连接姿态传感器，不区分左右身份。通用部分——扫描、认领、连接确认、断线重连——都在这里，
/// 不认识任何具体设备的协议；具体设备的适配器由注册表里认领它的工厂创建（ADR-0016）。
public final class DeviceManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var bluetoothReady = false

    public let registry: DeviceAdapterRegistry
    /// 没有任何已注册的设备支持时为 false：此时不启动扫描，界面提示"没有可用的设备支持"
    public var hasDeviceSupport: Bool { !registry.serviceUUIDs.isEmpty }

    private var central: CBCentralManager!
    private var devicesByPeripheral: [UUID: DiscoveredDevice] = [:]
    /// 用户要求连接的外设：意外断开后自动重连（PRD F3/F4）。校准、录制期间都一样，不区分阶段
    private var desiredConnections: Set<UUID> = []

    public init(registry: DeviceAdapterRegistry) {
        self.registry = registry
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public func startScan() {
        guard central.state == .poweredOn, hasDeviceSupport else { return }
        discovered.removeAll()
        devicesByPeripheral.removeAll()
        desiredConnections.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: registry.serviceUUIDs, options: nil)
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
    }

    public func connect(_ device: DiscoveredDevice) {
        guard let peripheral = device.peripheral else {
            connectSimulated(device)
            return
        }
        desiredConnections.insert(device.id)
        central.connect(peripheral, options: nil)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        if bluetoothReady { reconnectDroppedDevices() }
    }

    /// CoreBluetooth 的 connect 没有超时：设备不在时请求一直挂着，设备回来就连上，所以这里不需要自己重试计时。
    private func reconnectDroppedDevices() {
        for device in devicesByPeripheral.values where desiredConnections.contains(device.id) && !device.isReady {
            if let peripheral = device.peripheral { central.connect(peripheral, options: nil) }
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard devicesByPeripheral[peripheral.identifier] == nil else { return }
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard let factory = registry.factory(forAdvertisedServices: advertised) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let device = DiscoveredDevice(peripheral: peripheral, name: name, factory: factory)
        devicesByPeripheral[peripheral.identifier] = device
        discovered.append(device)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DeviceManager] didConnect: \(peripheral.name ?? peripheral.identifier.uuidString)")
        guard let device = devicesByPeripheral[peripheral.identifier], let factory = device.factory else { return }
        if let adapter = device.adapter {
            // 断线后的重连：适配器已经确认过，直接让它重新接手
            adapter.start()
        } else {
            // 第一次连接：先确认设备确实提供工厂声明的服务，再创建适配器
            peripheral.delegate = self
            peripheral.discoverServices(factory.serviceUUIDs)
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[DeviceManager] didFailToConnect: \(peripheral.name ?? peripheral.identifier.uuidString), error: \(String(describing: error))")
        guard desiredConnections.contains(peripheral.identifier) else { return }
        // 失败很少见，隔一会儿再试，避免立刻失败时空转
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.central.state == .poweredOn, self.desiredConnections.contains(peripheral.identifier) else { return }
            self.central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DeviceManager] didDisconnectPeripheral: \(peripheral.name ?? peripheral.identifier.uuidString), error: \(String(describing: error))")
        devicesByPeripheral[peripheral.identifier]?.adapter?.connectionDidDrop()
        guard desiredConnections.contains(peripheral.identifier), central.state == .poweredOn else { return }
        central.connect(peripheral, options: nil)
    }

    // MARK: - CBPeripheralDelegate（只在连接后确认阶段使用，确认通过后外设交给适配器）

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let device = devicesByPeripheral[peripheral.identifier], let factory = device.factory, device.adapter == nil else { return }
        let found = peripheral.services?.map(\.uuid) ?? []
        if error == nil, factory.confirm(discoveredServices: found) {
            let adapter = factory.makeAdapter(for: peripheral)
            device.attach(adapter)
            adapter.start()
        } else {
            print("[DeviceManager] 设备确认失败: \(peripheral.name ?? peripheral.identifier.uuidString), services: \(found), error: \(String(describing: error))")
            desiredConnections.remove(peripheral.identifier)
            device.markUnsupported()
            central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - 模拟设备（仅 DEBUG）

    #if DEBUG
    /// 往列表里加一个模拟设备：没有真实设备实现时也能走界面流程。模拟设备只给静止的数据，校准动作无法通过
    public func addSimulatedDevice() {
        let adapter = MockAdapter()
        let device = DiscoveredDevice(id: adapter.id, name: "模拟设备 \(discovered.count + 1)", adapter: adapter)
        discovered.append(device)
    }
    #endif

    private func connectSimulated(_ device: DiscoveredDevice) {
        #if DEBUG
        (device.adapter as? MockAdapter)?.start()
        #endif
    }
}
