import simd

/// 见 ADR-0005：把加速度计原始数据换算成渲染用的姿态，用于驱动鞋形模型（Pose3DView）。
/// 不使用 Angle 字段（欧拉角约定尚未验证）。
///
/// 数学关系：传感器和鞋是刚性固定在一起的，"传感器原始坐标系"里的向量要经过一次固定的换算
/// （由 F-002 校准时测出的 front/down/left 决定）才能变成"渲染世界坐标系"里的向量——
/// 不能把传感器原始读数直接当世界坐标用（两者是不同的坐标系，只是恰好都是 3 个数）。
enum PoseAlignment {
    /// 渲染世界坐标系里选定的方向（对应 Pose3DView 鞋形几何体的朝向、以及相机机位）：
    /// 鞋底 = -Y，脚尖 = +Z（相机从 -Z 往 +Z 看，脚尖朝屏幕里、脚跟朝屏幕外），左 = -X
    static let worldDown = SIMD3<Float>(0, -1, 0)
    static let worldFront = SIMD3<Float>(0, 0, 1)
    static let worldLeft = SIMD3<Float>(-1, 0, 0)

    /// 传感器原始坐标系 -> 渲染世界坐标系的换算旋转（一个 session 内为常量，由校准结果决定）
    static func sensorToWorld(frame: SensorOrientationFrame) -> simd_quatf {
        let sensorBasis = simd_float3x3([frame.front, frame.down, frame.left])
        let worldBasis = simd_float3x3([worldFront, worldDown, worldLeft])
        return simd_quatf(worldBasis * sensorBasis.transpose)
    }

    /// 每个回放时间点的最终渲染旋转：当前加速度计读数先换算到世界坐标系，
    /// 再算出"世界下方向 -> 当前重力方向"的最短路径旋转——不含偏航（见 ADR-0005 已知局限）。
    /// 加速度计读数接近零向量（数据异常）时返回 nil，不渲染。
    static func renderOrientation(frame: SensorOrientationFrame, currentAccel: SIMD3<Float>) -> simd_quatf? {
        let len = simd_length(currentAccel)
        guard len > 0.01 else { return nil }
        let currentDownWorld = sensorToWorld(frame: frame).act(currentAccel / len)
        return simd_quatf(from: worldDown, to: currentDownWorld)
    }
}
