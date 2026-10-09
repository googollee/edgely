#if DEBUG
import Combine
import Foundation
import simd

/// 模拟设备适配器，仅用于测试和 DEBUG 构建（Release 里没有）。
/// 测试里直接设置属性、调用 `emit` 推送样本；`start()` 之后按 50Hz 推送静止的样本（重力沿 +Z），并回报电量，
/// 让没有真实设备时也能走界面流程。
open class MockAdapter: DeviceAdapter, BatteryReporting {
    public let id = UUID()

    @Published public var isReady = false
    @Published public var batteryPercent: Int?
    public var lastRealtimeAt: Date?
    public var timeOrigin: Date?
    public var onSample: ((DeviceSample) -> Void)?

    public var isReadyPublisher: AnyPublisher<Bool, Never> { $isReady.eraseToAnyPublisher() }
    public var batteryPercentPublisher: AnyPublisher<Int?, Never> { $batteryPercent.eraseToAnyPublisher() }

    public private(set) var batteryRequests = 0
    private var nextIndex = 0
    private var timer: Timer?

    public init() {}

    deinit { timer?.invalidate() }

    open func resetStream() { nextIndex = 0 }

    /// 模拟设备的连接：立刻就绪，开始推送静止样本
    open func start() {
        isReady = true
        if batteryPercent == nil { batteryPercent = 80 }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: OutputRate.hz50.nominalPeriod, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Double(self.nextIndex) * OutputRate.hz50.nominalPeriod
            self.emit(DeviceSample(index: self.nextIndex, t: t, accel: SIMD3<Float>(0, 0, 1), gyro: .zero, arrival: Date()))
        }
    }

    open func connectionDidDrop() {
        isReady = false
        timer?.invalidate()
        timer = nil
    }

    open func requestBattery() { batteryRequests += 1 }

    /// 推送一个样本：更新最近收到数据的时间并回调订阅者
    public func emit(_ sample: DeviceSample) {
        lastRealtimeAt = sample.arrival
        nextIndex = sample.index + 1
        onSample?(sample)
    }
}
#endif
