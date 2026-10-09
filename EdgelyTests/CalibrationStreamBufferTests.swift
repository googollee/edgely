import XCTest
import simd
import AttSensorKit
@testable import Edgely

/// `CalibrationStreamBuffer`：窗口切片、`t` 的平移、站立基准的连续姿态。见 ADR-0011。
final class CalibrationStreamBufferTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)

    /// 构造一个 50Hz 的流：第 i 个样本 t = i·0.02，到达时间每 2 帧共用一个值（模拟 notify 成对）。
    private func fill(_ buffer: CalibrationStreamBuffer, count: Int) {
        for i in 0..<count {
            let arrival = origin.addingTimeInterval(Double(i / 2) * 0.04)
            buffer.append(DeviceSample(index: i, t: Double(i) * 0.02, accel: SIMD3(0, 0, -1), gyro: .zero, arrival: arrival))
        }
    }

    func test_window_picksByArrivalTime_andShiftsTToWindowStart() {
        let buffer = CalibrationStreamBuffer()
        fill(buffer, count: 100)

        // 到达时间 [0.4, 0.8] 对应 notify 10...20，即样本 20...41
        let window = buffer.window(from: origin.addingTimeInterval(0.4), to: origin.addingTimeInterval(0.8))

        XCTAssertEqual(window.first?.frameIndex, 20)
        XCTAssertEqual(window.last?.frameIndex, 41)
        XCTAssertEqual(window.first?.t, 0)
        // t 是设备适配层按整条流重建的，平移之后 dt 不变，不依赖窗口怎么切
        for (a, b) in zip(window.dropFirst(), window) { XCTAssertEqual(a.t - b.t, 0.02, accuracy: 1e-9) }
        XCTAssertEqual(window.first?.arrivalT, 0)
    }

    func test_sameSample_hasSameShiftedT_regardlessOfWindow() {
        let buffer = CalibrationStreamBuffer()
        fill(buffer, count: 100)
        let early = buffer.window(from: origin, to: origin.addingTimeInterval(1.0))
        let late = buffer.window(from: origin.addingTimeInterval(0.4), to: origin.addingTimeInterval(1.0))
        // 样本 30：在 early 里 t=0.6，在 late 里是相对 late 起点（样本 20，t=0.4）的 0.2
        XCTAssertEqual(early.first { $0.frameIndex == 30 }?.t ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(late.first { $0.frameIndex == 30 }?.t ?? -1, 0.2, accuracy: 1e-9)
    }

    func test_window_withoutSamples_isEmpty() {
        let buffer = CalibrationStreamBuffer()
        fill(buffer, count: 10)
        XCTAssertTrue(buffer.window(from: origin.addingTimeInterval(100), to: origin.addingTimeInterval(101)).isEmpty)
    }

    // MARK: - 站立基准的连续姿态

    /// 绕 z 轴以 `rate` deg/s 匀速转的 50Hz 流，帧序号 `startIndex` 起，全部在 `origin` 之后按 20ms 到达。
    private func fillSpinning(_ buffer: CalibrationStreamBuffer, count: Int, rate: Float, startIndex: Int = 0, skipping skipped: Set<Int> = []) {
        for i in 0..<count where !skipped.contains(i) {
            buffer.append(DeviceSample(
                index: startIndex + i, t: Double(startIndex + i) * 0.02, accel: SIMD3(0, 0, -1), gyro: SIMD3(0, 0, rate),
                arrival: origin.addingTimeInterval(Double(i) * 0.02)
            ))
        }
    }

    func test_startAttitude_integratesFromStandingAnchor() {
        let buffer = CalibrationStreamBuffer()
        fillSpinning(buffer, count: 100, rate: 90) // 每帧 90°/s × 0.02s = 1.8°
        buffer.anchorStanding(at: origin.addingTimeInterval(0.2)) // 锚点是样本 10

        // 窗口从样本 60 开始：锚点到窗口第一个样本之间积分 50 帧 = 90°
        let q = buffer.startAttitude(windowFrom: origin.addingTimeInterval(1.2), to: origin.addingTimeInterval(1.9))

        XCTAssertNotNil(q)
        XCTAssertEqual(q!.angle * 180 / .pi, 90, accuracy: 0.01)
        XCTAssertEqual(q!.axis.z, 1, accuracy: 1e-5)
    }

    func test_startAttitude_firstWindowRightAfterAnchor_isOneStep() {
        let buffer = CalibrationStreamBuffer()
        fillSpinning(buffer, count: 50, rate: 90)
        buffer.anchorStanding(at: origin.addingTimeInterval(0.2)) // 样本 10
        // 窗口第一个样本是样本 11：只积分了锚点那一帧的角速度
        let q = buffer.startAttitude(windowFrom: origin.addingTimeInterval(0.205), to: origin.addingTimeInterval(0.9))
        XCTAssertEqual(q!.angle * 180 / .pi, 1.8, accuracy: 0.01)
    }

    func test_startAttitude_isNil_withoutAnchor() {
        let buffer = CalibrationStreamBuffer()
        fillSpinning(buffer, count: 50, rate: 90)
        XCTAssertNil(buffer.startAttitude(windowFrom: origin, to: origin.addingTimeInterval(1)))
    }

    func test_startAttitude_isNil_whenStreamHasGapBetweenAnchorAndWindow() {
        let buffer = CalibrationStreamBuffer()
        fillSpinning(buffer, count: 100, rate: 90, skipping: [30, 31, 32]) // 帧序号断开
        buffer.anchorStanding(at: origin.addingTimeInterval(0.2))
        XCTAssertNil(buffer.startAttitude(windowFrom: origin.addingTimeInterval(1.2), to: origin.addingTimeInterval(1.9)),
                     "积分区间里有缺口时不硬积分，由调用方退回最小旋转")
    }

    func test_anchorStanding_reanchorDiscardsPreviousIntegration() {
        let buffer = CalibrationStreamBuffer()
        fillSpinning(buffer, count: 100, rate: 90)
        buffer.anchorStanding(at: origin.addingTimeInterval(0.2))
        buffer.anchorStanding(at: origin.addingTimeInterval(1.0)) // 整体重来后重新站立：锚点是样本 50
        let q = buffer.startAttitude(windowFrom: origin.addingTimeInterval(1.2), to: origin.addingTimeInterval(1.9))
        XCTAssertEqual(q!.angle * 180 / .pi, 18, accuracy: 0.01, "从样本 50 积分到样本 60 共 10 帧 = 18°")
    }
}
