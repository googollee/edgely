import XCTest
import simd
@testable import Edgely

/// ADR-0017：回放位移 = 当前位置 − 窗口内平均位置。
final class DisplacementCalculatorTests: XCTestCase {
    /// 传感器 x = 前、y = 左、z = 上（静止时加速度计读数向上，所以 down = -z）
    private let frame = SensorOrientationFrame(down: SIMD3(0, 0, -1), front: SIMD3(1, 0, 0), left: SIMD3(0, 1, 0))
    private let g = 9.80665

    /// 姿态不变、位置在前-上平面里做半径 r、频率 f 的圆周运动的合成数据
    private func circle(radius r: Double, hz f: Double, seconds: Double, startT: Double = 0) -> [SensorReading] {
        let w = 2 * Double.pi * f
        return stride(from: 0.0, to: seconds, by: 0.02).map { t in
            let aFront = -r * w * w * cos(w * t)
            let aUp = -r * w * w * sin(w * t)
            return SensorReading(t: startT + t, accel: SIMD3(Float(aFront / g), 0, Float(aUp / g + 1)), gyro: .zero)
        }
    }

    func test_stationary_hasNoDisplacement() {
        let readings = (0..<500).map { SensorReading(t: Double($0) * 0.02, accel: SIMD3(0, 0, 1), gyro: .zero) }
        let track = DisplacementCalculator.track(readings: readings, gaps: [], frame: frame)
        let d = DisplacementCalculator.displacements(track: track, window: 2)
        let valid = d.compactMap { $0 }
        XCTAssertFalse(valid.isEmpty)
        XCTAssertLessThan(valid.map { simd_length($0) }.max() ?? 0, 0.01)
    }

    func test_circularMotion_recoversRadius() {
        // 窗口 = 一个周期，位置均值是圆心，位移幅度应当是半径；渲染坐标里前 = +z、上 = +y
        let readings = circle(radius: 0.15, hz: 1, seconds: 20)
        let track = DisplacementCalculator.track(readings: readings, gaps: [], frame: frame)
        let d = DisplacementCalculator.displacements(track: track, window: 1)
        let mid = d[500..<700].compactMap { $0 }
        XCTAssertEqual(mid.count, 200)
        for v in mid {
            XCTAssertEqual(simd_length(SIMD2(v.y, v.z)), 0.15, accuracy: 0.02)
            XCTAssertEqual(v.x, 0, accuracy: 0.01)
        }
    }

    func test_windowEdges_haveNoDisplacement() {
        let readings = circle(radius: 0.1, hz: 1, seconds: 10)
        let track = DisplacementCalculator.track(readings: readings, gaps: [], frame: frame)
        let d = DisplacementCalculator.displacements(track: track, window: 2)
        XCTAssertNil(d[0])
        XCTAssertNil(d[49]) // t = 0.98，窗口起点 < 0
        XCTAssertNotNil(d[51])
        XCTAssertNil(d[readings.count - 1])
    }

    func test_gap_splitsSegments_andHidesDisplacementNearIt() {
        let first = circle(radius: 0.1, hz: 1, seconds: 10)
        let second = circle(radius: 0.1, hz: 1, seconds: 10, startT: 15)
        let readings = first + second
        let gaps = [DataGap(start: first.last!.t, end: 15)]
        let track = DisplacementCalculator.track(readings: readings, gaps: gaps, frame: frame)
        let d = DisplacementCalculator.displacements(track: track, window: 2)
        let lastOfFirst = first.count - 1
        XCTAssertNil(d[lastOfFirst])
        XCTAssertNil(d[lastOfFirst - 20]) // 距缺口 0.4 秒，窗口越过缺口
        XCTAssertNotNil(d[lastOfFirst - 70])
        XCTAssertNil(d[first.count])      // 缺口后第一个点
        XCTAssertNotNil(d[first.count + 70])
    }

    func test_windowIndex_isNearestEarlierSample() {
        let readings = (0..<5).map { SensorReading(t: Double($0), accel: .zero, gyro: .zero) }
        XCTAssertEqual(DisplacementCalculator.index(at: 2.5, in: readings), 2)
        XCTAssertEqual(DisplacementCalculator.index(at: -1, in: readings), 0)
        XCTAssertNil(DisplacementCalculator.index(at: 1, in: []))
    }
}
