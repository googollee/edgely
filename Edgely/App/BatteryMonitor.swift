import AttSensorKit
import Combine
import Foundation

/// 电量百分比的颜色规则（纯函数）。
///
/// 设备给出的电量是分档的（例如由电压查表得到）：目前接入的设备只有 100/90/75/60/50/40/30/20/15/10/5/0 这些档位，
/// 10% 一档对应的电压范围很宽，所以"低电量"按"≤ 10%"算，否则 10% 这一档不会变红。
/// 还没读到电量（nil）时不算低电量。
enum BatteryLevelPolicy {
    static let lowAtOrBelow = 10

    static func isLow(_ percent: Int?) -> Bool {
        guard let percent else { return false }
        return percent <= lowAtOrBelow
    }
}

/// 监控一组传感器的电量，给出要在电池条上显示的读数（页面顶部，见 `BatteryBar`；显示规则见 ADR-0015）。
///
/// 传感器就绪时立刻读一次电量、之后按固定间隔轮询，连接、校准、录制各阶段都有数据。
/// 录制自己的每分钟电量快照（`RecordingSession`）不受影响。
final class BatteryMonitor: ObservableObject {
    enum Side { case left, right }

    struct Item {
        let adapter: BatteryReporting
        /// 左右脚，身份还没判定时为 nil（ADR-0015）
        let side: Side?
        /// 断线后是否继续占着槽位显示"已断线"。校准后的页面要继续显示，让用户看出是哪只脚的传感器掉了；
        /// 连接页还没开始使用，断线就隐藏
        let keepWhenDisconnected: Bool
    }

    struct Reading: Equatable, Identifiable {
        /// 适配器对象的身份（不用 `adapter.id`：那是外设标识，和蓝牙层绑得太紧）
        let id: ObjectIdentifier
        let side: Side?
        /// 还没读到、或已断线时为 nil（断线后不保留旧值，ADR-0015）
        let percent: Int?
        let isConnected: Bool
    }

    @Published private(set) var readings: [Reading] = []

    private struct Entry {
        let item: Item
        var percent: Int?
        var isReady: Bool
    }

    private var entries: [Entry] = []
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?

    init(pollInterval: TimeInterval = 60) {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollReadySensors()
        }
    }

    deinit { timer?.invalidate() }

    /// 换一组要监控的传感器（阶段切换时调用）。空数组表示停止监控
    func watch(_ items: [Item]) {
        subscriptions.removeAll()
        entries = items.map { Entry(item: $0, percent: $0.adapter.isReady ? $0.adapter.batteryPercent : nil, isReady: $0.adapter.isReady) }
        for (index, item) in items.enumerated() {
            item.adapter.batteryPercentPublisher.dropFirst().sink { [weak self] percent in
                self?.entries[index].percent = percent
                self?.refresh()
            }.store(in: &subscriptions)
            item.adapter.isReadyPublisher.dropFirst().sink { [weak self] ready in
                self?.entries[index].isReady = ready
                if !ready { self?.entries[index].percent = nil } // 断线后不保留旧值，重连后等新读数
                if ready { item.adapter.requestBattery() } // 刚连上/重连后马上读，不等下一次轮询
                self?.refresh()
            }.store(in: &subscriptions)
        }
        pollReadySensors()
        refresh()
    }

    private func pollReadySensors() {
        for entry in entries where entry.isReady { entry.item.adapter.requestBattery() }
    }

    private func refresh() {
        let result = entries
            .filter { $0.isReady || $0.item.keepWhenDisconnected }
            .map { Reading(id: ObjectIdentifier($0.item.adapter), side: $0.item.side, percent: $0.percent, isConnected: $0.isReady) }
        if result != readings { readings = result }
    }
}
