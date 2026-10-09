import Foundation
import simd

/// `CalibrationEngine` 依赖的记录接口，只做这几件事，不掺入判定/流程逻辑（见 ADR-0012）。
/// 测试里不提供实现（引擎的 `recorder` 默认 nil），保持引擎本身可以脱离文件系统直接单测。
protocol CalibrationRecording: AnyObject {
    /// 这次校准阶段的落盘目录 id（时间戳），完成后写进 session 的 `meta.json`，供事后关联。
    var calibrationId: String { get }

    func recordSamples(step: String, sensorId: String, samples: [TimedSample])
    func recordStandingDown(sensorId: String, down: SIMD3<Float>?)
    func recordFrameOutcome(step: String, sensorId: String, outcome: CalibrationMath.FrameOutcome)
    /// 抬脚窗口的判定记录：只有一个峰值速度（算不出时为 nil）。
    func recordMotion(step: String, sensorId: String, peakSpeed: Float?, windowDuration: Double, sampleCount: Int)
    /// 一次尝试失败（整体重置）：记录失败位置和原因，随后内部转入下一次尝试的编号。
    func recordAttemptFailed(step: String, reason: String)
    /// 一次尝试完成（走到最后一步）：记录最终判定结果。
    func recordAttemptCompleted(
        leftSensorId: String?, leftFrame: SensorOrientationFrame?,
        rightSensorId: String?, rightFrame: SensorOrientationFrame?
    )
    /// 校准阶段结束（无论完成与否），收尾落盘。
    func close()
}

/// `CalibrationRecording` 的文件实现：写到 `Documents/Calibrations/<时间戳>/`，与 `Sessions/` 平级
/// （见 ADR-0012）。三个 JSON Lines 文件贯穿同一次校准阶段的所有尝试，每条记录带 `attempt` 编号区分
/// 是第几次尝试——失败的尝试不覆盖、不合并，只是追加下一个编号继续写。
final class CalibrationRecorder: CalibrationRecording {
    let calibrationId: String
    private let directory: URL

    private var samplesHandle: FileHandle?
    private var judgmentsHandle: FileHandle?
    private var attemptsHandle: FileHandle?

    private var attempt = 1

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        self.calibrationId = formatter.string(from: Date())

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = docs.appendingPathComponent("Calibrations").appendingPathComponent(calibrationId)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        samplesHandle = CalibrationRecorder.openForAppend(directory.appendingPathComponent("samples.jsonl"))
        judgmentsHandle = CalibrationRecorder.openForAppend(directory.appendingPathComponent("judgments.jsonl"))
        attemptsHandle = CalibrationRecorder.openForAppend(directory.appendingPathComponent("attempts.jsonl"))
    }

    private static func openForAppend(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    // MARK: - CalibrationRecording

    func recordSamples(step: String, sensorId: String, samples: [TimedSample]) {
        for sample in samples {
            append(CalibrationSampleRecord(attempt: attempt, step: step, sensorId: sensorId, sample: sample), to: samplesHandle)
        }
    }

    func recordStandingDown(sensorId: String, down: SIMD3<Float>?) {
        append(CalibrationJudgmentRecord(attempt: attempt, sensorId: sensorId, standingDown: down), to: judgmentsHandle)
    }

    func recordFrameOutcome(step: String, sensorId: String, outcome: CalibrationMath.FrameOutcome) {
        append(CalibrationJudgmentRecord(attempt: attempt, step: step, sensorId: sensorId, outcome: outcome), to: judgmentsHandle)
    }

    func recordMotion(step: String, sensorId: String, peakSpeed: Float?, windowDuration: Double, sampleCount: Int) {
        append(CalibrationJudgmentRecord(
            attempt: attempt, step: step, sensorId: sensorId,
            motionPeakSpeed: peakSpeed, windowDuration: windowDuration, sampleCount: sampleCount
        ), to: judgmentsHandle)
    }

    func recordAttemptFailed(step: String, reason: String) {
        append(CalibrationAttemptRecord(
            attempt: attempt, outcome: "failed", failedAtStep: step, failureReason: reason,
            leftSensorId: nil, rightSensorId: nil, leftFrame: nil, rightFrame: nil
        ), to: attemptsHandle)
        attempt += 1
    }

    func recordAttemptCompleted(
        leftSensorId: String?, leftFrame: SensorOrientationFrame?,
        rightSensorId: String?, rightFrame: SensorOrientationFrame?
    ) {
        append(CalibrationAttemptRecord(
            attempt: attempt, outcome: "completed", failedAtStep: nil, failureReason: nil,
            leftSensorId: leftSensorId, rightSensorId: rightSensorId,
            leftFrame: leftFrame?.dto, rightFrame: rightFrame?.dto
        ), to: attemptsHandle)
    }

    func close() {
        samplesHandle?.synchronizeFile()
        judgmentsHandle?.synchronizeFile()
        attemptsHandle?.synchronizeFile()
        samplesHandle?.closeFile()
        judgmentsHandle?.closeFile()
        attemptsHandle?.closeFile()
    }

    // MARK: - 写入

    private static let newline = Data([0x0A])

    /// 校准数据是留档分析用的，写失败不阻断校准流程本身（见 ADR-0012「后果」），所以这里静默吞掉错误。
    private func append<T: Encodable>(_ record: T, to handle: FileHandle?) {
        guard let handle, var data = try? encoder.encode(record) else { return }
        data.append(CalibrationRecorder.newline)
        handle.write(data)
    }
}
