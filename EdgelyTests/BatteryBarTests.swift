import XCTest
@testable import Edgely
import AttSensorKit

/// 电池条：颜色规则（纯函数）、`BatteryMonitor` 的监控行为、左右槽位分配和文字（ADR-0015）。
final class BatteryBarTests: XCTestCase {

    // MARK: - 颜色规则

    func test_isLow_includesTheTenPercentBucket() {
        XCTAssertTrue(BatteryLevelPolicy.isLow(10), "10% 这一档（3.50–3.68V）也算低电量")
        XCTAssertTrue(BatteryLevelPolicy.isLow(5))
        XCTAssertTrue(BatteryLevelPolicy.isLow(0))
        XCTAssertFalse(BatteryLevelPolicy.isLow(15))
        XCTAssertFalse(BatteryLevelPolicy.isLow(100))
        XCTAssertFalse(BatteryLevelPolicy.isLow(nil), "还没读到不算低电量")
    }

    // MARK: - 监控

    private func makeMonitor() -> BatteryMonitor { BatteryMonitor(pollInterval: 3600) }

    private func item(_ adapter: MockAdapter, side: BatteryMonitor.Side? = .left, keep: Bool = true) -> BatteryMonitor.Item {
        BatteryMonitor.Item(adapter: adapter, side: side, keepWhenDisconnected: keep)
    }

    func test_monitor_alwaysShowsReadings_evenWhenBatteryIsHigh_andTracksChanges() throws {
        let adapter = MockAdapter()
        adapter.isReady = true
        let monitor = makeMonitor()
        monitor.watch([item(adapter)])
        XCTAssertEqual(monitor.readings.map(\.percent), [nil], "还没读到电量：显示条，但没有数值")

        adapter.batteryPercent = 75
        XCTAssertEqual(monitor.readings.map(\.percent), [75])
        adapter.batteryPercent = 10
        XCTAssertEqual(monitor.readings.map(\.percent), [10])
    }

    func test_monitor_disconnected_keepsReadingOnlyWhenAsked() throws {
        let adapter = MockAdapter()
        adapter.isReady = true
        adapter.batteryPercent = 0
        let keeping = makeMonitor()
        keeping.watch([item(adapter, keep: true)])
        let hiding = makeMonitor()
        hiding.watch([item(adapter, keep: false)])
        XCTAssertEqual(keeping.readings.count, 1)
        XCTAssertEqual(hiding.readings.count, 1)

        adapter.isReady = false // 传感器没电关机，断线
        XCTAssertNil(keeping.readings.first?.percent, "断线后不保留旧电量")
        XCTAssertEqual(keeping.readings.first?.isConnected, false, "槽位保留，显示已断线")
        XCTAssertTrue(hiding.readings.isEmpty, "连接页断线就隐藏")
    }

    func test_monitor_notConnectedAndNoData_showsNothingOnTheConnectPage() throws {
        let adapter = MockAdapter() // 已发现、还没连上
        let monitor = makeMonitor()
        monitor.watch([item(adapter, keep: false)])
        XCTAssertTrue(monitor.readings.isEmpty)
        adapter.isReady = true
        XCTAssertEqual(monitor.readings.count, 1, "连上后出现")
    }

    func test_monitor_twoSensors_listsBoth() throws {
        let a = MockAdapter(), b = MockAdapter()
        a.isReady = true; b.isReady = true
        a.batteryPercent = 5; b.batteryPercent = 75
        let monitor = makeMonitor()
        monitor.watch([item(a, side: .left), item(b, side: .right)])
        XCTAssertEqual(monitor.readings.map(\.side), [.left, .right])
        XCTAssertEqual(monitor.readings.map(\.percent), [5, 75])
    }

    func test_monitor_emptyWatchClears() throws {
        let adapter = MockAdapter()
        adapter.isReady = true
        let monitor = makeMonitor()
        monitor.watch([item(adapter)])
        XCTAssertEqual(monitor.readings.count, 1)
        monitor.watch([])
        XCTAssertTrue(monitor.readings.isEmpty)
    }

    func test_monitor_reconnect_showsNoPercentUntilNewReading() throws {
        let adapter = MockAdapter()
        adapter.isReady = true
        adapter.batteryPercent = 40
        let monitor = makeMonitor()
        monitor.watch([item(adapter)])
        adapter.isReady = false
        adapter.isReady = true
        XCTAssertEqual(monitor.readings.first?.percent, nil, "重连后新读数到之前不显示旧值")
        adapter.batteryPercent = 35
        XCTAssertEqual(monitor.readings.first?.percent, 35)
    }

    // MARK: - 显示

    private func reading(_ side: BatteryMonitor.Side?, _ percent: Int? = 50) throws -> BatteryMonitor.Reading {
        let adapter = MockAdapter()
        return BatteryMonitor.Reading(id: ObjectIdentifier(adapter), side: side, percent: percent, isConnected: true)
    }

    func test_slots_placeBySide_regardlessOfOrder() throws {
        let l = try reading(.left), r = try reading(.right)
        let slots = BatteryBar.slots(for: [r, l])
        XCTAssertEqual(slots.left, l)
        XCTAssertEqual(slots.right, r)
    }

    func test_slots_singleSensor_onlyTakesItsOwnHalf() throws {
        let r = try reading(.right)
        let slots = BatteryBar.slots(for: [r])
        XCTAssertNil(slots.left)
        XCTAssertEqual(slots.right, r)
    }

    func test_slots_unresolvedSensorsFillVacantHalves() throws {
        let u1 = try reading(nil), u2 = try reading(nil), r = try reading(.right)
        let one = BatteryBar.slots(for: [r, u1])
        XCTAssertEqual(one.left, u1)
        XCTAssertEqual(one.right, r)
        let two = BatteryBar.slots(for: [u1, u2])
        XCTAssertEqual(two.left, u1)
        XCTAssertEqual(two.right, u2)
    }

    func test_percentText() {
        XCTAssertEqual(BatteryBar.percentTextForTesting(75), "75%")
        XCTAssertEqual(BatteryBar.percentTextForTesting(nil), "--%")
    }
}
