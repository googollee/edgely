import CoreBluetooth
import XCTest
@testable import AttSensorKit

final class DeviceAdapterRegistryTests: XCTestCase {
    private struct StubFactory: DeviceAdapterFactory {
        let serviceUUIDs: [CBUUID]
        func makeAdapter(for peripheral: CBPeripheral) -> DeviceAdapter { fatalError("not used") }
    }

    private let a = CBUUID(string: "FFE5")
    private let b = CBUUID(string: "FFE6")
    private let c = CBUUID(string: "FFE7")

    func test_emptyRegistry_hasNoServiceUUIDsAndClaimsNothing() {
        let registry = DeviceAdapterRegistry()
        XCTAssertTrue(registry.serviceUUIDs.isEmpty, "为空时扫描不能启动，传空数组会变成全量扫描")
        XCTAssertNil(registry.factory(forAdvertisedServices: [a]))
    }

    func test_serviceUUIDs_mergeAcrossFactories_withoutDuplicates() {
        let registry = DeviceAdapterRegistry()
        registry.register(StubFactory(serviceUUIDs: [a, b]))
        registry.register(StubFactory(serviceUUIDs: [b, c]))
        XCTAssertEqual(registry.serviceUUIDs, [a, b, c])
    }

    func test_factoryClaimsDeviceByAdvertisedService_firstRegisteredWins() {
        let registry = DeviceAdapterRegistry()
        let first = StubFactory(serviceUUIDs: [a, b])
        let second = StubFactory(serviceUUIDs: [b, c])
        registry.register(first)
        registry.register(second)
        XCTAssertEqual(registry.factory(forAdvertisedServices: [c])?.serviceUUIDs, second.serviceUUIDs)
        XCTAssertEqual(registry.factory(forAdvertisedServices: [b])?.serviceUUIDs, first.serviceUUIDs, "多个工厂命中时注册在前的优先")
        XCTAssertNil(registry.factory(forAdvertisedServices: [CBUUID(string: "180D")]))
        XCTAssertNil(registry.factory(forAdvertisedServices: []))
    }

    func test_defaultConfirm_requiresAnyDeclaredService() {
        let factory = StubFactory(serviceUUIDs: [a, b])
        XCTAssertTrue(factory.confirm(discoveredServices: [c, b]))
        XCTAssertFalse(factory.confirm(discoveredServices: [c]))
        XCTAssertFalse(factory.confirm(discoveredServices: []))
    }
}
