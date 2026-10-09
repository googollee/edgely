import AttSensorKit
import Foundation
import simd

/// 单条落盘记录。type 区分正常采样点、断线缺口标记、磁场读数（见 ADR-0001、PRD F4）。
struct SensorSampleRecord: Codable {
    /// 相对本次录制开始的秒数。`sample` 是适配器重建的时间（见 ADR-0010；丢帧修正见 ADR-0014，由适配器流式估计，落盘后不再修改）；
    /// 其余类型（磁场、缺口标记）没有采样序号，仍是 BLE 到达时间（手机本地时钟）
    let t: Double
    /// BLE 数据包到达手机的时间，相对本次录制开始的秒数（同一包里的帧共用同一个值）。旧数据没有这个字段，其 `t` 就是到达时间
    let arrivalT: Double?
    /// 帧在当前这条采样流里的序号，从 0 起。断线重连后流重开，序号会重新从 0 计；旧数据没有。只有 `sample` 有
    let frameIndex: Int?
    /// 到达时刻的手机绝对时间（Unix 秒），旧数据没有
    let wallClock: Double?
    let type: String // "sample" | "gap_start" | "gap_end" | "magnetic"
    let accelX: Float?
    let accelY: Float?
    let accelZ: Float?
    let gyroX: Float?
    let gyroY: Float?
    let gyroZ: Float?
    let angleX: Float?
    let angleY: Float?
    let angleZ: Float?
    /// 磁场读数（µT，由适配器换算，见 `MagneticFieldProviding`），只在 type == "magnetic" 时有值。
    /// 磁场不随实时数据帧自动推送、采样率远低于 accel/gyro（见 RecordingSession.magneticInterval），
    /// 单独记一行、不和 "sample" 合并（见 ADR-0013）。
    /// MVP 阶段只采集留档，不参与任何计算
    let magX: Float?
    let magY: Float?
    let magZ: Float?

    /// - Parameter angle: 设备自带的欧拉角（`EulerAngleProviding`），设备不提供时为 nil
    static func sample(sample: DeviceSample, startDate: Date, angle: SIMD3<Float>?) -> SensorSampleRecord {
        SensorSampleRecord(
            t: sample.t, arrivalT: sample.arrival.timeIntervalSince(startDate), frameIndex: sample.index,
            wallClock: sample.arrival.timeIntervalSince1970, type: "sample",
            accelX: sample.accel.x, accelY: sample.accel.y, accelZ: sample.accel.z,
            gyroX: sample.gyro.x, gyroY: sample.gyro.y, gyroZ: sample.gyro.z,
            angleX: angle?.x, angleY: angle?.y, angleZ: angle?.z,
            magX: nil, magY: nil, magZ: nil
        )
    }

    static func magnetic(arrival: Date, startDate: Date, x: Float, y: Float, z: Float) -> SensorSampleRecord {
        let arrivalT = arrival.timeIntervalSince(startDate)
        return SensorSampleRecord(
            t: arrivalT, arrivalT: arrivalT, frameIndex: nil, wallClock: arrival.timeIntervalSince1970, type: "magnetic",
            accelX: nil, accelY: nil, accelZ: nil, gyroX: nil, gyroY: nil, gyroZ: nil, angleX: nil, angleY: nil, angleZ: nil,
            magX: x, magY: y, magZ: z
        )
    }

    static func gapStart(arrival: Date, startDate: Date) -> SensorSampleRecord {
        let arrivalT = arrival.timeIntervalSince(startDate)
        return SensorSampleRecord(t: arrivalT, arrivalT: arrivalT, frameIndex: nil, wallClock: arrival.timeIntervalSince1970, type: "gap_start", accelX: nil, accelY: nil, accelZ: nil, gyroX: nil, gyroY: nil, gyroZ: nil, angleX: nil, angleY: nil, angleZ: nil, magX: nil, magY: nil, magZ: nil)
    }

    static func gapEnd(arrival: Date, startDate: Date) -> SensorSampleRecord {
        let arrivalT = arrival.timeIntervalSince(startDate)
        return SensorSampleRecord(t: arrivalT, arrivalT: arrivalT, frameIndex: nil, wallClock: arrival.timeIntervalSince1970, type: "gap_end", accelX: nil, accelY: nil, accelZ: nil, gyroX: nil, gyroY: nil, gyroZ: nil, angleX: nil, angleY: nil, angleZ: nil, magX: nil, magY: nil, magZ: nil)
    }
}

struct GPSRecord: Codable {
    let t: Double
    let lat: Double
    let lon: Double
    let altitude: Double
    let speed: Double
}

struct BatteryRecord: Codable {
    let t: Double
    let leftPercent: Int?
    let rightPercent: Int?
    let phonePercent: Int?
}
