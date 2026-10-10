import XCTest
@testable import Edgely

/// 校准落盘记录的编码（见 ADR-0012「校准数据落盘」、docs/reference/session-data-format.md）。
final class CalibrationRecorderTests: XCTestCase {
    // MARK: - 抬脚窗口的判定记录（ADR-0012）

    private func decode(_ record: CalibrationJudgmentRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_motionJudgment_encodesPeakSpeedAndResult() throws {
        let record = CalibrationJudgmentRecord(
            attempt: 2, step: "liftLeft", sensorId: "S1", motionPeakSpeed: 0.87, windowDuration: 1.4, sampleCount: 70
        )
        let json = try decode(record)
        XCTAssertEqual(json["result"] as? String, "motion")
        XCTAssertEqual(json["step"] as? String, "liftLeft")
        XCTAssertEqual(json["attempt"] as? Int, 2)
        XCTAssertEqual(json["sensorId"] as? String, "S1")
        XCTAssertEqual(try XCTUnwrap(json["peakSpeed"] as? Double), 0.87, accuracy: 1e-5)
        XCTAssertEqual(json["sampleCount"] as? Int, 70)
    }

    func test_motionJudgment_withoutPeakSpeed_isInsufficientData() throws {
        let record = CalibrationJudgmentRecord(
            attempt: 1, step: "liftRight", sensorId: "S1", motionPeakSpeed: nil, windowDuration: 0, sampleCount: 1
        )
        let json = try decode(record)
        XCTAssertEqual(json["result"] as? String, "insufficientData")
        XCTAssertNil(json["peakSpeed"])
    }

    func test_frameJudgment_encodesSegmentTimes() throws {
        let down = SIMD3<Float>(0, 0, -1)
        var window: [TimedSample] = []
        for i in 0..<100 {
            window.append(TimedSample(t: Double(i) * 0.02, accel: down, gyro: .zero))
        }
        let outcome = CalibrationMath.segmentedFrame(from: window, standingDown: down)
        let record = CalibrationJudgmentRecord(attempt: 1, step: "stride", sensorId: "S1", outcome: outcome)
        let json = try decode(record)
        // 没有活动帧时用整个窗口：区间起止就是窗口首尾
        XCTAssertEqual(try XCTUnwrap(json["segmentStartT"] as? Double), 0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(json["segmentEndT"] as? Double), 1.98, accuracy: 1e-6)
    }
}
