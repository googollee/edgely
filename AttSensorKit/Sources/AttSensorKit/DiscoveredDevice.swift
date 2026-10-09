import Combine
import CoreBluetooth
import Foundation

/// 扫描到的一个设备（被某个工厂认领）。连接并确认之后才有适配器。
/// 界面订阅它：就绪状态、电量的变化都从这里转发，行视图不需要认识具体的适配器类型。
public final class DiscoveredDevice: ObservableObject, Identifiable {
    /// 外设标识（CoreBluetooth 在这台手机上给的 UUID）
    public let id: UUID
    public let name: String?

    /// 连接并确认之后创建的适配器；确认失败或还没连接时为 nil
    @Published public private(set) var adapter: DeviceAdapter?
    @Published public private(set) var isReady = false
    /// 设备不具备电量能力时一直是 nil
    @Published public private(set) var batteryPercent: Int?
    /// 连接后确认失败的提示（"不是支持的设备"）
    @Published public private(set) var failure: String?

    let peripheral: CBPeripheral?
    let factory: DeviceAdapterFactory?
    private var subscriptions: Set<AnyCancellable> = []

    init(peripheral: CBPeripheral, name: String?, factory: DeviceAdapterFactory) {
        self.id = peripheral.identifier
        self.name = name ?? peripheral.name
        self.peripheral = peripheral
        self.factory = factory
    }

    /// 没有真实外设的设备（DEBUG 的模拟设备）
    init(id: UUID, name: String?, adapter: DeviceAdapter) {
        self.id = id
        self.name = name
        self.peripheral = nil
        self.factory = nil
        attach(adapter)
    }

    func attach(_ adapter: DeviceAdapter) {
        self.adapter = adapter
        failure = nil
        subscriptions.removeAll()
        isReady = adapter.isReady
        adapter.isReadyPublisher.dropFirst().sink { [weak self] in self?.isReady = $0 }.store(in: &subscriptions)
        if let battery = adapter as? BatteryReporting {
            batteryPercent = battery.batteryPercent
            battery.batteryPercentPublisher.dropFirst().sink { [weak self] in self?.batteryPercent = $0 }.store(in: &subscriptions)
        }
    }

    func markUnsupported() {
        failure = "不是支持的设备"
    }
}
