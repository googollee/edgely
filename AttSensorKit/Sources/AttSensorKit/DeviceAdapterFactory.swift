import CoreBluetooth
import Foundation

/// 一类设备的适配器工厂（ADR-0016）。设备实现包为自己支持的设备提供一个工厂并注册进 `DeviceAdapterRegistry`。
public protocol DeviceAdapterFactory {
    /// 这类设备广播的服务 UUID：用于扫描过滤和认领设备，也用于连接后的确认。
    /// 设备必须把其中至少一个放进广播包，否则扫描时会被过滤掉
    var serviceUUIDs: [CBUUID] { get }

    /// 连接后确认：`discoveredServices` 是实际发现的服务。默认实现是"包含任一 `serviceUUIDs`"，需要更严检查的工厂可以覆盖
    func confirm(discoveredServices: [CBUUID]) -> Bool

    /// 为已认领、已确认的外设创建适配器。适配器在 `start()` 里接手外设（见 `DeviceAdapter.start()`）
    func makeAdapter(for peripheral: CBPeripheral) -> DeviceAdapter
}

public extension DeviceAdapterFactory {
    func confirm(discoveredServices: [CBUUID]) -> Bool {
        discoveredServices.contains { serviceUUIDs.contains($0) }
    }
}

/// 已注册的工厂集合。扫描用它汇总的 UUID，发现设备后用广播里的服务 UUID 认领。
public final class DeviceAdapterRegistry {
    public private(set) var factories: [DeviceAdapterFactory] = []

    public init() {}

    public func register(_ factory: DeviceAdapterFactory) {
        factories.append(factory)
    }

    /// 所有工厂的服务 UUID，去重、保持注册顺序。为空表示没有可用的设备支持，此时不应启动扫描
    /// （`scanForPeripherals(withServices:)` 传空数组会变成全量扫描）
    public var serviceUUIDs: [CBUUID] {
        var seen = Set<CBUUID>()
        return factories.flatMap(\.serviceUUIDs).filter { seen.insert($0).inserted }
    }

    /// 认领设备：广播里的服务 UUID 命中某个工厂的 `serviceUUIDs`。多个工厂同时命中时，注册在前的优先
    public func factory(forAdvertisedServices services: [CBUUID]) -> DeviceAdapterFactory? {
        factories.first { factory in services.contains { factory.serviceUUIDs.contains($0) } }
    }
}
