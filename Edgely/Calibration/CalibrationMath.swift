import AttSensorKit
import Foundation
import simd

/// 一个传感器校准后得到的参考系：下、前、左（右脚用同一套字段表示"右"方向，语义相同）
struct SensorOrientationFrame: Equatable {
    let down: SIMD3<Float>
    let front: SIMD3<Float>
    let left: SIMD3<Float>
}

/// 带相对时间戳的校准采样：速度积分需要 Δt，所以校准算法吃的是这个类型，而不是设备适配层的 `DeviceSample`。
/// `t` 是相对窗口内第一个样本的秒数，来自设备适配层按采样序号重建的时间轴（见 ADR-0010、ADR-0011），
/// 由 `CalibrationStreamBuffer.window(from:to:)` 平移得到，不是 BLE 到达时间。`arrivalT` 是同一个样本相对窗口内第一个样本的 BLE 到达时间，只用于落盘留档分析，
/// 算法不读它；构造时可省略（测试里的合成信号没有到达时间）。
struct TimedSample: Equatable {
    let t: TimeInterval
    let accel: SIMD3<Float> // g
    let gyro: SIMD3<Float>  // deg/s
    var arrivalT: TimeInterval? = nil
    /// 这个样本在本次校准内的实时帧序号（从 0 起算）和到达时的手机绝对时间（`timeIntervalSince1970`），
    /// 同样只用于落盘：可以把各窗口拼成一条时间线。
    var frameIndex: Int? = nil
    var wallClock: TimeInterval? = nil
}

/// F-002 方向校准用到的纯计算逻辑：只接受采样窗口和数值，不依赖设备适配层/CoreBluetooth，
/// 可以直接单元测试、不需要 mock 任何接口。`CalibrationEngine` 负责取窗口数据、维护步骤状态机与单步超时。
///
/// 整套流程的决定见 ADR-0012。两类窗口各走一条管线：
/// - 抬脚窗口：`motionPeakSpeed`，只回答"这只脚动了多快"，用于左右身份判定（`compare`）。
/// - 迈步窗口：`frame`，重力补偿后的加速度一次积分成速度，用"动作起止速度为零"做线性去趋势后取速度方向。
///   姿态参考系是站立步骤的体坐标系：窗口起点的姿态由调用方从站立末尾连续积分得到后传入（`startAttitude`），
///   取不到时退回"起点重力方向对齐站立 down 的最小旋转"。
/// 窗口两端是否静止不做计算验证，完全依赖点击式交互和指令文案。
enum CalibrationMath {
    /// 相对区分度：较大值至少是较小值的这个倍数才判定为清晰（见 ADR-0012 §3）
    static let minSeparationRatio: Float = 3.0
    /// 峰值速度下限（m/s）：身份判定与"这一步够不够明显"共用同一个参数（见 ADR-0012）
    static let minPeakSpeed: Float = 0.15

    // MARK: - ADR-0012 的初始参数（均未经充分的真实数据验证，需现场测试回填）

    /// 端点取样的观察窗长：取窗口首尾各这么长一段，取 accel 均值作为该处的重力方向观测
    static let edgeWindow: TimeInterval = 0.2
    /// 姿态积分漂移自检：窗口首尾测得的重力方向经姿态补偿后的夹角上限（度）
    static let driftToleranceDegrees: Float = 15
    /// 方向一致性下限：|∫v dt| / ∫|v| dt，低于此判定方向不明确
    static let minDirectionCoherence: Float = 0.5
    /// 活动段检测（迈步窗口只对传感器所在脚自己的那一步积分，见 ADR-0012 §5 步骤 0）：
    /// 逐帧判活动——角速度模超过 `activityGyro`（deg/s），或 `|accel|` 偏离 1g 超过 `activityAccel`（g）。
    /// 真实迈步时脚会转动、会抬起，这两项至少有一项远超阈值。
    static let activityGyro: Float = 40
    static let activityAccel: Float = 0.15
    /// 活动帧之间的间隔超过这个时长就分成两个活动簇（另一只脚落地的单帧冲击因此自成一簇、持续时间为 0）
    static let activityGap: TimeInterval = 0.3
    /// 积分区间在最长活动簇两端各延长这么长，落在这只脚自己的静止段上，让"起止速度为零"的前提成立
    static let segmentMargin: TimeInterval = 0.4

    /// accel 的单位是 g，积分成速度前换算成 m/s²，为速度阈值提供直观的物理单位。
    static let gravity: Float = 9.80665

    enum ComparisonOutcome: Equatable {
        case winner(firstWins: Bool)
        case tooWeak
        case tooClose
    }

    /// 前轴计算的结果：成功给参考系，失败给原因。任何失败都由调用方整体重置（见 ADR-0012「失败处理」），
    /// 算法本身不区分失败类型的处理方式，区分类型只是为了 `FrameOutcome` 语义清晰。
    enum FrameResult: Equatable {
        case frame(SensorOrientationFrame)
        /// 窗口数据不足以计算（样本太少、时长为零、端点取不到有效的重力方向），纯防御性分支，不对应 ADR 里
        /// 任何命名的失败类型
        case insufficientData
        /// 姿态积分的累积漂移超出容差，本窗口的方向结果不可信
        case driftTooLarge
        /// 速度方向过于分散，给不出一个明确的"前"
        case directionUnclear
    }

    /// 判定用到的全部中间量，成功和失败都带（见 ADR-0012「前轴计算」、「校准数据落盘」）。
    /// `peakSpeed` 是迈步窗口的幅度判定依赖的字段（抬脚窗口的身份判定用 `motionPeakSpeed`），其余字段主要供落盘分析。
    /// 窗口起点姿态（相对站立体坐标系）的来源，见 ADR-0012
    enum StartAttitudeSource: String, Equatable {
        /// 调用方从站立末尾连续积分陀螺仪得到，倾斜和偏航都以站立为基准
        case continuous
        /// 连续积分不可用（流有缺口、没有站立锚点等），退回起点重力方向到站立 down 的最小旋转：
        /// 只对齐重力，不约束绕 down 轴的偏航
        case aligned
    }

    struct FrameDiagnostics: Equatable {
        var downStart: SIMD3<Float>?
        var downEnd: SIMD3<Float>?
        /// 窗口内的积分漂移：窗口首尾测得的重力方向经姿态补偿后的夹角（ADR-0012 §5 步骤 3）
        var driftDegrees: Float?
        /// 从站立起的累计漂移：窗口起点姿态下，起点测得的重力方向与站立 down 的夹角（ADR-0012）。
        /// `aligned` 来源时它是窗口起点相对站立姿态的原始倾角（对齐前），不是漂移，只作留档
        var startDriftDegrees: Float?
        var startAttitudeSource: StartAttitudeSource?
        var peakSpeed: Float?
        var coherence: Float?
        /// 积分区间的时长与采样数（分段积分时是活动段，不是整个窗口）
        var windowDuration: TimeInterval
        var sampleCount: Int
        /// 分段积分时，积分区间在窗口内的起止时间（相对窗口第一个样本的秒数）；没有分段时为 nil
        var segmentStartT: TimeInterval?
        var segmentEndT: TimeInterval?
    }

    struct FrameOutcome: Equatable {
        let result: FrameResult
        let diagnostics: FrameDiagnostics

        /// 峰值速度，取不到时按 0 处理——身份判定拿它跟别的窗口比较，缺数据等同于"没动"。
        var peakSpeed: Float { diagnostics.peakSpeed ?? 0 }
    }

    // MARK: - 端点取样

    /// 取 `[from, to]` 时间范围内样本的 accel 均值方向。用于 `downStart`/`downEnd`/站立基准——
    /// 不做静止验证，信任调用方给的窗口两端确实静止（见 ADR-0012）。
    private static func averageDirection(_ samples: [TimedSample], from: TimeInterval, to: TimeInterval) -> SIMD3<Float>? {
        let picked = samples.filter { $0.t >= from && $0.t <= to }
        guard !picked.isEmpty else { return nil }
        var sum = SIMD3<Float>(repeating: 0)
        for s in picked { sum += s.accel }
        let avg = sum / Float(picked.count)
        guard simd_length(avg) > 0.01 else { return nil }
        return simd_normalize(avg)
    }

    /// 站立基准轴："下"取窗口末尾 `edgeWindow` 秒的平均加速度方向。只取末尾而不是整窗平均，
    /// 是因为窗口里还包含用户走到位、调整站姿的过程，整段平均会把这些晃动算进去（见 ADR-0012）。
    static func standingDown(from samples: [TimedSample]) -> SIMD3<Float>? {
        guard let last = samples.last else { return nil }
        return averageDirection(samples, from: max(samples.first?.t ?? last.t, last.t - edgeWindow), to: last.t)
    }

    // MARK: - 抬脚窗口的"动没动"强度

    /// 抬脚窗口里这只脚的峰值速度（m/s），用于左右身份判定（见 ADR-0012）。
    ///
    /// 抬脚发生在站立之前，这时还没有站立基准，所以重力参考取**窗口自己起点的重力方向**（窗口起点静止由点击式交互保证）；
    /// 之后与迈步窗口同一套数值方法：陀螺积分跟踪姿态、去重力、一次积分成速度、零速去趋势，取 `max|v_c(t)|`。
    /// 预期抬脚没有明显旋转，但仍做姿态跟踪，免得转动让重力漏进线性加速度。
    /// 不做漂移自检、不判方向——身份判定只关心"动了多快"。窗口数据不足、时长为零时返回 nil。
    static func motionPeakSpeed(of samples: [TimedSample]) -> Float? {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return nil }
        let duration = last.t - first.t
        guard duration > 0,
              let gravityDirection = averageDirection(samples, from: first.t, to: min(last.t, first.t + edgeWindow))
        else { return nil }

        let attitude = attitudes(samples)
        var velocities: [SIMD3<Float>] = [.zero]
        var v = SIMD3<Float>(repeating: 0)
        for i in 1..<samples.count {
            let dt = Float(samples[i].t - samples[i - 1].t)
            let a0 = attitude[i - 1].act(samples[i - 1].accel) - gravityDirection
            let a1 = attitude[i].act(samples[i].accel) - gravityDirection
            v += (a0 + a1) * 0.5 * dt * gravity
            velocities.append(v)
        }
        let vEnd = velocities[velocities.count - 1]
        var peak: Float = 0
        for i in samples.indices {
            let corrected = velocities[i] - vEnd * (Float(samples[i].t - first.t) / Float(duration))
            peak = max(peak, simd_length(corrected))
        }
        return peak
    }

    // MARK: - 姿态跟踪

    /// 每个采样点的姿态，约定 **v_ref = q.act(v_body)**，q[0] = `initial`（默认单位姿态）。
    /// 反了会得到"能跑但方向全错"的结果，改动时务必保持这个方向（见 ADR-0012 §5「坐标系与单位约定」）。
    /// gyro 的单位是 deg/s，这里转成 rad/s 再积分；用四元数增量累乘并每步归一化，避免长时间累乘后失去正交性。
    static func attitudes(_ samples: [TimedSample], initial: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) -> [simd_quatf] {
        var q = initial
        var out: [simd_quatf] = [q]
        guard samples.count > 1 else { return out }
        for i in 1..<samples.count {
            q = advance(q, gyro: samples[i - 1].gyro, dt: Float(samples[i].t - samples[i - 1].t))
            out.append(q)
        }
        return out
    }

    /// 姿态按上一个采样的角速度积分一个 `dt`。校准流程从站立末尾逐个样本积分时也用它
    /// （见 `CalibrationStreamBuffer.startAttitude`），两处积分规则必须一致，连续姿态才不会在窗口边界出现跳变。
    static func advance(_ q: simd_quatf, gyro: SIMD3<Float>, dt: Float) -> simd_quatf {
        let omega = gyro * (.pi / 180)
        let rate = simd_length(omega)
        guard dt > 0, rate > 1e-6 else { return q }
        return simd_normalize(q * simd_quatf(angle: rate * dt, axis: omega / rate))
    }

    // MARK: - 前轴

    /// 从一个由两次点击界定的窗口算出参考系（见 ADR-0012 §5 的 9 步算法）。整个窗口参与积分；
    /// 迈步窗口用 `segmentedFrame`，先取活动段再积分。
    /// - Parameters:
    ///   - standingDown: 站立步骤测得的"下"基准轴，用于去重力，也是最终输出的 `down` 轴。
    ///   - startAttitude: 窗口第一个样本相对站立体坐标系的姿态（把窗口起点的体坐标向量转到站立体坐标系）。
    ///     调用方从站立末尾连续积分得到；传 nil（流有缺口等）时退回起点重力方向对齐站立 down 的最小旋转。
    static func frame(
        from samples: [TimedSample], standingDown: SIMD3<Float>, startAttitude: simd_quatf? = nil
    ) -> FrameOutcome {
        frameCore(
            from: samples, standingDown: standingDown,
            initialAttitude: { startAttitude ?? simd_quatf(from: $0, to: simd_normalize(standingDown)) },
            source: startAttitude == nil ? .aligned : .continuous,
            rawTiltWhenAligned: startAttitude == nil, enforceStartDrift: startAttitude != nil
        )
    }

    /// 迈步窗口：先在窗口里找出这只脚自己的那一步（活动段，见 `activeSegment`），再对这一段跑 `frame` 的管线
    /// （见 ADR-0012 §5）。窗口里另一只脚的动作和静止段不进入积分。找不到活动帧时用整个窗口。
    /// 区间起点的姿态 = 从窗口起点姿态（`startAttitude`，nil 时退回最小旋转）继续积分陀螺仪到区间起点，窗口内连续。
    static func segmentedFrame(
        from samples: [TimedSample], standingDown: SIMD3<Float>, startAttitude: simd_quatf? = nil
    ) -> FrameOutcome {
        guard samples.count >= 2, let first = samples.first, let last = samples.last,
              let windowDown = averageDirection(samples, from: first.t, to: min(last.t, first.t + edgeWindow))
        else {
            return frame(from: samples, standingDown: standingDown, startAttitude: startAttitude)
        }
        let range = activeSegment(of: samples) ?? samples.startIndex..<samples.endIndex
        let windowInitial = startAttitude ?? simd_quatf(from: windowDown, to: simd_normalize(standingDown))
        let segmentStartAttitude = attitudes(samples, initial: windowInitial)[range.lowerBound]

        let core = frameCore(
            from: Array(samples[range]), standingDown: standingDown,
            initialAttitude: { _ in segmentStartAttitude },
            source: startAttitude == nil ? .aligned : .continuous,
            rawTiltWhenAligned: false, enforceStartDrift: startAttitude != nil
        )
        var diagnostics = core.diagnostics
        diagnostics.segmentStartT = samples[range.lowerBound].t - first.t
        diagnostics.segmentEndT = samples[range.upperBound - 1].t - first.t
        return FrameOutcome(result: core.result, diagnostics: diagnostics)
    }

    /// 活动段：最长活动簇前后各延长 `segmentMargin`，截在窗口内（见 ADR-0012 §5 步骤 0）。没有活动帧返回 nil。
    static func activeSegment(of samples: [TimedSample]) -> Range<Int>? {
        guard samples.count >= 2 else { return nil }
        let active = samples.indices.filter {
            simd_length(samples[$0].gyro) > activityGyro || abs(simd_length(samples[$0].accel) - 1) > activityAccel
        }
        guard let firstActive = active.first else { return nil }

        var clusters: [(start: Int, end: Int)] = []
        var start = firstActive
        var previous = firstActive
        for i in active.dropFirst() {
            if samples[i].t - samples[previous].t > activityGap {
                clusters.append((start, previous))
                start = i
            }
            previous = i
        }
        clusters.append((start, previous))

        // 持续时间最长的一簇；时长相同取靠前的
        var best = clusters[0]
        for cluster in clusters.dropFirst()
        where samples[cluster.end].t - samples[cluster.start].t > samples[best.end].t - samples[best.start].t {
            best = cluster
        }
        let epsilon = 1e-9
        let from = samples[best.start].t - segmentMargin - epsilon
        let to = samples[best.end].t + segmentMargin + epsilon
        let lower = samples.indices.first { samples[$0].t >= from } ?? best.start
        let upper = samples.indices.last { samples[$0].t <= to } ?? best.end
        return lower..<(upper + 1)
    }

    /// `frame` 与 `segmentedFrame` 共用的管线。
    /// - Parameters:
    ///   - initialAttitude: 由积分区间起点的重力方向给出区间第一个样本的姿态。
    ///   - rawTiltWhenAligned: `aligned` 且不分段时，从站立起的累计漂移字段记录的是对齐前的原始倾角（只留档）。
    ///   - enforceStartDrift: 起点姿态来自连续积分时，从站立起的累计漂移超出容差判 `driftTooLarge`。
    private static func frameCore(
        from samples: [TimedSample], standingDown: SIMD3<Float>,
        initialAttitude: (SIMD3<Float>) -> simd_quatf,
        source: StartAttitudeSource, rawTiltWhenAligned: Bool, enforceStartDrift: Bool
    ) -> FrameOutcome {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else {
            return FrameOutcome(
                result: .insufficientData,
                diagnostics: FrameDiagnostics(windowDuration: 0, sampleCount: samples.count)
            )
        }
        let duration = last.t - first.t

        // 1. 重力基准：去重力用调用方传入的站立基准；downStart/downEnd 只是这个窗口两端的重力方向观测，仅供漂移自检使用。
        let downStart = averageDirection(samples, from: first.t, to: min(last.t, first.t + edgeWindow))
        let downEnd = averageDirection(samples, from: max(first.t, last.t - edgeWindow), to: last.t)

        var diagnostics = FrameDiagnostics(
            downStart: downStart, downEnd: downEnd, windowDuration: duration, sampleCount: samples.count
        )

        guard duration > 0, let downStart, let downEnd else {
            return FrameOutcome(result: .insufficientData, diagnostics: diagnostics)
        }

        // 2. 姿态跟踪：起点姿态以站立体坐标系为基准（ADR-0012 §5）。连续积分得到的起点姿态把起点重力方向转回站立系后，
        // 应当与站立 down 重合，夹角是"从站立到窗口起点"的累计漂移，超出容差同样判数据不可信。
        let initial = initialAttitude(downStart)
        diagnostics.startAttitudeSource = source
        // continuous：累计漂移；aligned（不分段）：对齐前的起点倾角（留档，不判失败——脚可能本来就抬起倾斜，是正常情形）
        let startDrift = angleDegrees(source == .aligned && rawTiltWhenAligned ? downStart : initial.act(downStart), standingDown)
        diagnostics.startDriftDegrees = startDrift
        guard !enforceStartDrift || startDrift <= driftToleranceDegrees else {
            return FrameOutcome(result: .driftTooLarge, diagnostics: diagnostics)
        }
        let attitude = attitudes(samples, initial: initial)

        // 3. 积分漂移自检：重力方向在世界系下不变，ΔR(T)·downEnd 理应与 ΔR(0)·downStart 重合，偏差即窗口内的累积漂移。
        // 参照物取本窗口起点而不是站立 down：这一步只测窗口内的漂移，从站立起的累计漂移由上面的 startDrift 单独把关。
        let driftDegrees = angleDegrees(attitude[attitude.count - 1].act(downEnd), attitude[0].act(downStart))
        diagnostics.driftDegrees = driftDegrees
        guard driftDegrees <= driftToleranceDegrees else {
            return FrameOutcome(result: .driftTooLarge, diagnostics: diagnostics)
        }

        // 4-6. 去重力（a_ref = ΔR(t)·accel(t) − standingDown）→ 一次积分（梯形）→ 零速去趋势
        var velocities: [SIMD3<Float>] = [.zero]
        var v = SIMD3<Float>(repeating: 0)
        for i in 1..<samples.count {
            let dt = Float(samples[i].t - samples[i - 1].t)
            let a0 = attitude[i - 1].act(samples[i - 1].accel) - standingDown
            let a1 = attitude[i].act(samples[i].accel) - standingDown
            v += (a0 + a1) * 0.5 * dt * gravity
            velocities.append(v)
        }
        let span = Float(duration)
        let vEnd = velocities[velocities.count - 1]
        let corrected = samples.indices.map { i in
            velocities[i] - vEnd * (Float(samples[i].t - first.t) / span)
        }

        // 7. 取方向：位移方向只用其方向，不用模长；峰值速度顺带算出。路径长度按投影掉 down 轴分量之后的
        // 水平速度累计，不用完整 3D 速度——迈步必然抬脚，抬脚产生的路程对净位移贡献趋近于 0，但会原样
        // 累进路径长度，若不投影会把"抬脚抬多高"这个跟方向无关的量也算进方向一致性判据里（见 ADR-0012
        // 「为什么方向一致性判定要先投影掉 down 轴」）。峰值速度不投影，身份判定要看"这只脚动没动"，跟方向无关。
        let down = simd_normalize(standingDown)
        var displacement = SIMD3<Float>(repeating: 0)
        var planarPathLength: Float = 0
        var peakSpeed: Float = 0
        for i in 1..<samples.count {
            let dt = Float(samples[i].t - samples[i - 1].t)
            let mid = (corrected[i] + corrected[i - 1]) * 0.5
            displacement += mid * dt
            let planar0 = corrected[i - 1] - simd_dot(corrected[i - 1], down) * down
            let planar1 = corrected[i] - simd_dot(corrected[i], down) * down
            planarPathLength += (simd_length(planar0) + simd_length(planar1)) * 0.5 * dt
            peakSpeed = max(peakSpeed, simd_length(corrected[i]))
        }
        diagnostics.peakSpeed = peakSpeed

        guard planarPathLength > 0 else {
            return FrameOutcome(result: .directionUnclear, diagnostics: diagnostics)
        }

        // 8. 正交化：投影是线性运算，先积分再投影和先投影再积分结果相同，这里直接复用整段位移的投影结果。
        let planar = displacement - simd_dot(displacement, down) * down
        guard simd_length(planar) > 1e-6 else {
            return FrameOutcome(result: .directionUnclear, diagnostics: diagnostics)
        }

        // 9. 质量判定：只判方向一致性（分子分母都只统计水平分量），峰值速度不在这里判失败，
        // 由调用方按 ADR-0012 的规则决定怎么用。
        let coherence = simd_length(planar) / planarPathLength
        diagnostics.coherence = coherence
        guard coherence >= minDirectionCoherence else {
            return FrameOutcome(result: .directionUnclear, diagnostics: diagnostics)
        }

        let front = simd_normalize(planar)
        let frame = SensorOrientationFrame(down: down, front: front, left: simd_normalize(simd_cross(down, front)))
        return FrameOutcome(result: .frame(frame), diagnostics: diagnostics)
    }

    static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        guard simd_length(a) > 1e-6, simd_length(b) > 1e-6 else { return .greatestFiniteMagnitude }
        let cosine = max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))
        return acos(cosine) * 180 / .pi
    }

    // MARK: - 左右身份判定（见 ADR-0012）

    /// 相对比较：只要求较大的一侧过绝对下限（证明确实有一侧产生了可信的平动）；较小的一侧越接近 0 说明区分度越好，
    /// 不要求两侧都过下限——"没在动的那一脚峰值速度接近 0"本身就是预期中的正常信号，不是数据不足。
    static func compare(_ a: Float, _ b: Float) -> ComparisonOutcome {
        let larger = max(a, b)
        let smaller = min(a, b)
        guard larger >= minPeakSpeed else { return .tooWeak }
        guard smaller <= 0 || larger / smaller >= minSeparationRatio else { return .tooClose }
        return .winner(firstWins: a >= b)
    }
}
