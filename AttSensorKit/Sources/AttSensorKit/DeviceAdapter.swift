import Combine
import Foundation
import simd

/// 设备适配层（ADR-0011、ADR-0016）的对外契约：把某一种姿态传感器的原始数据，按经验和协议说明重整成一条稳定的采样流。
///
/// 这一层**只重整、不切片、不保存历史**：窗口怎么切、历史留多久是使用方（校准流程、采样记录）的事。
/// 使用方只依赖这个协议和下面的能力协议（`Capabilities.swift`），不认识任何具体设备的协议细节。
/// 具体设备的实现通过 `DeviceAdapterFactory` 注册进 `DeviceAdapterRegistry`。
public protocol DeviceAdapter: AnyObject {
    /// 稳定的设备身份（校准结果按它对应回具体设备）
    var id: UUID { get }

    /// 连接是否就绪（订阅好数据通知）。断线后为 false，自动重连成功后重新为 true
    var isReady: Bool { get }
    /// `isReady` 的变化流（订阅时先给出当前值）。注意发布发生在值改变之前，要用回调给出的值，不要回头读 `isReady`
    var isReadyPublisher: AnyPublisher<Bool, Never> { get }

    /// 最近一次收到实时数据的时间。断线检测（PRD F4）只看它；电量等寄存器响应不算，
    /// 否则实时数据流停了、而寄存器读取仍有回应时，缺口会被遮住
    var lastRealtimeAt: Date? { get }

    /// 时间零点：设置后，每条流的 `DeviceSample.t` 都以它为基准——流的第一个样本 `t` = 到达时间 − 零点，之后按重建的间隔递增；
    /// 流每次重开（`resetStream()`、断线重连）都用重开后第一个样本的到达时间重新锚定，断线的缺口因此保留。
    /// 不设置（nil）时每条流的第一个样本 `t` 为 0，校准用的就是这种。
    /// 录制把它设成录制开始的时刻，样本的 `t` 就和 GPS、电量在同一基准上，使用方不需要自己平移。
    var timeOrigin: Date? { get set }

    /// 每整理出一个样本回调一次，保证按采样顺序、`t` 单调递增。同一时刻只有一个使用方订阅（后设置的覆盖先前的）。
    var onSample: ((DeviceSample) -> Void)? { get set }

    /// 开始一条新的流：帧序号从 0 重新计数，时间轴估计回到冷启动状态。
    /// 用在回传速率刚改过、或一次新的校准开始之前（旧速率的估计对新速率没有意义）。
    func resetStream()

    /// 设备管理器在外设连接成功（含断线后自动重连成功）后调用：适配器接手外设，开始发现特征值、订阅数据通知。
    /// 可能被调用多次（每次重连一次）。
    func start()

    /// 设备管理器在外设意外断开时调用：适配器把 `isReady` 置为 false
    func connectionDidDrop()
}

/// 整理后的采样。物理量已经是统一的单位（加速度 g，角速度 deg/s），设备协议的细节到这里为止。
public struct DeviceSample: Equatable {
    /// 在当前这条流里的帧序号，从 0 起，`resetStream()` 后重新计数
    public let index: Int
    /// 重建后的时间（秒）：严格单调，没有丢帧的地方间隔均匀，丢帧处按适配器的估计补上，不是 BLE 到达时间。
    /// 默认相对这条流的第一个样本；设了 `timeOrigin` 时相对零点
    public let t: TimeInterval
    public let accel: SIMD3<Float> // g
    public let gyro: SIMD3<Float>  // deg/s
    /// 该样本所在数据包到达手机的时间。这是唯一实测的时间，无论 `t` 如何重建都保留，供落盘和后期分析使用，校准算法不读
    public let arrival: Date

    public init(index: Int, t: TimeInterval, accel: SIMD3<Float>, gyro: SIMD3<Float>, arrival: Date) {
        self.index = index
        self.t = t
        self.accel = accel
        self.gyro = gyro
        self.arrival = arrival
    }
}

/// 设备回传速率。录制和校准都固定使用 50Hz，不提供其他档位：校准的数值积分依赖采样密度（ADR-0012）。
public enum OutputRate: String {
    case hz50

    public var label: String { "50Hz" }

    /// 丢帧估计的单位（帧）：BLE 一次 notify 带多少帧，丢包时一次丢掉一整个 notify
    public var framesPerNotify: Int { 2 }

    /// 名义采样周期（秒）
    public var nominalPeriod: TimeInterval { 0.02 }
}
