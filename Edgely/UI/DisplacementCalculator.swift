import Foundation
import simd

/// 回放用的采样点：时间、加速度（g）、角速度（deg/s）。
struct SensorReading: Equatable {
    let t: Double
    let accel: SIMD3<Float>
    let gyro: SIMD3<Float>
}

/// ADR-0017：回放位移 = 当前位置 − 以当前时刻为中心的窗口内位置均值。
/// 位置由重力补偿后的加速度二次积分得到；姿态用陀螺积分 + 加速度计修正倾斜。
/// 只在连续的数据段内计算（数据缺口把采样切成多段），窗口超出段边界的时刻没有位移。
enum DisplacementCalculator {
    /// 可选的平均窗口长度（秒）
    static let windowOptions: [Double] = [1, 2, 5, 10]
    static let defaultWindow: Double = 2

    private static let gravity = 9.80665
    /// 50Hz 采样周期；丢帧造成的长间隔按它补点积分
    private static let samplePeriod = 0.02
    /// 超过这个间隔的相邻采样不再补点（正常录制里只有数据缺口会这么长，缺口已把数据切成不同的段）
    private static let maxGapToFill = 0.5
    /// 加速度计倾斜修正增益（1/s）
    private static let tiltCorrectionGain = 0.5
    /// 用每段开头这么长的数据平均出初始重力方向
    private static let initialGravityDuration = 1.0
    /// 水平投影长度低于它时认为前轴接近竖直，朝向不可靠
    private static let minHorizontalFront = 0.1

    /// 与窗口长度无关的中间结果：每个采样点的世界系位置（会随时间漂移，只能相减后使用）和当前朝向。
    struct Track {
        fileprivate let times: [Double]
        fileprivate let positions: [SIMD3<Double>]
        /// 校准前轴在当前时刻的水平投影（单位向量，世界系 x/y），前轴接近竖直时为 nil
        fileprivate let heading: [SIMD2<Double>?]
        /// 每个采样点所属数据段的起止下标（含）
        fileprivate let segmentFirst: [Int]
        fileprivate let segmentLast: [Int]
        /// 位置（按采样点之间分段线性）从数据段开头起的累积积分，窗口均值用；跨段的间隔不累加
        fileprivate let cumulative: [SIMD3<Double>]
    }

    /// 积分整段数据。`gaps` 把数据切成多段，每段独立估计姿态和位置。
    static func track(readings: [SensorReading], gaps: [DataGap], frame: SensorOrientationFrame) -> Track {
        var positions = [SIMD3<Double>](repeating: .zero, count: readings.count)
        var heading = [SIMD2<Double>?](repeating: nil, count: readings.count)
        var segFirst = [Int](repeating: 0, count: readings.count)
        var segLast = [Int](repeating: 0, count: readings.count)

        var start = 0
        while start < readings.count {
            var end = start
            while end + 1 < readings.count, !crossesGap(readings[end].t, readings[end + 1].t, gaps) { end += 1 }
            integrate(readings, start...end, frame: frame, positions: &positions, heading: &heading)
            for i in start...end { segFirst[i] = start; segLast[i] = end }
            start = end + 1
        }

        // 梯形累积。位置里含有积分漂移（可达每秒数十米），丢帧时采样间隔不均匀，
        // 按采样个数求均值会在窗口边缘遇到丢帧时跳变；对分段线性曲线精确积分则不受采样间隔影响
        var cumulative = [SIMD3<Double>](repeating: .zero, count: readings.count)
        for i in 1..<max(readings.count, 1) where segFirst[i] == segFirst[i - 1] {
            cumulative[i] = cumulative[i - 1] + (positions[i - 1] + positions[i]) / 2 * (readings[i].t - readings[i - 1].t)
        }
        return Track(times: readings.map(\.t), positions: positions, heading: heading,
                     segmentFirst: segFirst, segmentLast: segLast, cumulative: cumulative)
    }

    /// 位置曲线从数据段开头到时刻 x 的积分。k 是不晚于 x 的最后一个采样下标，x 不得早于段首。
    private static func integral(_ track: Track, upTo x: Double, at k: Int) -> SIMD3<Double> {
        let f = x - track.times[k]
        guard f > 0, k + 1 <= track.segmentLast[k] else { return track.cumulative[k] }
        let span = track.times[k + 1] - track.times[k]
        let px = track.positions[k] + (track.positions[k + 1] - track.positions[k]) * (f / span)
        return track.cumulative[k] + (track.positions[k] + px) / 2 * f
    }

    /// 按窗口长度算出每个采样点的位移，已换算到渲染世界坐标系（米；x = -左，y = 上，z = 前，见 PoseAlignment）。
    /// 窗口越出所在数据段、或前轴朝向不可靠的采样点为 nil。
    static func displacements(track: Track, window: Double) -> [SIMD3<Float>?] {
        let n = track.times.count
        var result = [SIMD3<Float>?](repeating: nil, count: n)
        var lo = 0
        var hi = 0
        for i in 0..<n {
            let t = track.times[i]
            guard let h = track.heading[i],
                  t - window / 2 >= track.times[track.segmentFirst[i]],
                  t + window / 2 <= track.times[track.segmentLast[i]] else { continue }
            // lo / hi：不晚于窗口左 / 右端的最后一个采样（窗口端点落在 lo…lo+1、hi…hi+1 之间）
            lo = max(lo, track.segmentFirst[i])
            while lo + 1 < n, track.times[lo + 1] <= t - window / 2 { lo += 1 }
            hi = max(hi, i)
            while hi + 1 <= track.segmentLast[i], track.times[hi + 1] <= t + window / 2 { hi += 1 }
            let mean = (integral(track, upTo: t + window / 2, at: hi) - integral(track, upTo: t - window / 2, at: lo)) / window
            let d = track.positions[i] - mean
            let fwd = SIMD2<Double>(h.x, h.y)
            let left = SIMD2<Double>(-h.y, h.x) // 竖直向上 × 前
            let pFront = d.x * fwd.x + d.y * fwd.y
            let pLeft = d.x * left.x + d.y * left.y
            result[i] = SIMD3<Float>(Float(-pLeft), Float(d.z), Float(pFront))
        }
        return result
    }

    /// 回放时刻 t 对应的采样下标（最近邻，取不晚于 t 的最后一个）
    static func index(at t: Double, in readings: [SensorReading]) -> Int? {
        guard !readings.isEmpty else { return nil }
        var lo = 0
        var hi = readings.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if readings[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: - 积分

    private static func crossesGap(_ a: Double, _ b: Double, _ gaps: [DataGap]) -> Bool {
        gaps.contains { $0.start >= a - 1e-9 && $0.start < b }
    }

    /// 一段连续数据：姿态四元数（传感器系 → 世界系，世界 z 向上）+ 位置双重积分
    private static func integrate(_ r: [SensorReading], _ range: ClosedRange<Int>, frame: SensorOrientationFrame,
                                  positions: inout [SIMD3<Double>], heading: inout [SIMD2<Double>?]) {
        let t0 = r[range.lowerBound].t
        var sum = SIMD3<Double>.zero
        var count = 0.0
        for i in range where r[i].t - t0 <= initialGravityDuration {
            sum += SIMD3<Double>(r[i].accel); count += 1
        }
        var q = quaternionFromUp(sum / count)
        var velocity = SIMD3<Double>.zero
        var position = SIMD3<Double>.zero
        let front = SIMD3<Double>(frame.front)
        let worldUp = SIMD3<Double>(0, 0, 1)

        for i in range {
            if i > range.lowerBound {
                // 丢帧时相邻采样的间隔大于一个采样周期：缺的这段用两端读数线性插值补上，
                // 再按采样周期逐步积分；直接把单个读数乘以长间隔会让位置出现虚假的阶跃
                let span = min(max(r[i].t - r[i - 1].t, 0), maxGapToFill)
                let steps = max(1, Int((span / samplePeriod).rounded()))
                let dt = span / Double(steps)
                for k in 1...steps {
                    let alpha = Double(k) / Double(steps)
                    let a = simd_mix(SIMD3<Double>(r[i - 1].accel), SIMD3<Double>(r[i].accel), SIMD3<Double>(repeating: alpha))
                    let gyro = simd_mix(SIMD3<Double>(r[i - 1].gyro), SIMD3<Double>(r[i].gyro), SIMD3<Double>(repeating: alpha))
                    // 倾斜修正：把当前加速度方向转到世界系，与竖直方向的叉积就是倾斜误差
                    let rot = rotate(q)
                    let aw = rot * a
                    let norm = simd_length(aw)
                    var w = gyro * Double.pi / 180
                    if norm > 1e-6 {
                        w += rot.transpose * (tiltCorrectionGain * simd_cross(aw / norm, worldUp))
                    }
                    let dq = qmul(q, SIMD4<Double>(0, w.x * dt / 2, w.y * dt / 2, w.z * dt / 2))
                    q = simd_normalize(q + dq)
                    // 世界系线加速度（m/s²）= 加速度计读数 × g − 重力
                    var lin = (rotate(q) * a) * gravity
                    lin.z -= gravity
                    velocity += lin * dt
                    position += velocity * dt
                }
            }
            positions[i] = position
            let fw = rotate(q) * front
            let hl = (fw.x * fw.x + fw.y * fw.y).squareRoot()
            heading[i] = hl >= minHorizontalFront ? SIMD2<Double>(fw.x / hl, fw.y / hl) : nil
        }
    }

    /// 传感器系 → 世界系的旋转矩阵。q = (w, x, y, z)
    private static func rotate(_ q: SIMD4<Double>) -> simd_double3x3 {
        let (w, x, y, z) = (q.x, q.y, q.z, q.w)
        return simd_double3x3(rows: [
            SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
            SIMD3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
            SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
        ])
    }

    private static func qmul(_ p: SIMD4<Double>, _ q: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(p.x * q.x - p.y * q.y - p.z * q.z - p.w * q.w,
              p.x * q.y + p.y * q.x + p.z * q.w - p.w * q.z,
              p.x * q.z - p.y * q.w + p.z * q.x + p.w * q.y,
              p.x * q.w + p.y * q.z - p.z * q.y + p.w * q.x)
    }

    /// 把传感器系下的"向上"向量转到世界 z 的最短旋转（静止时加速度计读数指向上）
    private static func quaternionFromUp(_ up: SIMD3<Double>) -> SIMD4<Double> {
        let len = simd_length(up)
        guard len > 1e-6 else { return SIMD4(1, 0, 0, 0) }
        let u = up / len
        let axis = simd_cross(u, SIMD3<Double>(0, 0, 1))
        let s = simd_length(axis)
        let c = u.z
        if s < 1e-9 { return c > 0 ? SIMD4(1, 0, 0, 0) : SIMD4(0, 1, 0, 0) }
        let angle = atan2(s, c)
        let n = axis / s
        return SIMD4(cos(angle / 2), n.x * sin(angle / 2), n.y * sin(angle / 2), n.z * sin(angle / 2))
    }
}
