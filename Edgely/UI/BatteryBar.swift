import SwiftUI

/// 电池条：挂在根视图顶部（`RootView`），准备录制、录制中两个页面共用同一个位置。
/// 一行分成左右两半：左脚传感器在左半边，右脚传感器在右半边，只有一个传感器时另一半留空；
/// 每个槽位靠自己那一半的左侧对齐，内容是"左脚 85%"。断线时显示"左脚 已断线"。
/// 连接页不用这个条，电量直接显示在设备行里（`BatteryPercentText`）。规则见 ADR-0015。
struct BatteryBar: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        if !monitor.readings.isEmpty {
            let slots = BatteryBar.slots(for: monitor.readings)
            HStack(spacing: 0) {
                BatterySlot(reading: slots.left)
                BatterySlot(reading: slots.right)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 把读数分到左右两个槽位：按左右脚归位；没判定出左右脚的放到还空着的那一半
    static func slots(for readings: [BatteryMonitor.Reading]) -> (left: BatteryMonitor.Reading?, right: BatteryMonitor.Reading?) {
        var left = readings.first { $0.side == .left }
        var right = readings.first { $0.side == .right }
        for reading in readings where reading.side == nil {
            if left == nil { left = reading } else if right == nil { right = reading }
        }
        return (left, right)
    }
}

extension BatteryBar {
    static func percentTextForTesting(_ percent: Int?) -> String { BatteryPercentText.text(percent) }
}

/// 一个槽位：占一半宽度，没有读数时留空
private struct BatterySlot: View {
    let reading: BatteryMonitor.Reading?

    var body: some View {
        HStack(spacing: 8) {
            if let reading {
                Text(reading.side == .right ? "右脚" : reading.side == .left ? "左脚" : "传感器").font(.callout)
                if reading.isConnected {
                    BatteryPercentText(percent: reading.percent)
                } else {
                    Text("已断线").font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 电量百分比文字：电量 ≤ 10% 红色，其余主色（`BatteryLevelPolicy`）；没读到时显示 `--%`
struct BatteryPercentText: View {
    let percent: Int?

    var body: some View {
        Text(BatteryPercentText.text(percent))
            .font(.callout.bold().monospacedDigit())
            .foregroundStyle(BatteryLevelPolicy.isLow(percent) ? Color.red : Color.primary)
    }

    static func text(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "--%"
    }
}
