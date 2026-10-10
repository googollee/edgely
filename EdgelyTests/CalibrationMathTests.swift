import XCTest
import simd
@testable import Edgely

/// `CalibrationMath` 是纯计算类型（不依赖设备适配层/CoreBluetooth），
/// 这里直接构造理想的 `TimedSample` 序列喂给它，不需要 mock 任何接口。
final class CalibrationMathTests: XCTestCase {

    /// 测试信号统一按 50Hz 构造（校准阶段的实际速率，见 AppCoordinator）
    private let dt: TimeInterval = 0.02

    // MARK: - 测试数据构造

    /// "下"方向固定取 -Z，前进方向取 +X。
    /// 注意静止时 accel 的方向就是 down 方向——这是 `CalibrationMath` 既有的约定（见 standingDown），
    /// 下面所有信号都按这个约定构造，保持与被测代码自洽。
    private let down = SIMD3<Float>(0, 0, -1)
    private let forward = SIMD3<Float>(1, 0, 0)

    /// 一次理想迈步：静止 → 匀加速 → 匀减速 → 静止。加速段与减速段等时长、等幅度，
    /// 因此起止速度都是 0、加速度的正负面积严格相等（ADR-0012 §5：为什么用速度而不是加速度）。
    ///
    /// 窗口不再搜索静止段（见 ADR-0012，静止性完全交给点击式交互），`frame()` 直接对整个数组积分，
    /// 首尾这段"静止"信号只是为了让端点取样（downStart/downEnd）取到有意义的重力方向观测。
    ///
    /// 动作期间传感器绕"下"轴匀速转动，这是真实迈步的样子（脚在动就必然在转）。绕"下"轴转的好处是
    /// 重力在体坐标下保持不变，信号容易构造得自洽：参考系下的线性加速度反向旋转一次就是体坐标下的读数。
    /// - Parameter bias: 注入到每一帧 accel 上的恒定偏置，用来模拟重力补偿残差 + 加速度计零偏
    private func stepSignal(
        amplitude: Float = 0.2,
        accelerateSeconds: TimeInterval = 0.3,
        bias: SIMD3<Float> = .zero,
        leadingQuiet: TimeInterval = 0.4,
        trailingQuiet: TimeInterval = 0.4,
        direction: SIMD3<Float>? = nil,
        rotationRate: Float = 60 // deg/s
    ) -> [TimedSample] {
        let dir = direction ?? forward
        let spin = down * rotationRate
        var samples: [TimedSample] = []
        func append(_ accel: SIMD3<Float>, _ gyro: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel + bias, gyro: gyro))
        }

        for _ in 0..<Int(leadingQuiet / dt) { append(down, .zero) }
        let motionCount = Int(accelerateSeconds / dt) * 2
        for i in 0..<motionCount {
            let sign: Float = i < motionCount / 2 ? 1 : -1
            let turned = rotationRate * (.pi / 180) * Float(i) * Float(dt)
            let linearInBody = simd_quatf(angle: -turned, axis: down).act(dir) * amplitude * sign
            append(down + linearInBody, spin)
        }
        for _ in 0..<Int(trailingQuiet / dt) { append(down, .zero) }
        return samples
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    private func assertDirection(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, toleranceDegrees: Float = 5, file: StaticString = #filePath, line: UInt = #line) {
        let cosine = max(-1, min(1, simd_dot(simd_normalize(actual), simd_normalize(expected))))
        let degrees = acos(cosine) * 180 / .pi
        XCTAssertLessThanOrEqual(degrees, toleranceDegrees, "方向偏差 \(degrees)°", file: file, line: line)
    }

    private func outcome(of samples: [TimedSample], standingDown: SIMD3<Float>? = nil) -> CalibrationMath.FrameOutcome {
        CalibrationMath.frame(from: samples, standingDown: standingDown ?? down)
    }

    private func frame(of samples: [TimedSample], standingDown: SIMD3<Float>? = nil) -> SensorOrientationFrame? {
        guard case .frame(let f) = outcome(of: samples, standingDown: standingDown).result else { return nil }
        return f
    }

    // MARK: - standingDown(from:)

    func test_standingDown_usesTrailingWindowOnly() {
        // 前半段方向不同（走到位、调整站姿的过程），只有末尾 edgeWindow 秒是真正站定的读数
        var samples: [TimedSample] = []
        for i in 0..<20 {
            samples.append(TimedSample(t: Double(i) * dt, accel: SIMD3(0.5, 0, -0.8), gyro: SIMD3(30, 0, 0)))
        }
        for i in 20..<60 {
            samples.append(TimedSample(t: Double(i) * dt, accel: down, gyro: .zero))
        }
        let result = CalibrationMath.standingDown(from: samples)
        XCTAssertNotNil(result)
        assertEqual(result!, down)
    }

    /// 新算法不做静止性验证（见 ADR-0012）：哪怕末尾仍在动，也直接把这段读数当基准，不返回 nil。
    /// 这条测试锁定的是这个有意为之的设计决策，不是"应该失败但没失败"。
    func test_standingDown_stillReturnsValue_evenIfTrailingWindowIsMoving() {
        let stillMoving = (0..<60).map {
            TimedSample(t: Double($0) * dt, accel: down, gyro: SIMD3(40, 0, 0))
        }
        XCTAssertNotNil(CalibrationMath.standingDown(from: stillMoving))
    }

    func test_standingDown_emptySamples_returnsNil() {
        XCTAssertNil(CalibrationMath.standingDown(from: []))
    }

    // MARK: - frame(from:standingDown:) 成功路径 —— 见 ADR-0012

    func test_frame_idealStep_pointsAlongTravelDirection() {
        let result = frame(of: stepSignal())
        XCTAssertNotNil(result)
        assertDirection(result!.front, forward)
        assertEqual(result!.down, down)

        // 三轴应两两正交、单位长度
        XCTAssertEqual(simd_length(result!.front), 1, accuracy: 0.0001)
        XCTAssertEqual(simd_length(result!.left), 1, accuracy: 0.0001)
        XCTAssertEqual(simd_dot(result!.down, result!.front), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_dot(result!.down, result!.left), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_dot(result!.front, result!.left), 0, accuracy: 0.0001)
    }

    func test_frame_backwardStep_pointsBackward() {
        let result = frame(of: stepSignal(direction: -forward))
        XCTAssertNotNil(result)
        assertDirection(result!.front, -forward)
    }

    /// 回归用例，锁住 ADR-0012 §5 选速度方向的理由：迈步起止速度都是 0，加速段与减速段的加速度正负面积严格相等，
    /// 所以任何对加速度做"净方向"统计的方法都会失效——这里先证明这段理想信号的加速度净和确实接近 0
    /// （即净方向统计法拿不到任何方向信息），再证明速度积分法仍然给出正确方向。
    func test_frame_netAccelerationCancels_butVelocityDirectionSurvives() {
        // 去掉旋转，直接看动作段（前 0.4s 静止 = 20 帧，动作 0.6s = 30 帧）的加速度净和
        let plain = stepSignal(rotationRate: 0)
        var netAccel = SIMD3<Float>(repeating: 0)
        for i in 20..<50 { netAccel += plain[i].accel - down }
        XCTAssertLessThan(simd_length(netAccel), 0.01, "理想迈步的加速度净和接近 0：净方向统计法在这里拿不到任何方向信息")

        // 同一个动作，速度积分法仍然给出正确方向
        let result = frame(of: stepSignal())
        XCTAssertNotNil(result)
        assertDirection(result!.front, forward)
    }

    /// 零速去趋势的价值：恒定的重力补偿残差 / 加速度计零偏会在速度里积成一个线性项，
    /// 而动作末端真实速度必然为 0，按时间线性扣掉即可一阶消除（见 ADR-0012 §5）。
    func test_frame_constantAccelBias_isRemovedByDetrending() {
        let biased = stepSignal(bias: SIMD3(0.02, 0.01, 0))
        let result = frame(of: biased)
        XCTAssertNotNil(result)
        assertDirection(result!.front, forward, toleranceDegrees: 10)
    }

    /// 姿态补偿的压力测试：转得更快、动作更长，体坐标系在动作期间整整转过 180°。
    /// 补偿正确的话各帧转回参考系后仍然指向同一个方向；补偿反了或漏了，方向会被抹平或指偏。
    func test_frame_fastRotation_compensatesAttitude() {
        let result = frame(of: stepSignal(accelerateSeconds: 0.5, rotationRate: 180))
        XCTAssertNotNil(result)
        assertDirection(result!.front, forward, toleranceDegrees: 10)
    }

    /// 峰值速度不由 frame() 判失败（见 ADR-0012「失败处理」）：振幅很小的动作依然应当成功给出方向，
    /// 只是 diagnostics.peakSpeed 会很低——"够不够明显"是调用方（ADR-0012）的事。
    func test_frame_tinyAmplitude_stillSucceeds_withLowPeakSpeed() {
        let result = outcome(of: stepSignal(amplitude: 0.002))
        guard case .frame = result.result else {
            return XCTFail("振幅小不应该导致 frame() 失败")
        }
        XCTAssertNotNil(result.diagnostics.peakSpeed)
        XCTAssertLessThan(result.diagnostics.peakSpeed!, CalibrationMath.minPeakSpeed)
    }

    // MARK: - 姿态基准：窗口起点相对站立姿态倾斜 + 偏航（ADR-0012 §5）

    /// 把一个"窗口起点体坐标系 = 站立体坐标系"的信号，改写成"窗口起点体坐标系相对站立体坐标系转了 `startAttitude`"：
    /// 同一个真实动作，体坐标下的每个读数反向转一次。
    private func rewritten(_ samples: [TimedSample], startAttitude q0: simd_quatf) -> [TimedSample] {
        samples.map {
            TimedSample(t: $0.t, accel: q0.inverse.act($0.accel), gyro: q0.inverse.act($0.gyro))
        }
    }

    private func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
    }

    /// 起点倾斜 40°、再偏航 30°：传入连续积分得到的起点姿态后，front 仍是站立系下的真实前进方向。
    func test_frame_continuousStartAttitude_recoversTrueDirection_underTiltAndYaw() {
        let q0 = simd_quatf(angle: 30 * .pi / 180, axis: down) * simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let samples = rewritten(stepSignal(), startAttitude: q0)

        let result = CalibrationMath.frame(from: samples, standingDown: down, startAttitude: q0)

        guard case .frame(let f) = result.result else { return XCTFail("应当成功：\(result.result)") }
        assertDirection(f.front, forward, toleranceDegrees: 3)
        XCTAssertEqual(result.diagnostics.startAttitudeSource, .continuous)
        XCTAssertEqual(result.diagnostics.startDriftDegrees!, 0, accuracy: 0.1, "起点姿态与实测重力一致，累计漂移为 0")
    }

    /// 退路（没有连续姿态）只对齐重力：倾斜能修，偏航修不了，front 带着偏航误差。诊断里标明来源和起点倾角。
    func test_frame_alignedFallback_fixesTiltButNotYaw() {
        let tilt = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let tiltOnly = rewritten(stepSignal(), startAttitude: tilt)
        let tiltResult = CalibrationMath.frame(from: tiltOnly, standingDown: down)
        guard case .frame(let tiltFrame) = tiltResult.result else { return XCTFail("\(tiltResult.result)") }
        assertDirection(tiltFrame.front, forward, toleranceDegrees: 3)
        XCTAssertEqual(tiltResult.diagnostics.startAttitudeSource, .aligned)
        XCTAssertEqual(tiltResult.diagnostics.startDriftDegrees!, 40, accuracy: 0.5, "aligned 时记录的是对齐前的起点倾角")

        let q0 = simd_quatf(angle: 30 * .pi / 180, axis: down) * tilt
        let yawed = rewritten(stepSignal(), startAttitude: q0)
        guard case .frame(let yawFrame) = CalibrationMath.frame(from: yawed, standingDown: down).result else { return XCTFail() }
        XCTAssertGreaterThan(angleDegrees(yawFrame.front, forward), 10, "最小旋转不约束偏航，所以偏航误差留在 front 里")
    }

    /// 从站立起的累计漂移超出容差：连续姿态与起点实测重力对不上，判数据不可信，诊断带上数值。
    func test_frame_startDriftTooLarge_whenContinuousAttitudeContradictsMeasuredGravity() {
        let wrong = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let result = CalibrationMath.frame(from: stepSignal(), standingDown: down, startAttitude: wrong)

        XCTAssertEqual(result.result, .driftTooLarge)
        XCTAssertGreaterThan(result.diagnostics.startDriftDegrees!, CalibrationMath.driftToleranceDegrees)
        XCTAssertNil(result.diagnostics.driftDegrees, "窗口内漂移还没测就已经失败")
    }

    // MARK: - frame(from:standingDown:) 失败路径

    func test_frame_driftTooLarge_whenMeasuredGravityContradictsGyroIntegration() {
        var samples: [TimedSample] = []
        func append(_ accel: SIMD3<Float>, _ gyro: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: gyro))
        }
        for _ in 0..<20 { append(down, .zero) } // 前静止段 0.4s
        // 绕 Y 轴（不是 down 轴）转 90°：真实物理上这会改变体坐标系下测到的重力方向
        for _ in 0..<Int(0.3 / dt) { append(down + forward * 0.2, SIMD3(0, 300, 0)) }
        // 后静止段的读数却和前静止段完全一样——跟陀螺仪积分推算出的姿态对不上，构造出可检测的漂移
        for _ in 0..<20 { append(down, .zero) }

        let result = outcome(of: samples)
        XCTAssertEqual(result.result, .driftTooLarge)
        XCTAssertNotNil(result.diagnostics.driftDegrees, "失败也要带上诊断数值，供落盘分析（见 ADR-0012）")
        XCTAssertGreaterThan(result.diagnostics.driftDegrees!, CalibrationMath.driftToleranceDegrees)
    }

    func test_frame_directionUnclear_whenMotionZigzags() {
        var samples: [TimedSample] = []
        let spin = down * 2 // deg/s，只为让端点取样之外的这段数据不至于被误判静止，转动量小到可忽略
        func append(_ accel: SIMD3<Float>, _ gyro: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: gyro))
        }
        for _ in 0..<20 { append(down, .zero) } // 前静止段

        // 先朝前一个来回（加速+减速），再朝后一个来回，幅度、时长完全对称：净位移接近抵消，
        // 但路径长度是两段之和——应当判定方向不明确。
        let quarter = 8
        for _ in 0..<quarter { append(down + forward * 0.2, spin) }
        for _ in 0..<quarter { append(down - forward * 0.2, spin) }
        for _ in 0..<quarter { append(down - forward * 0.2, spin) }
        for _ in 0..<quarter { append(down + forward * 0.2, spin) }

        for _ in 0..<20 { append(down, .zero) } // 后静止段

        let result = outcome(of: samples)
        XCTAssertEqual(result.result, .directionUnclear)
        XCTAssertNotNil(result.diagnostics.coherence)
        XCTAssertLessThan(result.diagnostics.coherence!, CalibrationMath.minDirectionCoherence)
    }

    /// 迈步必然要抬脚：脚从地面抬起、越过一定高度、再落回地面，这段 down 轴方向的路程对净位移贡献趋近于 0，
    /// 但会原样累积进路程。这里构造一个水平方向单调、干净的迈步（净位移=路程，理应满分），叠加一段抬脚幅度
    /// 是水平幅度 4 倍的垂直起落（净位移趋近于 0），验证方向一致性判据不会被这段垂直路程拖累而误判失败
    /// （见 ADR-0012「为什么方向一致性判定要先投影掉 down 轴」）。
    func test_frame_coherence_ignoresVerticalLiftPathLength() {
        var samples: [TimedSample] = []
        let up = -down
        func append(_ accel: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: .zero))
        }
        for _ in 0..<20 { append(down) } // 前静止段

        // 水平：前两个 quarter 匀加速、后两个 quarter 匀减速——速度全程不变号，是一次干净的单向迈步。
        // 垂直：quarter 0/3 向上、quarter 1/2 向下（幅度是水平的 4 倍）——抬起又落回原高度，净位移趋近于 0。
        let quarter = 8
        let horizontal: Float = 0.2
        let vertical: Float = 0.8
        for _ in 0..<quarter { append(down + forward * horizontal + up * vertical) }
        for _ in 0..<quarter { append(down + forward * horizontal - up * vertical) }
        for _ in 0..<quarter { append(down - forward * horizontal - up * vertical) }
        for _ in 0..<quarter { append(down - forward * horizontal + up * vertical) }

        for _ in 0..<20 { append(down) } // 后静止段

        let result = outcome(of: samples)
        XCTAssertNotNil(result.diagnostics.coherence)
        XCTAssertGreaterThanOrEqual(result.diagnostics.coherence!, CalibrationMath.minDirectionCoherence)
        guard case .frame(let frame) = result.result else {
            return XCTFail("抬脚不应拖累方向一致性判定，实际结果：\(result.result)")
        }
        assertDirection(frame.front, forward)
        assertEqual(frame.down, down)
    }

    func test_frame_emptySamples_isInsufficientData() {
        let result = outcome(of: [])
        XCTAssertEqual(result.result, .insufficientData)
        XCTAssertEqual(result.diagnostics.sampleCount, 0)
    }

    func test_frame_singleSample_isInsufficientData() {
        let result = outcome(of: [TimedSample(t: 0, accel: down, gyro: .zero)])
        XCTAssertEqual(result.result, .insufficientData)
    }

    func test_frame_zeroDuration_isInsufficientData() {
        // 两个样本时间戳相同：没有 Δt，积分无从谈起
        let samples = [
            TimedSample(t: 0, accel: down, gyro: .zero),
            TimedSample(t: 0, accel: down, gyro: .zero)
        ]
        XCTAssertEqual(outcome(of: samples).result, .insufficientData)
    }

    // MARK: - compare(_:_:) —— 见 ADR-0012 §3（峰值速度域：绝对下限 0.15 m/s，相对区分度 3x）

    func test_compare_clearWinner_firstWins() {
        XCTAssertEqual(CalibrationMath.compare(1.0, 0.2), .winner(firstWins: true))
    }

    func test_compare_clearWinner_secondWins() {
        XCTAssertEqual(CalibrationMath.compare(0.2, 1.0), .winner(firstWins: false))
    }

    func test_compare_otherSideNearZero_isWinner() {
        // 单传感器场景的核心用例：没戴传感器的那只脚做动作时，这一侧读数接近 0 是正常现象，
        // 不应该被判定为"数据不足"，而应该直接判定另一侧为 winner（见 ADR-0012）。
        XCTAssertEqual(CalibrationMath.compare(0.5, 0), .winner(firstWins: true))
        XCTAssertEqual(CalibrationMath.compare(0, 0.5), .winner(firstWins: false))
    }

    func test_compare_bothBelowFloor_isTooWeak() {
        XCTAssertEqual(CalibrationMath.compare(0.1, 0.05), .tooWeak)
    }

    func test_compare_ratioTooClose_isTooClose() {
        // 0.3 / 0.15 = 2x，低于 3x 的相对区分度阈值，尽管两侧都过了绝对下限
        XCTAssertEqual(CalibrationMath.compare(0.3, 0.15), .tooClose)
    }

    func test_compare_ratioExactlyAtThreshold_isWinner() {
        // 0.75 / 0.25 = 3x，正好达到阈值，应判定为 winner
        XCTAssertEqual(CalibrationMath.compare(0.75, 0.25), .winner(firstWins: true))
    }

    func test_compare_onlyLargerSideNeedsToClearFloor() {
        // 较大一侧（0.6）过了绝对下限（0.15），较小一侧（0.05）远低于下限——
        // 这不该判定为 tooWeak，因为"较小一侧没怎么动"本身就是预期信号，只要比值够大就该判定为 winner。
        XCTAssertEqual(CalibrationMath.compare(0.6, 0.05), .winner(firstWins: true))
    }

    // MARK: - motionPeakSpeed(of:) —— 抬脚窗口的"动没动"强度，见 ADR-0012

    /// 一次理想的抬脚：静止 → 竖直方向（沿 down 的反方向）匀加速 → 匀减速 → 静止，没有旋转。
    /// 加速段与减速段等时长、等幅度，起止速度都是 0。
    private func liftSignal(amplitude: Float = 0.3, accelerateSeconds: TimeInterval = 0.3, quiet: TimeInterval = 0.4) -> [TimedSample] {
        var samples: [TimedSample] = []
        func append(_ accel: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: .zero))
        }
        for _ in 0..<Int(quiet / dt) { append(down) }
        let motionCount = Int(accelerateSeconds / dt) * 2
        for i in 0..<motionCount {
            let sign: Float = i < motionCount / 2 ? 1 : -1
            append(down + (-down) * amplitude * sign)
        }
        for _ in 0..<Int(quiet / dt) { append(down) }
        return samples
    }

    func test_motionPeakSpeed_liftIsClearlyAboveStillWindow() {
        let lift = CalibrationMath.motionPeakSpeed(of: liftSignal())
        let still = CalibrationMath.motionPeakSpeed(of: (0..<50).map { TimedSample(t: Double($0) * dt, accel: down, gyro: .zero) })
        XCTAssertNotNil(lift)
        XCTAssertNotNil(still)
        XCTAssertGreaterThan(lift!, CalibrationMath.minPeakSpeed)
        XCTAssertLessThan(still!, 0.01)
    }

    /// 峰值速度的物理量级：匀加速 a（m/s²）持续 T 秒，峰值速度 = a·T。
    func test_motionPeakSpeed_matchesPhysicalMagnitude() {
        let amplitudeG: Float = 0.3
        let accelerateSeconds: TimeInterval = 0.3
        let peak = CalibrationMath.motionPeakSpeed(of: liftSignal(amplitude: amplitudeG, accelerateSeconds: accelerateSeconds))!
        let expected = amplitudeG * CalibrationMath.gravity * Float(accelerateSeconds)
        XCTAssertEqual(peak, expected, accuracy: expected * 0.1)
    }

    /// 重力基准取窗口自己的起点：不需要也不依赖站立基准，传感器朝向任意都行。
    func test_motionPeakSpeed_worksForArbitrarySensorOrientation() {
        let tilt = simd_quatf(angle: 70 * .pi / 180, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        let rotated = liftSignal().map { TimedSample(t: $0.t, accel: tilt.act($0.accel), gyro: .zero) }
        let upright = CalibrationMath.motionPeakSpeed(of: liftSignal())!
        let tilted = CalibrationMath.motionPeakSpeed(of: rotated)!
        XCTAssertEqual(tilted, upright, accuracy: upright * 0.02)
    }

    /// 动作期间带转动时，姿态跟踪让重力不漏进线性加速度：绕"下"轴匀速转，峰值速度与不转时一致。
    func test_motionPeakSpeed_isStableUnderRotationAboutDown() {
        let rate: Float = 60
        let base = liftSignal()
        // 体坐标系随脚一起绕 down 轴转：竖直方向的加速度不受影响，只需给陀螺加上转速
        let spun = base.map { TimedSample(t: $0.t, accel: $0.accel, gyro: down * rate) }
        let plain = CalibrationMath.motionPeakSpeed(of: base)!
        let withSpin = CalibrationMath.motionPeakSpeed(of: spun)!
        XCTAssertEqual(withSpin, plain, accuracy: plain * 0.05)
    }

    func test_motionPeakSpeed_emptyOrSingleSample_isNil() {
        XCTAssertNil(CalibrationMath.motionPeakSpeed(of: []))
        XCTAssertNil(CalibrationMath.motionPeakSpeed(of: [TimedSample(t: 0, accel: down, gyro: .zero)]))
    }

    func test_motionPeakSpeed_zeroDuration_isNil() {
        let samples = [TimedSample(t: 0, accel: down, gyro: .zero), TimedSample(t: 0, accel: down, gyro: .zero)]
        XCTAssertNil(CalibrationMath.motionPeakSpeed(of: samples))
    }

    // MARK: - activeSegment(of:) / segmentedFrame —— 迈步窗口取活动段再积分，见 ADR-0012 §5 步骤 0

    private func quiet(_ seconds: TimeInterval, from start: Int) -> [TimedSample] {
        (0..<Int(seconds / dt)).map { TimedSample(t: Double(start + $0) * dt, accel: down, gyro: .zero) }
    }

    /// 把几段信号按顺序拼成一个窗口，`t` 连续。
    private func concatenated(_ parts: [[TimedSample]]) -> [TimedSample] {
        var out: [TimedSample] = []
        for part in parts {
            for sample in part {
                out.append(TimedSample(t: Double(out.count) * dt, accel: sample.accel, gyro: sample.gyro))
            }
        }
        return out
    }

    /// 另一只脚落地造成的单帧冲击：只有一帧的大加速度，之后立即回到静止。
    private func spike(_ along: SIMD3<Float>, g: Float = 2) -> [TimedSample] {
        [TimedSample(t: 0, accel: down + along * g, gyro: .zero)]
    }

    func test_activeSegment_coversTheBurstPlusMarginOnBothSides() {
        let step = stepSignal(leadingQuiet: 0, trailingQuiet: 0) // 0.6 秒，全程都在动
        let window = concatenated([quiet(1.5, from: 0), step, quiet(1.5, from: 0)])

        let range = CalibrationMath.activeSegment(of: window)!

        let burstStart = Int(1.5 / dt)
        let burstEnd = burstStart + step.count - 1
        let margin = Int(CalibrationMath.segmentMargin / dt)
        XCTAssertEqual(range.lowerBound, burstStart - margin)
        XCTAssertEqual(range.upperBound - 1, burstEnd + margin, "区间是半开区间，最后一个样本是 upperBound − 1")
    }

    func test_activeSegment_ignoresIsolatedSingleFrameSpike_picksLongestBurst() {
        // 静止 1.0 秒 → 单帧尖峰 → 静止 0.6 秒 → 真正的迈步 → 静止
        let step = stepSignal(leadingQuiet: 0, trailingQuiet: 0)
        let window = concatenated([quiet(1.0, from: 0), spike(SIMD3(0, 1, 0)), quiet(0.6, from: 0), step, quiet(1.0, from: 0)])

        let range = CalibrationMath.activeSegment(of: window)!

        let stepStart = Int(1.0 / dt) + 1 + Int(0.6 / dt)
        XCTAssertGreaterThan(range.lowerBound, Int(1.0 / dt) + 1, "尖峰之后的静止段不应被划进积分区间")
        XCTAssertLessThanOrEqual(range.lowerBound, stepStart)
    }

    func test_activeSegment_isClippedToTheWindow() {
        // 动作紧贴窗口开头：区间起点不能小于 0
        let window = concatenated([stepSignal(leadingQuiet: 0, trailingQuiet: 0), quiet(1.5, from: 0)])
        let range = CalibrationMath.activeSegment(of: window)!
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertLessThan(range.upperBound, window.count)
    }

    func test_activeSegment_noActivity_isNil() {
        XCTAssertNil(CalibrationMath.activeSegment(of: quiet(2, from: 0)))
        XCTAssertNil(CalibrationMath.activeSegment(of: []))
    }

    /// 传感器所在脚后迈：前面有一段静止、其间有另一只脚落地的冲击尖峰。整窗口积分会被尖峰带偏，
    /// 分段积分只对自己的那一步积分，方向正确（见 ADR-0012 §5 步骤 0）。
    func test_segmentedFrame_ignoresIdlePrefixWithImpactSpike() {
        let window = concatenated([quiet(0.8, from: 0), spike(SIMD3(0, 1, 0), g: 3), quiet(0.7, from: 0), stepSignal(direction: forward), quiet(0.2, from: 0)])

        let segmented = CalibrationMath.segmentedFrame(from: window, standingDown: down)
        let whole = CalibrationMath.frame(from: window, standingDown: down)

        guard case .frame(let good) = segmented.result else { return XCTFail("分段积分应当成功：\(segmented.result)") }
        assertDirection(good.front, forward, toleranceDegrees: 3)
        if case .frame(let bad) = whole.result {
            let cosine = max(-1, min(1, simd_dot(simd_normalize(bad.front), forward)))
            XCTAssertGreaterThan(acos(cosine) * 180 / .pi, 5, "整窗口积分应当被尖峰带偏，否则这个用例没有区分度")
        }
        XCTAssertGreaterThan(segmented.diagnostics.coherence ?? 0, whole.diagnostics.coherence ?? 1)
    }

    func test_segmentedFrame_diagnosticsDescribeTheSegment() {
        let window = concatenated([quiet(1.0, from: 0), stepSignal(leadingQuiet: 0, trailingQuiet: 0), quiet(1.0, from: 0)])
        let range = CalibrationMath.activeSegment(of: window)!

        let result = CalibrationMath.segmentedFrame(from: window, standingDown: down)

        XCTAssertEqual(result.diagnostics.segmentStartT ?? -1, window[range.lowerBound].t, accuracy: 1e-9)
        XCTAssertEqual(result.diagnostics.segmentEndT ?? -1, window[range.upperBound - 1].t, accuracy: 1e-9)
        XCTAssertEqual(result.diagnostics.sampleCount, range.count, "判定用的采样数是积分区间的")
        XCTAssertEqual(result.diagnostics.windowDuration, window[range.upperBound - 1].t - window[range.lowerBound].t, accuracy: 1e-9)
    }

    func test_segmentedFrame_startAttitudeSource_followsWhetherCallerProvidedOne() {
        let window = concatenated([quiet(0.8, from: 0), stepSignal(leadingQuiet: 0, trailingQuiet: 0), quiet(0.8, from: 0)])
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        XCTAssertEqual(CalibrationMath.segmentedFrame(from: window, standingDown: down, startAttitude: identity).diagnostics.startAttitudeSource, .continuous)
        XCTAssertEqual(CalibrationMath.segmentedFrame(from: window, standingDown: down).diagnostics.startAttitudeSource, .aligned)
    }

    /// 起点倾斜 40° 时，分段积分仍然通过窗口起点姿态把区间起点转回站立系。
    func test_segmentedFrame_withTiltedWindowStart_recoversTrueDirection() {
        let tilt = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let window = rewritten(concatenated([quiet(0.8, from: 0), stepSignal(leadingQuiet: 0, trailingQuiet: 0), quiet(0.8, from: 0)]), startAttitude: tilt)

        let result = CalibrationMath.segmentedFrame(from: window, standingDown: down, startAttitude: tilt)

        guard case .frame(let f) = result.result else { return XCTFail("\(result.result)") }
        assertDirection(f.front, forward, toleranceDegrees: 3)
        XCTAssertEqual(result.diagnostics.startDriftDegrees ?? 99, 0, accuracy: 0.5)
    }

    func test_segmentedFrame_noActivity_usesWholeWindow_andReportsWeakMotion() {
        let result = CalibrationMath.segmentedFrame(from: quiet(2, from: 0), standingDown: down)
        XCTAssertLessThan(result.diagnostics.peakSpeed ?? 0, CalibrationMath.minPeakSpeed)
        XCTAssertEqual(result.diagnostics.sampleCount, Int(2 / dt))
    }
}
