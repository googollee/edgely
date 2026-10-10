import AttSensorKit
import Foundation
import simd

/// F-002：功能性方向校准。双传感器、单传感器走同一套四步流程，不需要用户手动选择左右脚——
/// 抬左脚、抬右脚两步判定身份，站立步取重力基准，最后一步从并拢开始左右脚各迈一步、算前轴。
/// 整套流程的决定（身份判定、前轴算法、失败处理、落盘）见 ADR-0012。
///
/// **失败处理只有一种**：任何一项判定没通过，整个流程从第一步重来，不做局部重试（见 ADR-0012「失败处理」）。
///
/// 所有窗口都严格由两次确认点击界定，不做实时手势识别，单步超过时限（每一步相同）未点击视为超时失败。
/// 本类只负责"累积设备适配层的采样流并按点击切窗口 + 维护步骤状态机 + 单步超时 + 更新 UI 状态"，实际的判定/计算都委托给
/// `CalibrationMath`（纯计算，可以直接单元测试）。引擎对设备的依赖收窄成 `DeviceAdapter` 协议（ADR-0011：
/// 一条整理好的采样流），测试可以换成不碰蓝牙的假实现。引擎创建时开始订阅各设备的采样流，`close()` 时取消订阅，
/// 这期间的全部样本由 `CalibrationStreamBuffer` 累积（会话结束即丢弃）。
/// 每个窗口的原始数据和判定结果同时交给
/// `recorder` 落盘（见 ADR-0012「校准数据落盘」），`recorder` 默认 nil，不影响引擎本身的可测试性。
final class CalibrationEngine: ObservableObject {
    @Published var instruction: String = ""
    @Published var buttonTitle: String = "确认"
    @Published var isDone = false
    /// 人工核对用的提示（身份判定结果），和 retryNote 分开展示
    @Published var lastNote: String?
    /// 校准失败、流程被整体重置时的提示，重新开始后清空（见 ADR-0012「失败处理」）
    @Published var retryNote: String?

    @Published var resolvedLeft: DeviceAdapter?
    @Published var resolvedRight: DeviceAdapter?
    @Published var leftFrame: SensorOrientationFrame?
    @Published var rightFrame: SensorOrientationFrame?

    private let sensors: [DeviceAdapter]
    private var buffers: [UUID: CalibrationStreamBuffer] = [:]
    private let isDualMode: Bool
    private var downVectors: [UUID: SIMD3<Float>] = [:]
    private let recorder: CalibrationRecording?

    /// 单步时限：从上一次点击算起，超过这个时长仍未收到确认就判定"动作太慢"（见 ADR-0012「窗口与时限」）。
    /// 每一步相同。初始值，需现场验证用户能否稳定在这个时长内完成一步。
    /// 时限到了由计时器自动判失败、整体重来，不等用户下一次点击；点击时也会再检查一次，作为兜底。
    static let defaultStepTimeLimit: TimeInterval = 10
    private let stepTimeLimit: TimeInterval

    /// 当前这一步的时限，供 UI 显示倒计时（每一步相同）
    var currentStepTimeLimit: TimeInterval { stepTimeLimit }

    /// 当前这一步窗口的起点：上一次确认点击的时刻，第一步（抬左脚）则是引擎创建（即"进入校准阶段"）的时刻。
    /// 对 UI 暴露，供显示倒计时使用。
    private(set) var windowStartedAt: Date
    /// 当前这一步的超时计时器：每个窗口起点（引擎创建、每次点击、超时重置）重新开始，校准完成或 `close()` 时取消
    private var timeoutTimer: Timer?
    /// 当前这一步窗口的终点：这一次确认点击的时刻，只在 `confirmCurrentStep` 执行期间有意义
    private var windowEndedAt: Date

    private enum Step: Int {
        case liftLeft, liftRight, standing, stride, done

        /// 落盘记录用的标签（见 ADR-0012「校准数据落盘」），不面向用户展示
        var label: String {
            switch self {
            case .liftLeft: return "liftLeft"
            case .liftRight: return "liftRight"
            case .standing: return "standing"
            case .stride: return "stride"
            case .done: return "done"
            }
        }
    }
    private var step: Step = .liftLeft

    /// 单传感器场景下，步骤 1（抬左脚）这个传感器的峰值速度，等步骤 2（抬右脚）确认后立即用来判定身份（见 ADR-0012 §3）。
    private var singleLeftLiftPeak: Float?

    /// - Parameters:
    ///   - sensors: 1 个或 2 个已连接的传感器（见 PRD F-001）
    ///   - recorder: 校准数据落盘（见 ADR-0012），默认 nil——测试不需要文件系统，生产由调用方注入
    ///   - stepTimeLimit: 单步时限，默认见 `defaultStepTimeLimit`；测试里可以传很小的值来验证超时，不必真等几秒
    init(sensors: [DeviceAdapter], recorder: CalibrationRecording? = nil, stepTimeLimit: TimeInterval = CalibrationEngine.defaultStepTimeLimit) {
        precondition(sensors.count == 1 || sensors.count == 2, "CalibrationEngine 只支持 1 或 2 个传感器")
        self.sensors = sensors
        self.isDualMode = sensors.count == 2
        self.recorder = recorder
        self.stepTimeLimit = stepTimeLimit
        let now = Date()
        self.windowStartedAt = now
        self.windowEndedAt = now
        for sensor in sensors {
            let buffer = CalibrationStreamBuffer()
            buffers[sensor.id] = buffer
            sensor.onSample = { [weak buffer] in buffer?.append($0) }
        }
        instruction = CalibrationEngine.instructionText(for: .liftLeft)
        buttonTitle = "确认"
        startWindow(at: now)
    }

    deinit {
        timeoutTimer?.invalidate()
    }

    /// 这次校准阶段的落盘目录 id，完成后随 session 写进 `meta.json`（见 ADR-0012「校准数据落盘」）
    var calibrationId: String? { recorder?.calibrationId }

    /// 校准阶段结束时调用：取消对设备采样流的订阅、丢弃累积的样本，并收尾落盘（见 ADR-0012）。
    /// 设备本身的流不受影响（设备适配层不保存历史，没人订阅时样本直接丢弃）。
    func close() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        for sensor in sensors {
            sensor.onSample = nil
        }
        buffers.removeAll()
        recorder?.close()
    }

    // MARK: - 确认

    func confirmCurrentStep() {
        let clickedAt = Date()
        windowEndedAt = clickedAt
        defer { startWindow(at: clickedAt) }

        guard step != .done else { return }
        guard clickedAt.timeIntervalSince(windowStartedAt) <= stepTimeLimit else {
            resetToStart(reason: "动作太慢，请重新开始")
            return
        }
        // 窗口里的采样流中断过（传感器断线后重连，帧序号从 0 重新计数）：重建的时间轴在中断处接不上，数据不可用。
        // 窗口数据仍然落盘留档，便于事后看是哪一步断的（ADR-0012 §6）
        if sensors.contains(where: { !CalibrationEngine.isContinuous(samples(for: $0)) }) {
            sensors.forEach { _ = recordedWindow(for: $0) }
            resetToStart(reason: "校准失败，请重新开始")
            return
        }

        switch step {
        case .liftLeft:
            isDualMode ? confirmDualLift(isLeft: true) : confirmSingleLift(isLeft: true)

        case .liftRight:
            isDualMode ? confirmDualLift(isLeft: false) : confirmSingleLift(isLeft: false)

        case .standing:
            var measured: [UUID: SIMD3<Float>] = [:]
            for sensor in sensors {
                guard let down = evaluateStandingDown(sensor) else {
                    resetToStart(reason: "校准失败，请重新开始")
                    return
                }
                measured[sensor.id] = down
            }
            downVectors = measured
            retryNote = nil
            advance(to: .stride)

        case .stride:
            confirmStride()

        case .done:
            return
        }
    }

    // MARK: - 单步超时

    /// 开始一个新窗口：起点定为 `start`，并重新开始计时。已经走完整个流程时不再计时。
    private func startWindow(at start: Date) {
        windowStartedAt = start
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        guard step != .done else { return }
        let remaining = max(0, stepTimeLimit - Date().timeIntervalSince(start))
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.stepTimedOut()
        }
    }

    /// 计时器到点：这一步没有在时限内收到确认，判超时、整体重来，重来的这一刻成为新窗口的起点（ADR-0012 §2、§6）。
    private func stepTimedOut() {
        guard step != .done else { return }
        let now = Date()
        windowEndedAt = now
        resetToStart(reason: "动作太慢，请重新开始")
        startWindow(at: now)
    }

    /// 窗口内的帧序号是否连续递增。没有序号的样本（测试里的合成信号）视为连续。
    private static func isContinuous(_ window: [TimedSample]) -> Bool {
        zip(window, window.dropFirst()).allSatisfy { previous, next in
            guard let i = previous.frameIndex, let j = next.frameIndex else { return true }
            return j == i + 1
        }
    }

    private func samples(for sensor: DeviceAdapter) -> [TimedSample] {
        buffers[sensor.id]?.window(from: windowStartedAt, to: windowEndedAt) ?? []
    }

    /// 取窗口数据并记录原始采样——所有窗口共用，调用方不用重复落盘逻辑。
    private func recordedWindow(for sensor: DeviceAdapter) -> [TimedSample] {
        let window = samples(for: sensor)
        recorder?.recordSamples(step: step.label, sensorId: sensor.id.uuidString, samples: window)
        return window
    }

    /// 抬脚窗口：取窗口数据、记录原始采样、算峰值速度、记录判定——身份判定只关心"动了多快"（见 ADR-0012 §3）。
    /// 算不出（窗口数据不足）时按 0 处理：缺数据等同于"没动"。
    private func evaluateLift(_ sensor: DeviceAdapter) -> Float {
        let window = recordedWindow(for: sensor)
        let peak = CalibrationMath.motionPeakSpeed(of: window)
        recorder?.recordMotion(
            step: step.label, sensorId: sensor.id.uuidString, peakSpeed: peak,
            windowDuration: window.last.map { $0.t } ?? 0, sampleCount: window.count
        )
        return peak ?? 0
    }

    /// 站立窗口：取窗口数据、记录原始采样、跑站立基准算法、记录判定结果。
    private func evaluateStandingDown(_ sensor: DeviceAdapter) -> SIMD3<Float>? {
        let window = recordedWindow(for: sensor)
        let down = CalibrationMath.standingDown(from: window)
        recorder?.recordStandingDown(sensorId: sensor.id.uuidString, down: down)
        // 姿态基准的锚点：站立窗口的末尾（ADR-0012 §5），迈步窗口的起点姿态从这里连续积分
        if down != nil { buffers[sensor.id]?.anchorStanding(at: windowEndedAt) }
        return down
    }

    /// 迈步窗口：取窗口数据、记录原始采样（完整窗口）、取活动段后跑前轴算法、记录判定结果。
    private func evaluateFrame(_ sensor: DeviceAdapter, standingDown: SIMD3<Float>) -> CalibrationMath.FrameOutcome {
        let window = recordedWindow(for: sensor)
        let startAttitude = buffers[sensor.id]?.startAttitude(windowFrom: windowStartedAt, to: windowEndedAt)
        let outcome = CalibrationMath.segmentedFrame(from: window, standingDown: standingDown, startAttitude: startAttitude)
        recorder?.recordFrameOutcome(step: step.label, sensorId: sensor.id.uuidString, outcome: outcome)
        return outcome
    }

    private func advance(to newStep: Step) {
        step = newStep
        instruction = CalibrationEngine.instructionText(for: newStep)
        buttonTitle = "确认"
        isDone = newStep == .done
        if newStep == .done {
            recorder?.recordAttemptCompleted(
                leftSensorId: resolvedLeft?.id.uuidString, leftFrame: leftFrame,
                rightSensorId: resolvedRight?.id.uuidString, rightFrame: rightFrame
            )
        }
    }

    /// 唯一的失败处理：丢弃所有中间状态，流程回到第一步重新开始（见 ADR-0012「失败处理」，不做局部重试）
    private func resetToStart(reason: String) {
        recorder?.recordAttemptFailed(step: step.label, reason: reason)
        downVectors.removeAll()
        singleLeftLiftPeak = nil
        resolvedLeft = nil
        resolvedRight = nil
        leftFrame = nil
        rightFrame = nil
        lastNote = nil
        retryNote = reason
        advance(to: .liftLeft)
    }

    // MARK: - 双传感器：同一时刻比较两个传感器（身份在步骤 1 就已判定，步骤 2 核对）

    private func confirmDualLift(isLeft: Bool) {
        let sensorA = sensors[0]
        let sensorB = sensors[1]
        let peakA = evaluateLift(sensorA)
        let peakB = evaluateLift(sensorB)
        let comparison = CalibrationMath.compare(peakA, peakB)
        guard case .winner(let firstWins) = comparison else {
            resetToStart(reason: CalibrationEngine.comparisonFailureMessage(comparison))
            return
        }
        let winner = firstWins ? sensorA : sensorB
        let loser = firstWins ? sensorB : sensorA

        if isLeft {
            resolvedLeft = winner
            resolvedRight = loser
            lastNote = "已判定：动作更明显的传感器为左脚"
            advance(to: .liftRight)
        } else {
            // 步骤 2 抬右脚：动得更明显的必须是步骤 1 里判定的右脚传感器，否则抬错了脚或判错了
            guard winner === resolvedRight else {
                resetToStart(reason: "校准失败，请重新开始")
                return
            }
            lastNote = nil
            advance(to: .standing)
        }
    }

    // MARK: - 单传感器：两个抬脚窗口直接比较峰值速度

    private func confirmSingleLift(isLeft: Bool) {
        guard let sensor = sensors.first else { return }
        let peak = evaluateLift(sensor)
        if isLeft {
            singleLeftLiftPeak = peak
            lastNote = nil
            advance(to: .liftRight)
        } else {
            resolveSingleIdentity(sensor: sensor, rightPeak: peak)
        }
    }

    /// 直接比较步骤 1（抬左脚）、步骤 2（抬右脚）两个窗口的峰值速度判定身份（见 ADR-0012 §3）。
    private func resolveSingleIdentity(sensor: DeviceAdapter, rightPeak: Float) {
        guard let leftPeak = singleLeftLiftPeak else { return }
        let comparison = CalibrationMath.compare(leftPeak, rightPeak)
        guard case .winner(let leftWins) = comparison else {
            resetToStart(reason: CalibrationEngine.comparisonFailureMessage(comparison))
            return
        }
        if leftWins {
            resolvedLeft = sensor
        } else {
            resolvedRight = sensor
        }
        lastNote = leftWins ? "已判定：这个传感器是左脚" : "已判定：这个传感器是右脚"
        advance(to: .standing)
    }

    private static func comparisonFailureMessage(_ outcome: CalibrationMath.ComparisonOutcome) -> String {
        switch outcome {
        case .tooWeak: return "动作幅度太小，请重新开始"
        case .tooClose: return "校准失败，请重新开始"
        case .winner: return ""
        }
    }

    // MARK: - 迈步：每个已识别身份的传感器用自己的窗口算前轴

    private func confirmStride() {
        // 双传感器两个都要算；单传感器只有被识别出的那只脚有传感器
        var targets: [(sensor: DeviceAdapter, isLeft: Bool)] = []
        if let left = resolvedLeft { targets.append((left, true)) }
        if let right = resolvedRight { targets.append((right, false)) }
        guard !targets.isEmpty else {
            resetToStart(reason: "校准失败，请重新开始")
            return
        }

        var frames: [Bool: SensorOrientationFrame] = [:]
        for (sensor, isLeft) in targets {
            guard let standing = downVectors[sensor.id] else {
                resetToStart(reason: "校准失败，请重新开始")
                return
            }
            let outcome = evaluateFrame(sensor, standingDown: standing)
            // 算法没算到峰值速度（数据不足、漂移超限）属于「其余」类失败，不是幅度问题，用兜底提示（见 ADR-0012 §6）
            guard let peakSpeed = outcome.diagnostics.peakSpeed else {
                resetToStart(reason: "校准失败，请重新开始")
                return
            }
            // 身份已定，该动的脚没动就是失败（见 ADR-0012「失败处理」）
            guard peakSpeed >= CalibrationMath.minPeakSpeed else {
                resetToStart(reason: "动作幅度太小，请重新开始")
                return
            }
            guard case .frame(let frame) = outcome.result else {
                resetToStart(reason: "校准失败，请重新开始")
                return
            }
            frames[isLeft] = frame
        }
        leftFrame = frames[true]
        rightFrame = frames[false]
        lastNote = nil
        advance(to: .done)
    }

    // MARK: - 文案

    /// 每一步都要求动作前后各停顿一次：算法把"动作起止速度为零"当作消除积分误差的边界条件，
    /// 两端没停稳这个前提就不成立；算法本身不做静止性验证，这条提示是唯一的保障（见 ADR-0012）。
    private static func instructionText(for step: Step) -> String {
        switch step {
        case .liftLeft: return "请站稳，抬起左脚（离地即可）再放下，停稳后点击「确认」"
        case .liftRight: return "请站稳，抬起右脚（离地即可）再放下，停稳后点击「确认」"
        case .standing: return "请双脚并拢自然站立、雪靴放平，站稳一两秒后点击「确认」"
        case .stride: return "双脚并拢站稳后，左脚向前迈一步，右脚跟上并拢，停稳后点击「确认」，沿脚尖方向直着迈"
        case .done: return "校准完成"
        }
    }
}
