import AttSensorKit
import Foundation
import UIKit
import CoreLocation
import simd

/// F3/F4/F6：录制配置与执行、断线检测与标记、GPS 轨迹记录。
/// left/right 均为可选——本次 session 使用 1 个还是 2 个传感器，见 PRD F1/F3。
final class RecordingSession: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var leftConnected = true
    @Published var rightConnected = true
    @Published var leftGapCount = 0
    @Published var rightGapCount = 0

    let sessionId: String
    let hasLeft: Bool
    let hasRight: Bool
    var storageDirectory: URL { storage.directory }

    private let storage: SessionStorage
    private let left: DeviceAdapter?
    private let right: DeviceAdapter?
    private let locationLogger = LocationLogger()

    private var startDate = Date()
    private var timer: Timer?
    private var batteryTimer: Timer?
    private var disconnectTimer: Timer?
    private var magneticTimer: Timer?

    private var leftGapOpen = false
    private var rightGapOpen = false

    /// 断线判定阈值，见 PRD F4
    private let disconnectThreshold: TimeInterval = 2.0
    /// 电量快照间隔，见 PRD F3
    private let batteryInterval: TimeInterval = 60
    /// 磁场轮询间隔：MVP 只为留档尽量多采集，不追求逐帧同步（磁场寄存器不随实时数据帧自动推送，需要主动轮询读取）
    private let magneticInterval: TimeInterval = 0.5

    private let outputRate: OutputRate
    private let outputRateLabel: String
    private let leftFrameDTO: CalibrationFrameDTO?
    private let rightFrameDTO: CalibrationFrameDTO?
    private let calibrationId: String?

    /// - Parameters:
    ///   - left: 左脚传感器，未使用时为 nil
    ///   - right: 右脚传感器，未使用时为 nil（left、right 至少一个非 nil）
    ///   - calibrationId: 本次使用的校准记录 id，写进 meta.json 供事后关联（见 ADR-0012）
    init(left: DeviceAdapter?, right: DeviceAdapter?, outputRate: OutputRate,
         leftFrame: SensorOrientationFrame?, rightFrame: SensorOrientationFrame?, calibrationId: String? = nil) {
        precondition(left != nil || right != nil, "RecordingSession 至少需要一个传感器")
        self.left = left
        self.right = right
        self.hasLeft = left != nil
        self.hasRight = right != nil
        self.outputRate = outputRate
        self.outputRateLabel = outputRate.label
        self.leftFrameDTO = leftFrame?.dto
        self.rightFrameDTO = rightFrame?.dto
        self.calibrationId = calibrationId
        self.sessionId = RecordingSession.makeSessionId()
        self.storage = SessionStorage(sessionId: sessionId, hasLeft: hasLeft, hasRight: hasRight)

        subscribe(to: left, isLeft: true)
        subscribe(to: right, isLeft: false)
        locationLogger.onLocation = { [weak self] loc in
            self?.handleLocation(loc)
        }

        for sensor in [left, right] {
            (sensor as? OutputRateConfigurable)?.setOutputRate(outputRate)
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        writeMeta(endedAt: nil)
    }

    /// 接上适配器的数据出口。设备自带欧拉角（`EulerAngleProviding`）的，随同一帧一起取；否则只有采样流，欧拉角留空。
    /// 磁场是可选能力（`MagneticFieldProviding`），设备没有就不采
    private func subscribe(to adapter: DeviceAdapter?, isLeft: Bool) {
        if let euler = adapter as? EulerAngleProviding {
            euler.onSampleWithAngle = { [weak self] sample, angle in
                self?.handleSample(sample, angle: angle, isLeft: isLeft)
            }
        } else {
            adapter?.onSample = { [weak self] sample in
                self?.handleSample(sample, angle: nil, isLeft: isLeft)
            }
        }
        (adapter as? MagneticFieldProviding)?.onMagneticField = { [weak self] ut, at in
            self?.handleMagnetic(ut, at: at, isLeft: isLeft)
        }
    }

    private static func makeSessionId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func writeMeta(endedAt: Date?) {
        storage.writeMeta(SessionMeta(
            sessionId: sessionId,
            outputRate: outputRateLabel,
            bindingPosition: "雪靴",
            startedAt: startDate,
            endedAt: endedAt,
            sensorCount: (hasLeft ? 1 : 0) + (hasRight ? 1 : 0),
            dataFileNames: storage.dataFileNames,
            leftCalibration: leftFrameDTO,
            rightCalibration: rightFrameDTO,
            calibrationId: calibrationId
        ))
    }

    func start() {
        startDate = Date()
        // 采样流的时间零点设成录制开始，并重开流：之前（init 到 start 之间）收到的帧不属于这次录制的时间轴
        for sensor in [left, right] {
            sensor?.timeOrigin = startDate
            sensor?.resetStream()
        }
        locationLogger.start()

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate)
        }
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkDisconnects()
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: batteryInterval, repeats: true) { [weak self] _ in
            self?.snapshotBattery()
        }
        magneticTimer = Timer.scheduledTimer(withTimeInterval: magneticInterval, repeats: true) { [weak self] _ in
            (self?.left as? MagneticFieldProviding)?.requestMagneticField()
            (self?.right as? MagneticFieldProviding)?.requestMagneticField()
        }
        requestBatteries()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.snapshotBattery()
        }
    }

    func stop() {
        timer?.invalidate()
        disconnectTimer?.invalidate()
        batteryTimer?.invalidate()
        magneticTimer?.invalidate()
        // 适配器录制结束后还会被校准复用，零点要还回去，否则校准的 t 不再从 0 起
        left?.timeOrigin = nil
        right?.timeOrigin = nil
        locationLogger.stop()
        requestBatteries()
        // 等设备回应电量读取后记录结束时刻的快照，再收尾落盘。这里刻意强引用 self：调用方（AppCoordinator.stopRecording）
        // 在 stop() 之后马上释放会话，用 weak 的话收尾会因为 self 已经没了而整体跳过（没有结束电量、没有 endedAt、最后一次 fsync 也不执行）。
        // 闭包只活 1 秒，执行完即释放，不会形成长期的循环引用。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.snapshotBattery()
            self.writeMeta(endedAt: Date())
            self.storage.close()
        }
    }

    /// `sample.t` 已经是适配器重建好的、相对录制开始的时间（见 `DeviceAdapter.timeOrigin`），直接落盘。
    private func handleSample(_ sample: DeviceSample, angle: SIMD3<Float>?, isLeft: Bool) {
        let record = SensorSampleRecord.sample(sample: sample, startDate: startDate, angle: angle)
        // 缺口结束标记用到达时间：它标记的是"重新收到数据"的时刻，和 gap_start 同一个时钟
        if isLeft {
            storage.appendLeft(record)
            if leftGapOpen {
                storage.appendLeft(.gapEnd(arrival: sample.arrival, startDate: startDate))
                leftGapOpen = false
            }
            leftConnected = true
        } else {
            storage.appendRight(record)
            if rightGapOpen {
                storage.appendRight(.gapEnd(arrival: sample.arrival, startDate: startDate))
                rightGapOpen = false
            }
            rightConnected = true
        }
    }

    /// MVP：磁场只为留档采集，不参与断线判定/连接状态，单独落盘一行（type = "magnetic"），
    /// 不和 accel/gyro 的 sample 合并（见 ADR-0013）
    private func handleMagnetic(_ ut: SIMD3<Float>, at: Date, isLeft: Bool) {
        let record = SensorSampleRecord.magnetic(arrival: at, startDate: startDate, x: ut.x, y: ut.y, z: ut.z)
        if isLeft {
            storage.appendLeft(record)
        } else {
            storage.appendRight(record)
        }
    }

    private func checkDisconnects() {
        let now = Date()
        if let last = left?.lastRealtimeAt, now.timeIntervalSince(last) > disconnectThreshold {
            if !leftGapOpen {
                storage.appendLeft(.gapStart(arrival: now, startDate: startDate))
                leftGapOpen = true
                leftGapCount += 1
            }
            leftConnected = false
        }
        if let last = right?.lastRealtimeAt, now.timeIntervalSince(last) > disconnectThreshold {
            if !rightGapOpen {
                storage.appendRight(.gapStart(arrival: now, startDate: startDate))
                rightGapOpen = true
                rightGapCount += 1
            }
            rightConnected = false
        }
    }

    private func snapshotBattery() {
        let t = Date().timeIntervalSince(startDate)
        let phone = UIDevice.current.batteryLevel >= 0 ? Int(UIDevice.current.batteryLevel * 100) : nil
        storage.appendBattery(BatteryRecord(
            t: t, leftPercent: (left as? BatteryReporting)?.batteryPercent, rightPercent: (right as? BatteryReporting)?.batteryPercent, phonePercent: phone
        ))
        requestBatteries()
    }

    /// 设备具备电量能力（`BatteryReporting`）才读
    private func requestBatteries() {
        (left as? BatteryReporting)?.requestBattery()
        (right as? BatteryReporting)?.requestBattery()
    }

    private func handleLocation(_ loc: CLLocation) {
        let t = Date().timeIntervalSince(startDate)
        storage.appendGPS(GPSRecord(t: t, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, altitude: loc.altitude, speed: loc.speed))
    }
}
