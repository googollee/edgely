import XCTest
import AttSensorKit
@testable import Edgely

/// 录制结束的收尾（PRD F-003：记录结束时刻的电量与结束时间）。
/// 用 `MockAdapter` 代替真实设备：`RecordingSession` 只依赖 AttSensorKit 的协议。
final class RecordingSessionTests: XCTestCase {
    private func makeAdapter() throws -> MockAdapter {
        MockAdapter()
    }

    /// 模拟适配器的重建时间轴：每次 notify 带 2 帧、共用到达时间；`t` 以录制设的 `timeOrigin` 为基准、间隔均匀
    private final class Feeder {
        private var index = 0
        private var anchor: TimeInterval?
        func notify(_ adapter: MockAdapter) {
            let arrival = Date()
            let anchor = self.anchor ?? arrival.timeIntervalSince(adapter.timeOrigin ?? arrival)
            self.anchor = anchor
            for _ in 0..<2 {
                adapter.emit(DeviceSample(index: index, t: anchor + Double(index) * 0.02, accel: .zero, gyro: .zero, arrival: arrival))
                index += 1
            }
        }
    }

    private func runLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func readLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// 对照：会话一直被持有时，收尾正常执行。
    func test_stopWhileSessionIsRetained_writesEndTimeAndFinalBattery() throws {
        let session = RecordingSession(left: try makeAdapter(), right: nil, outputRate: .hz50, leftFrame: nil, rightFrame: nil)
        let directory = session.storageDirectory
        defer { try? FileManager.default.removeItem(at: directory) }

        session.start()
        runLoop(for: 1.3)
        session.stop()
        runLoop(for: 1.5)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SessionMeta.self, from: try Data(contentsOf: directory.appendingPathComponent("meta.json")))
        XCTAssertNotNil(meta.endedAt)
        XCTAssertEqual(readLines(directory.appendingPathComponent("battery.jsonl")).count, 2)
        withExtendedLifetime(session) {}
    }

    /// 和 `AppCoordinator.stopRecording()` 的顺序一致：`stop()` 之后立刻丢掉对会话的引用。
    func test_stopThenReleasingSession_stillWritesEndTimeAndFinalBattery() throws {
        let adapter = try makeAdapter()
        var session: RecordingSession? = RecordingSession(
            left: adapter, right: nil, outputRate: .hz50, leftFrame: nil, rightFrame: nil
        )
        let directory = try XCTUnwrap(session?.storageDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        session?.start()
        runLoop(for: 1.3) // start() 在约 1 秒后记录开始时刻的电量
        let batteryBeforeStop = readLines(directory.appendingPathComponent("battery.jsonl")).count
        XCTAssertEqual(batteryBeforeStop, 1, "开始时刻的电量快照")

        session?.stop()
        session = nil // AppCoordinator.stopRecording() 随后 returnToStart()，recording = nil
        runLoop(for: 1.5) // stop() 的收尾在约 1 秒后执行

        let metaData = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SessionMeta.self, from: metaData)
        XCTAssertNotNil(meta.endedAt, "meta.json 要有结束时间")
        XCTAssertEqual(readLines(directory.appendingPathComponent("battery.jsonl")).count, 2, "要有结束时刻的电量快照")
    }

    /// 录制的 `t` 是重建时间（间隔均匀），到达时间与绝对时间另存为 `arrivalT`/`wallClock`。
    func test_recordedSamples_useReconstructedTimeAndKeepArrivalAndWallClock() throws {
        let adapter = try makeAdapter()
        let session = RecordingSession(left: adapter, right: nil, outputRate: .hz50, leftFrame: nil, rightFrame: nil)
        let directory = session.storageDirectory
        defer { try? FileManager.default.removeItem(at: directory) }

        session.start()
        let feeder = Feeder()
        for _ in 0..<5 { // 每次 notify 带 2 帧，同一包里的帧共用到达时间
            feeder.notify(adapter)
            runLoop(for: 0.03)
        }

        let decoder = JSONDecoder()
        let records = try readLines(directory.appendingPathComponent("left.jsonl"))
            .map { try decoder.decode(SensorSampleRecord.self, from: Data($0.utf8)) }
            .filter { $0.type == "sample" }
        XCTAssertEqual(records.count, 10)
        XCTAssertEqual(records.map(\.frameIndex), Array(0..<10))
        for (a, b) in zip(records, records.dropFirst()) {
            XCTAssertEqual(b.t - a.t, 0.02, accuracy: 0.001, "重建时间间隔均匀")
        }
        XCTAssertEqual(records[0].arrivalT, records[1].arrivalT, "同一包共用到达时间")
        XCTAssertNotEqual(records[1].arrivalT, records[2].arrivalT)
        XCTAssertEqual(try XCTUnwrap(records[0].wallClock), Date().timeIntervalSince1970, accuracy: 5)
        // 第一帧的 t 锚定在到达时间上，和 GPS/电量同一基准
        XCTAssertEqual(records[0].t, try XCTUnwrap(records[0].arrivalT), accuracy: 0.001)
        session.stop()
        runLoop(for: 1.2)
    }
}
