import XCTest
import simd
import AttSensorKit
@testable import Edgely

/// 供测试使用的假设备：不碰蓝牙，`CalibrationEngine` 只认 `DeviceAdapter` 协议（ADR-0011）。
/// 测试在每次点击确认之前，用 `push` 把"这一步窗口里的数据"推进采样流；样本的到达时间是推送那一刻，
/// 引擎按两次点击的时刻切窗口，所以每个窗口只会看到自己推的数据。
/// 流内的重建时间 `t` 连续累加（窗口之间留一个采样间隔），和真实适配层"整条流一个时间轴"的形态一致。
private final class FakeDeviceAdapter: MockAdapter {
    private var index = 0
    private var base: TimeInterval = 0

    override func resetStream() {
        super.resetStream()
        index = 0
        base = 0
    }

    func push(_ window: [TimedSample]) {
        // 保证推送时刻严格晚于上一次点击：引擎用 Date 比较，避免同一时刻的偶然相等
        Thread.sleep(forTimeInterval: 0.002)
        let arrival = Date()
        for sample in window {
            onSample?(DeviceSample(index: index, t: base + sample.t, accel: sample.accel, gyro: sample.gyro, arrival: arrival))
            index += 1
        }
        base += (window.last?.t ?? 0) + 0.02
    }
}

/// 记下引擎对落盘接口的全部调用，用来验证步骤标签和记录内容（ADR-0012「校准数据落盘」）。
private final class FakeRecorder: CalibrationRecording {
    let calibrationId = "test"
    var sampleSteps: [String] = []
    var motionRecords: [(step: String, peakSpeed: Float?)] = []
    var frameSteps: [String] = []
    var standingRecorded = 0
    var failures: [(step: String, reason: String)] = []
    var completed = 0

    func recordSamples(step: String, sensorId: String, samples: [TimedSample]) { sampleSteps.append(step) }
    func recordStandingDown(sensorId: String, down: SIMD3<Float>?) { standingRecorded += 1 }
    func recordFrameOutcome(step: String, sensorId: String, outcome: CalibrationMath.FrameOutcome) { frameSteps.append(step) }
    func recordMotion(step: String, sensorId: String, peakSpeed: Float?, windowDuration: Double, sampleCount: Int) {
        motionRecords.append((step, peakSpeed))
    }
    func recordAttemptFailed(step: String, reason: String) { failures.append((step, reason)) }
    func recordAttemptCompleted(leftSensorId: String?, leftFrame: SensorOrientationFrame?, rightSensorId: String?, rightFrame: SensorOrientationFrame?) { completed += 1 }
    func close() {}
}

/// `CalibrationEngine` 编排 `CalibrationMath`，这里只验证编排逻辑本身（身份怎么判、失败怎么处理），
/// 不重复验证算法细节（那是 `CalibrationMathTests` 的事）——信号构造沿用同一套物理约定，
/// 只要能可靠地产出"明显动了"或"没动"两种窗口就够用。
final class CalibrationEngineTests: XCTestCase {
    private let dt: TimeInterval = 0.02
    private let down = SIMD3<Float>(0, 0, -1)
    private let forward = SIMD3<Float>(1, 0, 0)

    private func quietSignal(duration: TimeInterval = 0.6) -> [TimedSample] {
        (0..<Int(duration / dt)).map { TimedSample(t: Double($0) * dt, accel: down, gyro: .zero) }
    }

    /// 与 CalibrationMathTests.stepSignal 同一套构造方式（静止 → 匀加速 → 匀减速 → 静止，动作期间绕
    /// "下"轴转动），这里只需要它能稳定产出一个 `.frame` 成功结果，不需要覆盖所有信号变体。
    private func stepSignal(direction: SIMD3<Float>) -> [TimedSample] {
        let amplitude: Float = 0.2
        let accelerateSeconds: TimeInterval = 0.3
        // 这里不让传感器转动：引擎的姿态是从站立起连续积分的（ADR-0012 §5），各窗口的合成信号又是独立构造的，
        // 一旦带转动，窗口之间的体姿态就不连续了。转动补偿的算法细节由 CalibrationMathTests 覆盖。
        let rotationRate: Float = 0
        let spin = down * rotationRate
        var samples: [TimedSample] = []
        func append(_ accel: SIMD3<Float>, _ gyro: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: gyro))
        }
        for _ in 0..<Int(0.4 / dt) { append(down, .zero) }
        let motionCount = Int(accelerateSeconds / dt) * 2
        for i in 0..<motionCount {
            let sign: Float = i < motionCount / 2 ? 1 : -1
            let turned = rotationRate * (.pi / 180) * Float(i) * Float(dt)
            let linearInBody = simd_quatf(angle: -turned, axis: down).act(direction) * amplitude * sign
            // 真实迈步脚会抬起：竖直方向加一段同样"先加速后减速"的加速度（垂直于前进方向，不影响前轴，
            // 但让 |accel| 偏离 1g，活动段检测才看得见这一步）
            let lift = (-down) * 0.3 * sign
            append(down + linearInBody + lift, spin)
        }
        for _ in 0..<Int(0.4 / dt) { append(down, .zero) }
        return samples
    }

    /// 一次理想的抬脚再放下：静止 → 竖直方向匀加速 → 匀减速 → 静止，没有旋转（预期抬脚没有明显旋转，见 ADR-0012）。
    private func liftSignal(amplitude: Float = 0.3) -> [TimedSample] {
        var samples: [TimedSample] = []
        func append(_ accel: SIMD3<Float>) {
            samples.append(TimedSample(t: Double(samples.count) * dt, accel: accel, gyro: .zero))
        }
        for _ in 0..<Int(0.4 / dt) { append(down) }
        let motionCount = Int(0.3 / dt) * 2
        for i in 0..<motionCount {
            let sign: Float = i < motionCount / 2 ? 1 : -1
            append(down + (-down) * amplitude * sign)
        }
        for _ in 0..<Int(0.4 / dt) { append(down) }
        return samples
    }

    /// 一次点击：先把这一步各设备的窗口数据推进采样流（没列出的设备这一步没有数据），再确认。
    private func confirm(_ engine: CalibrationEngine, feeding feeds: [(FakeDeviceAdapter, [TimedSample])] = []) {
        for (sensor, window) in feeds { sensor.push(window) }
        engine.confirmCurrentStep()
    }

    // MARK: - 双传感器

    func test_dualSensor_happyPath_resolvesIdentityAndCompletes() {
        let left = FakeDeviceAdapter()
        let right = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [left, right])

        confirm(engine, feeding: [(left, liftSignal()), (right, quietSignal())])                 // 1 抬左脚
        XCTAssertTrue(engine.resolvedLeft === left, "抬脚动得更明显的一侧应判定为左脚")
        XCTAssertTrue(engine.resolvedRight === right)
        confirm(engine, feeding: [(left, quietSignal()), (right, liftSignal())])                 // 2 抬右脚：核对一致
        confirm(engine, feeding: [(left, quietSignal()), (right, quietSignal())])                // 3 站立
        confirm(engine, feeding: [(left, stepSignal(direction: forward)), (right, stepSignal(direction: forward))]) // 4 迈步

        XCTAssertTrue(engine.isDone)
        XCTAssertNil(engine.retryNote, "全程不应该触发整体重置")
        guard let leftFrame = engine.leftFrame, let rightFrame = engine.rightFrame else { return XCTFail("两只脚都应有参考系") }
        for frame in [leftFrame, rightFrame] {
            let cosine = simd_dot(simd_normalize(frame.front), forward)
            XCTAssertGreaterThan(cosine, 0.99, "算出的前方向应当就是迈步方向")
        }
    }

    func test_dualSensor_ambiguousLift_resetsToStart() {
        // 两侧抬脚幅度接近，达不到 3 倍相对区分度，应判定失败整体重置
        let left = FakeDeviceAdapter()
        let right = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [left, right])

        confirm(engine, feeding: [(left, liftSignal()), (right, liftSignal())])

        XCTAssertEqual(engine.retryNote, "校准失败，请重新开始")
        XCTAssertNil(engine.resolvedLeft)
        XCTAssertNil(engine.resolvedRight)
    }

    func test_dualSensor_bothLiftsTooWeak_resetsWithSpecificMessage() {
        let left = FakeDeviceAdapter()
        let right = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [left, right])

        confirm(engine, feeding: [(left, quietSignal()), (right, quietSignal())])

        XCTAssertEqual(engine.retryNote, "动作幅度太小，请重新开始")
    }

    func test_dualSensor_secondLiftContradictsFirst_resetsToStart() {
        // 第 1 步判定 left 传感器是左脚；第 2 步抬"右脚"时动的却还是 left 传感器，说明抬错了脚或判错了
        let left = FakeDeviceAdapter()
        let right = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [left, right])

        confirm(engine, feeding: [(left, liftSignal()), (right, quietSignal())])
        XCTAssertTrue(engine.resolvedLeft === left)
        confirm(engine, feeding: [(left, liftSignal()), (right, quietSignal())])

        XCTAssertEqual(engine.retryNote, "校准失败，请重新开始")
        XCTAssertNil(engine.resolvedLeft, "判定失败要整体重置，不保留步骤 1 已经判定的身份")
    }

    func test_dualSensor_strideTooWeakOnOneSensor_resetsWithSpecificMessage() {
        let left = FakeDeviceAdapter()
        let right = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [left, right])

        confirm(engine, feeding: [(left, liftSignal()), (right, quietSignal())])
        confirm(engine, feeding: [(left, quietSignal()), (right, liftSignal())])
        confirm(engine, feeding: [(left, quietSignal()), (right, quietSignal())])
        // 迈步：右脚传感器该动却没动
        confirm(engine, feeding: [(left, stepSignal(direction: forward)), (right, quietSignal())])

        XCTAssertEqual(engine.retryNote, "动作幅度太小，请重新开始")
        XCTAssertFalse(engine.isDone)
    }

    /// 迈步窗口没算出峰值速度（数据不足、漂移超限）不是"动作幅度太小"，提示要走兜底（ADR-0012 §6）
    private func driveToStride(_ engine: CalibrationEngine, _ sensor: FakeDeviceAdapter) {
        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
    }

    func test_stride_withoutData_resetsWithGenericMessage() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        driveToStride(engine, sensor)

        confirm(engine) // 迈步窗口里没有任何样本

        XCTAssertEqual(engine.retryNote, "校准失败，请重新开始")
        XCTAssertFalse(engine.isDone)
    }

    func test_stride_excessiveDrift_resetsWithGenericMessage() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        driveToStride(engine, sensor)

        // 加速度计始终显示静止，陀螺却持续大幅转动：积分出的姿态与重力观测对不上，漂移超限
        let spinning = (0..<50).map { TimedSample(t: Double($0) * dt, accel: down, gyro: SIMD3<Float>(0, 200, 0)) }
        confirm(engine, feeding: [(sensor, spinning)])

        XCTAssertEqual(engine.retryNote, "校准失败，请重新开始")
        XCTAssertFalse(engine.isDone)
    }

    // MARK: - 单传感器

    func test_singleSensor_onLeftFoot_resolvesLeftAndOnlyComputesLeftFrame() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        confirm(engine, feeding: [(sensor, liftSignal())])                       // 1 抬左脚：动得明显
        XCTAssertNil(engine.resolvedLeft, "单传感器要比较两个窗口，第 1 步结束时还不能判定")
        confirm(engine, feeding: [(sensor, quietSignal())])                      // 2 抬右脚：这只脚不在这，预期不动
        XCTAssertTrue(engine.resolvedLeft === sensor)
        XCTAssertNil(engine.resolvedRight)
        confirm(engine, feeding: [(sensor, quietSignal())])                      // 3 站立
        confirm(engine, feeding: [(sensor, stepSignal(direction: forward))])     // 4 迈步

        XCTAssertTrue(engine.isDone)
        XCTAssertNil(engine.retryNote)
        XCTAssertNotNil(engine.leftFrame)
        XCTAssertNil(engine.rightFrame)
    }

    func test_singleSensor_onRightFoot_resolvesRight() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, liftSignal())])
        XCTAssertTrue(engine.resolvedRight === sensor)
        XCTAssertNil(engine.resolvedLeft)
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, stepSignal(direction: forward))])

        XCTAssertTrue(engine.isDone)
        XCTAssertNil(engine.leftFrame)
        XCTAssertNotNil(engine.rightFrame)
    }

    func test_singleSensor_bothLiftsTooWeak_resetsToStart() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())]) // 两个窗口都没过绝对下限

        XCTAssertEqual(engine.retryNote, "动作幅度太小，请重新开始")
        XCTAssertNil(engine.resolvedLeft)
        XCTAssertNil(engine.resolvedRight)
    }

    func test_singleSensor_strideTooWeak_resetsWithSpecificMessage() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())]) // 迈步：该动却没动

        XCTAssertEqual(engine.retryNote, "动作幅度太小，请重新开始")
        XCTAssertFalse(engine.isDone)
    }

    // MARK: - 失败后整体重来、时限

    func test_failureReturnsToFirstStep_andClearsState() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        let firstInstruction = engine.instruction

        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])   // 身份已判定
        XCTAssertNotEqual(engine.instruction, firstInstruction)
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])   // 迈步失败

        XCTAssertEqual(engine.instruction, firstInstruction, "失败后回到第一步")
        XCTAssertNil(engine.resolvedLeft)
        XCTAssertNil(engine.leftFrame)
        XCTAssertFalse(engine.isDone)
    }

    func test_timeout_failsWithSpecificMessage() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor], stepTimeLimit: 0.01)

        Thread.sleep(forTimeInterval: 0.05)
        confirm(engine, feeding: [(sensor, liftSignal())])

        XCTAssertEqual(engine.retryNote, "动作太慢，请重新开始")
    }

    /// 窗口里采样流中断过（传感器断线重连，帧序号重新计数）：这一步的数据不可用，整体重来，窗口仍然落盘留档
    func test_streamInterruptedInsideWindow_resetsAndStillRecordsTheWindow() {
        let sensor = FakeDeviceAdapter()
        let recorder = FakeRecorder()
        let engine = CalibrationEngine(sensors: [sensor], recorder: recorder)

        sensor.push(liftSignal())
        sensor.resetStream() // 窗口中途重连
        sensor.push(liftSignal())
        engine.confirmCurrentStep()

        XCTAssertEqual(engine.retryNote, "校准失败，请重新开始")
        XCTAssertNil(engine.resolvedLeft)
        XCTAssertEqual(recorder.failures.map(\.step), ["liftLeft"])
        XCTAssertEqual(recorder.sampleSteps, ["liftLeft"], "失败的窗口也落盘")
    }

    func test_streamInterruptedInEarlierWindow_doesNotAffectLaterSteps() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        sensor.resetStream() // 第一步开始前就重新计数，窗口内是连续的
        confirm(engine, feeding: [(sensor, liftSignal())])

        XCTAssertNil(engine.retryNote)
    }

    /// 让主线程的 RunLoop 跑一小段时间，计时器才有机会触发（`Thread.sleep` 不会）
    private func runLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func test_timeout_firesWithoutAClick_andReturnsToFirstStep() {
        let sensor = FakeDeviceAdapter()
        let recorder = FakeRecorder()
        let engine = CalibrationEngine(sensors: [sensor], recorder: recorder, stepTimeLimit: 0.05)
        let firstInstruction = engine.instruction
        confirm(engine, feeding: [(sensor, liftSignal())])
        XCTAssertNotEqual(engine.instruction, firstInstruction, "已进入第 2 步")
        XCTAssertNil(engine.retryNote)

        runLoop(for: 0.2) // 不点击，等超时

        XCTAssertEqual(engine.retryNote, "动作太慢，请重新开始")
        XCTAssertEqual(engine.instruction, firstInstruction, "超时后整体重来，回到第一步")
        // 用户一直不点击的话会持续超时，这里只看第一次：失败发生在用户停下的那一步
        XCTAssertEqual(recorder.failures.first?.step, "liftRight")
        XCTAssertTrue(recorder.failures.allSatisfy { $0.reason == "动作太慢，请重新开始" })
    }

    func test_timeout_restartsTheClock_andKeepsFailingWhileUserDoesNothing() {
        let sensor = FakeDeviceAdapter()
        let recorder = FakeRecorder()
        let engine = CalibrationEngine(sensors: [sensor], recorder: recorder, stepTimeLimit: 0.05)
        let startBefore = engine.windowStartedAt

        runLoop(for: 0.2)

        XCTAssertGreaterThan(engine.windowStartedAt, startBefore, "超时重置后，新窗口的起点是重置那一刻")
        XCTAssertGreaterThanOrEqual(recorder.failures.count, 2, "新一轮的时限也会继续计时")
        XCTAssertTrue(recorder.failures.allSatisfy { $0.step == "liftLeft" })
    }

    func test_clickWithinLimit_postponesTheTimeout() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor], stepTimeLimit: 0.15)

        runLoop(for: 0.1)
        confirm(engine, feeding: [(sensor, liftSignal())]) // 点击后重新计时
        runLoop(for: 0.1)                                   // 距第一次计时开始已 0.2 秒，但距点击只有 0.1 秒

        XCTAssertNil(engine.retryNote)
    }

    func test_noTimeoutAfterCompletion_orAfterClose() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor], stepTimeLimit: 0.3)
        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, stepSignal(direction: forward))])
        XCTAssertTrue(engine.isDone)

        runLoop(for: 0.5)
        XCTAssertTrue(engine.isDone, "完成后不再计时")
        XCTAssertNil(engine.retryNote)

        let other = FakeDeviceAdapter()
        let closed = CalibrationEngine(sensors: [other], stepTimeLimit: 0.05)
        closed.close()
        runLoop(for: 0.2)
        XCTAssertNil(closed.retryNote, "close() 之后计时器被取消")
    }

    /// 每一步的时限都是 10 秒，UI 倒计时读的就是这个值（ADR-0012「窗口与时限」）。
    func test_stepTimeLimit_isTenSecondsForEveryStep() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])

        XCTAssertEqual(CalibrationEngine.defaultStepTimeLimit, 10)
        XCTAssertEqual(engine.currentStepTimeLimit, 10)                                   // 1 抬左脚
        confirm(engine, feeding: [(sensor, liftSignal())])
        XCTAssertEqual(engine.currentStepTimeLimit, 10)                                   // 2 抬右脚
        confirm(engine, feeding: [(sensor, quietSignal())])
        XCTAssertEqual(engine.currentStepTimeLimit, 10)                                   // 3 站立
        confirm(engine, feeding: [(sensor, quietSignal())])
        XCTAssertEqual(engine.currentStepTimeLimit, 10)                                   // 4 迈步
    }

    /// 传感器所在脚后迈：迈步窗口前面是一段静止，其间有另一只脚落地的冲击尖峰。分段积分后仍然能算出正确的前方向。
    func test_stride_withIdlePrefixAndImpactSpike_stillSucceeds() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        let spike = [TimedSample(t: 0, accel: down + SIMD3<Float>(0, 3, 0), gyro: .zero)]
        let strideWindow = quietSignal(duration: 0.8) + spike + quietSignal(duration: 0.7) + stepSignal(direction: forward)
        let reindexed = strideWindow.enumerated().map { TimedSample(t: Double($0.offset) * dt, accel: $0.element.accel, gyro: $0.element.gyro) }

        confirm(engine, feeding: [(sensor, quietSignal())])        // 抬左脚：这只脚是右脚，不动
        confirm(engine, feeding: [(sensor, liftSignal())])         // 抬右脚
        confirm(engine, feeding: [(sensor, quietSignal())])        // 站立
        confirm(engine, feeding: [(sensor, reindexed)])            // 迈步

        XCTAssertTrue(engine.isDone, "不应被前面的冲击尖峰拖垮：\(engine.retryNote ?? "")")
        guard let frame = engine.rightFrame else { return XCTFail("右脚应有参考系") }
        XCTAssertGreaterThan(simd_dot(simd_normalize(frame.front), forward), 0.99)
    }

    func test_buttonTitleIsAlwaysConfirm() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        XCTAssertEqual(engine.buttonTitle, "确认")
        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        XCTAssertEqual(engine.buttonTitle, "确认", "新流程没有\"校验\"步骤")
    }

    // MARK: - 落盘记录

    func test_recorder_receivesStepLabelsAndMotionJudgments() {
        let sensor = FakeDeviceAdapter()
        let recorder = FakeRecorder()
        let engine = CalibrationEngine(sensors: [sensor], recorder: recorder)

        confirm(engine, feeding: [(sensor, liftSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, stepSignal(direction: forward))])

        XCTAssertEqual(recorder.sampleSteps, ["liftLeft", "liftRight", "standing", "stride"])
        XCTAssertEqual(recorder.motionRecords.map { $0.step }, ["liftLeft", "liftRight"])
        XCTAssertGreaterThan(recorder.motionRecords[0].peakSpeed ?? 0, CalibrationMath.minPeakSpeed)
        XCTAssertLessThan(recorder.motionRecords[1].peakSpeed ?? 1, CalibrationMath.minPeakSpeed)
        XCTAssertEqual(recorder.standingRecorded, 1)
        XCTAssertEqual(recorder.frameSteps, ["stride"])
        XCTAssertEqual(recorder.completed, 1)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func test_recorder_receivesFailureStepAndReason() {
        let sensor = FakeDeviceAdapter()
        let recorder = FakeRecorder()
        let engine = CalibrationEngine(sensors: [sensor], recorder: recorder)

        confirm(engine, feeding: [(sensor, quietSignal())])
        confirm(engine, feeding: [(sensor, quietSignal())]) // 两次抬脚都太弱

        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertEqual(recorder.failures[0].step, "liftRight")
        XCTAssertEqual(recorder.failures[0].reason, "动作幅度太小，请重新开始")
        XCTAssertEqual(recorder.completed, 0)
    }

    // MARK: - 订阅生命周期

    func test_close_unsubscribesFromDeviceStreams() {
        let sensor = FakeDeviceAdapter()
        let engine = CalibrationEngine(sensors: [sensor])
        XCTAssertNotNil(sensor.onSample, "引擎创建时就订阅设备的采样流")

        engine.close()

        XCTAssertNil(sensor.onSample)
    }
}
