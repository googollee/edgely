import Foundation
import simd

struct CalibrationFrameDTO: Codable {
    let down: [Float]
    let front: [Float]
    let left: [Float]

    /// 读取 meta.json 时还原成 SensorOrientationFrame，供 F-005 姿态渲染使用（见 ADR-0005）
    var frame: SensorOrientationFrame {
        SensorOrientationFrame(
            down: SIMD3<Float>(down[0], down[1], down[2]),
            front: SIMD3<Float>(front[0], front[1], front[2]),
            left: SIMD3<Float>(left[0], left[1], left[2])
        )
    }
}

extension SensorOrientationFrame {
    var dto: CalibrationFrameDTO {
        CalibrationFrameDTO(
            down: [down.x, down.y, down.z],
            front: [front.x, front.y, front.z],
            left: [left.x, left.y, left.z]
        )
    }
}

/// session 元数据，即 meta.json（字段见 docs/reference/session-data-format.md）
struct SessionMeta: Codable {
    let sessionId: String
    let outputRate: String
    let startedAt: Date
    var endedAt: Date?
    let sensorCount: Int // 1 或 2，见 PRD F-001/F-003
    let dataFileNames: [String] // 本次实际生成的数据文件名列表
    let leftCalibration: CalibrationFrameDTO?
    let rightCalibration: CalibrationFrameDTO?
    /// 本次使用的校准记录 id（`Calibrations/<calibrationId>/`），供事后关联"这趟数据用的是哪次校准的参考系"
    /// （见 ADR-0012）。校准数据落盘失败时可能为 nil。
    let calibrationId: String?
}
