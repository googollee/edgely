import Combine
import Foundation
import simd

// 设备不一定具备的能力（ADR-0016）。使用方用 `as?` 判断，设备不具备就跳过，不要求每个设备都实现。

/// 电量
public protocol BatteryReporting: DeviceAdapter {
    /// 电量百分比，还没读到时为 nil
    var batteryPercent: Int? { get }
    /// `batteryPercent` 的变化流（订阅时先给出当前值）
    var batteryPercentPublisher: AnyPublisher<Int?, Never> { get }
    /// 请求读一次电量，响应到达后更新 `batteryPercent`
    func requestBattery()
}

/// 磁场读数。MVP 阶段只为留档采集，不参与任何计算
public protocol MagneticFieldProviding: DeviceAdapter {
    /// 每收到一次磁场读数回调一次（已换算成 µT）和到达时间
    var onMagneticField: ((SIMD3<Float>, Date) -> Void)? { get set }
    /// 请求读一次磁场，响应到达后触发 `onMagneticField`
    func requestMagneticField()
}

/// 设备自带的欧拉角（deg）。录制留档用，不参与计算
public protocol EulerAngleProviding: DeviceAdapter {
    /// 每个实时样本回调一次：样本和同一帧的欧拉角。和 `onSample` 同时触发，各自独立订阅
    var onSampleWithAngle: ((DeviceSample, SIMD3<Float>) -> Void)? { get set }
}

/// 可设置回传速率
public protocol OutputRateConfigurable: DeviceAdapter {
    /// 设置回传速率，同时按新速率重开采样流（旧速率下的时间轴估计对新速率没有意义）
    func setOutputRate(_ rate: OutputRate)
}
