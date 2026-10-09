import XCTest
@testable import Edgely

/// 回放页读取传感器文件时的缺口解析（PRD F4：复盘时要看得出哪段时间数据缺失）。
final class SessionFileLoaderTests: XCTestCase {
    private func sample(_ t: Double) -> String {
        #"{"t":\#(t),"type":"sample","accelX":0,"accelY":0,"accelZ":-1,"gyroX":0,"gyroY":0,"gyroZ":0,"angleX":0,"angleY":0,"angleZ":0}"#
    }
    private func gap(_ type: String, _ t: Double) -> String { #"{"t":\#(t),"type":"\#(type)"}"# }
    private func data(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    func test_noGaps() {
        let result = SessionFileLoader.parseSamples(data([sample(0), sample(0.02)]))
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func test_gapStartsAtLastSampleBeforeDetection_andEndsAtGapEnd() {
        // 最后一个采样在 5.0 秒，连续 2 秒没数据，7.0 秒判定断线；9.5 秒重新收到数据
        let result = SessionFileLoader.parseSamples(data([sample(4.98), sample(5.0), gap("gap_start", 7.0), sample(9.5), gap("gap_end", 9.5), sample(9.52)]))
        XCTAssertEqual(result.gaps, [DataGap(start: 5.0, end: 9.5)])
        XCTAssertEqual(result.samples.count, 4)
    }

    func test_multipleGaps() {
        let result = SessionFileLoader.parseSamples(data([
            sample(1), gap("gap_start", 3), sample(4), gap("gap_end", 4),
            sample(10), gap("gap_start", 12), sample(15), gap("gap_end", 15),
        ]))
        XCTAssertEqual(result.gaps, [DataGap(start: 1, end: 4), DataGap(start: 10, end: 15)])
    }

    func test_unclosedGap_endsAtSessionLength() {
        let lines = [sample(1), gap("gap_start", 3)]
        XCTAssertEqual(SessionFileLoader.parseSamples(data(lines), sessionLength: 20).gaps, [DataGap(start: 1, end: 20)])
        XCTAssertEqual(SessionFileLoader.parseSamples(data(lines)).gaps, [DataGap(start: 1, end: 3)], "没有会话时长时取最后一条记录的时刻")
    }

    func test_gapBeforeAnySample_startsAtDetection() {
        let result = SessionFileLoader.parseSamples(data([gap("gap_start", 2), sample(6), gap("gap_end", 6)]))
        XCTAssertEqual(result.gaps, [DataGap(start: 2, end: 6)])
    }

    func test_magneticRecordsAreNotSamples() {
        let magnetic = #"{"t":1,"type":"magnetic","magX":1,"magY":2,"magZ":3}"#
        let result = SessionFileLoader.parseSamples(data([sample(0), magnetic]))
        XCTAssertEqual(result.samples.count, 1)
    }

    func test_gapContains_isStrictlyInside() {
        let gap = DataGap(start: 5, end: 9)
        XCTAssertFalse(gap.contains(5), "端点上各有一个真实采样点")
        XCTAssertTrue(gap.contains(7))
        XCTAssertFalse(gap.contains(9))
    }
}
