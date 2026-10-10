import Foundation
import simd

/// 校准过程落盘的三类记录（见 ADR-0012）。都写进同一个 `attempt` 编号，用来在同一次校准阶段里
/// 区分"重来了几次"——同一个字段贯穿三个文件，不需要按尝试拆子目录。

/// 交给判定算法的原始窗口采样，一行一个采样点，沿用 ADR-0001 的 JSON Lines 约定。
/// `type` 恒为 "sample"（旧数据里还有 "chipTime" 记录，读取时按它过滤，见 docs/reference/session-data-format.md）。
/// `t` 是按采样序号重建的时间，`arrivalT` 是原始 BLE 到达时间（相对窗口第一个样本），
/// 旧数据的 `t` 就是到达时间、没有 `arrivalT`。
struct CalibrationSampleRecord: Codable {
    let type: String
    let attempt: Int
    let step: String
    let sensorId: String
    let t: Double
    let arrivalT: Double?
    /// 本次校准内的实时帧序号（从 0 起算）和到达时的手机绝对时间（Unix 秒），较新的数据才有
    let frameIndex: Int?
    let wallClock: Double?
    let accelX: Float
    let accelY: Float
    let accelZ: Float
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float

    init(attempt: Int, step: String, sensorId: String, sample: TimedSample) {
        self.type = "sample"
        self.attempt = attempt
        self.step = step
        self.sensorId = sensorId
        self.t = sample.t
        self.arrivalT = sample.arrivalT
        self.frameIndex = sample.frameIndex
        self.wallClock = sample.wallClock
        self.accelX = sample.accel.x
        self.accelY = sample.accel.y
        self.accelZ = sample.accel.z
        self.gyroX = sample.gyro.x
        self.gyroY = sample.gyro.y
        self.gyroZ = sample.gyro.z
    }
}

/// 单个窗口的判定结果与全部中间量（见 ADR-0012「前轴计算」、「校准数据落盘」）。
/// `result` 取值："standingDown" | "motion"（抬脚窗口，只有峰值速度）| "frame" | "insufficientData" | "driftTooLarge" | "directionUnclear"。
struct CalibrationJudgmentRecord: Codable {
    let attempt: Int
    let step: String
    let sensorId: String
    let result: String
    let downStart: [Float]?
    let downEnd: [Float]?
    let driftDegrees: Float?
    /// 从站立起的累计漂移 / 窗口起点相对站立的倾角，以及起点姿态的来源（"continuous" | "aligned"），见 ADR-0012
    let startDriftDegrees: Float?
    let startAttitudeSource: String?
    let peakSpeed: Float?
    let coherence: Float?
    /// 迈步窗口是积分区间的时长与采样数（分段积分，见 ADR-0012 §5 步骤 0），其余窗口是整个窗口的
    let windowDuration: Double
    let sampleCount: Int
    /// 迈步窗口：积分区间在窗口内的起止时间（相对窗口第一个样本的秒数）；其余窗口为 nil
    let segmentStartT: Double?
    let segmentEndT: Double?
    /// 只在 result == "frame" 时有值：算出的参考系
    let front: [Float]?
    let down: [Float]?
    let left: [Float]?

    init(attempt: Int, step: String, sensorId: String, outcome: CalibrationMath.FrameOutcome) {
        self.attempt = attempt
        self.step = step
        self.sensorId = sensorId
        self.downStart = outcome.diagnostics.downStart.map { [$0.x, $0.y, $0.z] }
        self.downEnd = outcome.diagnostics.downEnd.map { [$0.x, $0.y, $0.z] }
        self.driftDegrees = outcome.diagnostics.driftDegrees
        self.startDriftDegrees = outcome.diagnostics.startDriftDegrees
        self.startAttitudeSource = outcome.diagnostics.startAttitudeSource?.rawValue
        self.peakSpeed = outcome.diagnostics.peakSpeed
        self.coherence = outcome.diagnostics.coherence
        self.windowDuration = outcome.diagnostics.windowDuration
        self.sampleCount = outcome.diagnostics.sampleCount
        self.segmentStartT = outcome.diagnostics.segmentStartT
        self.segmentEndT = outcome.diagnostics.segmentEndT
        switch outcome.result {
        case .frame(let frame):
            self.result = "frame"
            self.front = [frame.front.x, frame.front.y, frame.front.z]
            self.down = [frame.down.x, frame.down.y, frame.down.z]
            self.left = [frame.left.x, frame.left.y, frame.left.z]
        case .insufficientData:
            self.result = "insufficientData"; self.front = nil; self.down = nil; self.left = nil
        case .driftTooLarge:
            self.result = "driftTooLarge"; self.front = nil; self.down = nil; self.left = nil
        case .directionUnclear:
            self.result = "directionUnclear"; self.front = nil; self.down = nil; self.left = nil
        }
    }

    /// 抬脚窗口走的是 `CalibrationMath.motionPeakSpeed`，只产出一个峰值速度，单独构造一条精简记录（`result: "motion"`）。
    /// 窗口数据不足、算不出峰值速度时记为 "insufficientData"。
    init(attempt: Int, step: String, sensorId: String, motionPeakSpeed: Float?, windowDuration: Double, sampleCount: Int) {
        self.attempt = attempt
        self.step = step
        self.sensorId = sensorId
        self.result = motionPeakSpeed == nil ? "insufficientData" : "motion"
        self.downStart = nil
        self.downEnd = nil
        self.driftDegrees = nil
        self.startDriftDegrees = nil
        self.startAttitudeSource = nil
        self.peakSpeed = motionPeakSpeed
        self.coherence = nil
        self.windowDuration = windowDuration
        self.sampleCount = sampleCount
        self.segmentStartT = nil
        self.segmentEndT = nil
        self.front = nil
        self.down = nil
        self.left = nil
    }

    /// 站立步骤走的是 `CalibrationMath.standingDown`，不产出 `FrameOutcome`，单独构造一条精简记录。
    init(attempt: Int, sensorId: String, standingDown: SIMD3<Float>?) {
        self.attempt = attempt
        self.step = "standing"
        self.sensorId = sensorId
        self.result = standingDown == nil ? "insufficientData" : "standingDown"
        self.downStart = standingDown.map { [$0.x, $0.y, $0.z] }
        self.downEnd = nil
        self.driftDegrees = nil
        self.startDriftDegrees = nil
        self.startAttitudeSource = nil
        self.peakSpeed = nil
        self.coherence = nil
        self.windowDuration = 0
        self.sampleCount = 0
        self.segmentStartT = nil
        self.segmentEndT = nil
        self.front = nil
        self.down = nil
        self.left = nil
    }
}

/// 一次尝试（从站立开始，到完成或被整体重置为止）的结局。
struct CalibrationAttemptRecord: Codable {
    let attempt: Int
    let outcome: String // "completed" | "failed"
    let failedAtStep: String?
    let failureReason: String?
    let leftSensorId: String?
    let rightSensorId: String?
    let leftFrame: CalibrationFrameDTO?
    let rightFrame: CalibrationFrameDTO?
}
