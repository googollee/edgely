import XCTest
import AttSensorKit
import simd
@testable import Edgely

/// 回放必须能读懂当前代码录制的数据：用 `RecordingSession` 真实落盘，再按回放页的读取流程读回来。
final class ReplayRoundTripTests: XCTestCase {
    private let frame = SensorOrientationFrame(down: SIMD3(0, 0, -1), front: SIMD3(1, 0, 0), left: SIMD3(0, 1, 0))
    private let g = 9.80665

    private func runLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func test_recordedSession_isReadableByReplay_andProducesDisplacement() throws {
        let adapter = MockAdapter()
        let session = RecordingSession(left: adapter, right: nil, outputRate: .hz50, leftFrame: frame, rightFrame: nil, calibrationId: "cal-1")
        let directory = session.storageDirectory
        defer { try? FileManager.default.removeItem(at: directory) }

        session.start()
        // 前-上平面里半径 0.15m、1Hz 的圆周运动，姿态不变；整个采样流 20 秒，每个数据包 2 帧
        let r = 0.15, w = 2 * Double.pi
        let origin = adapter.timeOrigin ?? Date()
        for i in 0..<1000 {
            let t = Double(i) * 0.02
            let accel = SIMD3<Float>(Float(-r * w * w * cos(w * t) / g), 0, Float(-r * w * w * sin(w * t) / g + 1))
            adapter.emit(DeviceSample(index: i, t: t, accel: accel, gyro: i == 10 ? SIMD3(1, 2, 3) : .zero, arrival: origin.addingTimeInterval(t)))
        }
        session.stop()
        runLoop(for: 1.5)

        // —— 以下和 ReviewView.load() 的读取方式一致 ——
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SessionMeta.self, from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
        XCTAssertEqual(meta.leftCalibration?.frame, frame, "校准参考系随 session 保存，回放据此对齐并计算位移")

        let loaded = SessionFileLoader.loadSamples(url: directory.appendingPathComponent("left.jsonl"))
        XCTAssertEqual(loaded.samples.count, 1000)
        XCTAssertEqual(loaded.samples[10].gyro, SIMD3(1, 2, 3), "角速度随采样落盘，位移的姿态估计要用")
        XCTAssertTrue(loaded.gaps.isEmpty)

        let track = DisplacementCalculator.track(readings: loaded.samples, gaps: loaded.gaps, frame: try XCTUnwrap(meta.leftCalibration).frame)
        let d = DisplacementCalculator.displacements(track: track, window: 1)
        let mid = d[300..<700].compactMap { $0 }
        XCTAssertEqual(mid.count, 400, "中间段都应有位移")
        for v in mid { XCTAssertEqual(simd_length(SIMD2(v.y, v.z)), 0.15, accuracy: 0.02) }
        XCTAssertNil(d[0], "开头不足半个窗口，不展示位移")
    }

    func test_gapRecords_writtenByCode_areParsedAsGaps() throws {
        let start = Date()
        let encoder = JSONEncoder()
        func line(_ r: SensorSampleRecord) throws -> String { String(decoding: try encoder.encode(r), as: UTF8.self) }
        func sample(_ t: Double) throws -> String {
            try line(.sample(sample: DeviceSample(index: 0, t: t, accel: SIMD3(0, 0, 1), gyro: .zero, arrival: start.addingTimeInterval(t)), startDate: start, angle: nil))
        }
        let lines = [
            try sample(4.98), try sample(5.0),
            try line(.gapStart(arrival: start.addingTimeInterval(7), startDate: start)),
            try line(.gapEnd(arrival: start.addingTimeInterval(9.5), startDate: start)),
            try sample(9.5),
        ]
        let result = SessionFileLoader.parseSamples(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(result.gaps, [DataGap(start: 5.0, end: 9.5)])
        XCTAssertEqual(result.samples.count, 3)
    }
}
