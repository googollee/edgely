import AttSensorKit
import Foundation
import simd

/// 一次校准阶段的数据缓存：校准流程自己累积设备适配层（见 ADR-0011）吐出的整条采样流，不依赖适配层保存历史。
///
/// 一个校准会话从开始到结束累积全部样本（含站立），结束即丢弃。
/// 会话有上限：四步，每步时限见 `CalibrationEngine.defaultStepTimeLimit`（10 秒），四步至多 40 秒量级，
/// 50Hz 下约 2000 条，内存可以忽略。
///
/// 窗口切片也在这里：窗口由两次确认点击的时刻界定，按样本的到达时间切出子序列。
/// 样本的重建时间 `t` 是适配层给的、与窗口无关，切片只是把它平移成"相对窗口内第一个样本"，算法看到的 dt 不变。
final class CalibrationStreamBuffer {
    private(set) var samples: [DeviceSample] = []

    /// 姿态基准的锚点：站立窗口里最后一个样本在 `samples` 里的位置。其后的姿态都相对它（站立末尾的体坐标系）积分。
    private var anchorPosition: Int?

    func append(_ sample: DeviceSample) {
        samples.append(sample)
    }

    /// 站立步骤确认后设锚点：到达时间不晚于 `end` 的最后一个样本就是站立末尾（ADR-0012）。
    /// 再次站立（整体重来）时重设，之前的积分结果作废。
    func anchorStanding(at end: Date) {
        anchorPosition = samples.lastIndex { $0.arrival <= end }
    }

    /// 从站立末尾连续积分陀螺仪，得到窗口第一个样本相对站立体坐标系的姿态（ADR-0012）。
    /// 锚点处姿态为单位姿态，之后逐样本积分，规则与窗口内部的积分相同（`CalibrationMath.advance`），
    /// 窗口之间的样本（含没有被任何窗口取用的）也都参与，所以倾斜和偏航都以站立为基准。
    /// 没有锚点、窗口为空，或积分区间里有缺口（帧序号不连续）时返回 nil，调用方退回最小旋转对齐；
    /// 没有序号的丢帧检测不到，但至少不会拿已知断开的流硬积分。
    func startAttitude(windowFrom start: Date, to end: Date) -> simd_quatf? {
        guard let anchor = anchorPosition,
              let first = samples.firstIndex(where: { $0.arrival >= start && $0.arrival <= end }),
              first >= anchor else { return nil }
        var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for k in anchor..<first {
            guard samples[k + 1].index == samples[k].index + 1 else { return nil }
            q = CalibrationMath.advance(q, gyro: samples[k].gyro, dt: Float(samples[k + 1].t - samples[k].t))
        }
        return q
    }

    /// 到达时间落在 `[start, end]` 内的样本，换成校准算法的输入格式。
    /// `t` 平移成相对窗口内第一个样本的秒数；`arrivalT` 是同一基准下的 BLE 到达时间，只用于落盘留档。
    /// 窗口严格由两次点击界定，不做任何长度截断——超时的处理是判失败，不是缩短窗口（见 ADR-0012「窗口与时限」）。
    func window(from start: Date, to end: Date) -> [TimedSample] {
        let picked = samples.filter { $0.arrival >= start && $0.arrival <= end }
        guard let first = picked.first else { return [] }
        return picked.map { sample in
            TimedSample(
                t: sample.t - first.t, accel: sample.accel, gyro: sample.gyro,
                arrivalT: sample.arrival.timeIntervalSince(first.arrival),
                frameIndex: sample.index, wallClock: sample.arrival.timeIntervalSince1970
            )
        }
    }
}
