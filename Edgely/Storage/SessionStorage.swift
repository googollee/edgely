import Foundation

/// 原始数据存储：每个 session 一个目录，按数据流拆成多个 JSON Lines 文件（见 ADR-0001）。
final class SessionStorage {
    let sessionId: String
    let directory: URL

    private var leftHandle: FileHandle?
    private var rightHandle: FileHandle?
    private var gpsHandle: FileHandle?
    private var batteryHandle: FileHandle?

    private var fsyncTimer: Timer?
    /// 见 ADR-0003：崩溃场景下每路数据流最坏情况只丢失这个时间窗口内的数据
    private let fsyncInterval: TimeInterval = 10

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    var metaURL: URL { directory.appendingPathComponent("meta.json") }

    /// 本次 session 实际生成的数据文件名（不含 meta.json），写入 meta.json 供后续读取时判断包含哪些数据流
    let dataFileNames: [String]

    /// 见 PRD F1/F3：传感器数量为 1~2 个，`left.jsonl`/`right.jsonl` 只在对应传感器被使用时才创建
    init(sessionId: String, hasLeft: Bool, hasRight: Bool) {
        self.sessionId = sessionId
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = docs.appendingPathComponent("Sessions").appendingPathComponent(sessionId)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var names = ["gps.jsonl", "battery.jsonl"]
        if hasLeft { names.append("left.jsonl") }
        if hasRight { names.append("right.jsonl") }
        self.dataFileNames = names

        for name in names {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        if hasLeft {
            leftHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("left.jsonl"))
            leftHandle?.seekToEndOfFile()
        }
        if hasRight {
            rightHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("right.jsonl"))
            rightHandle?.seekToEndOfFile()
        }
        gpsHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("gps.jsonl"))
        batteryHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("battery.jsonl"))
        gpsHandle?.seekToEndOfFile()
        batteryHandle?.seekToEndOfFile()

        fsyncTimer = Timer.scheduledTimer(withTimeInterval: fsyncInterval, repeats: true) { [weak self] _ in
            self?.syncToDisk()
        }
    }

    /// 见 ADR-0003：定期 fsync，而不是每条记录都同步
    private func syncToDisk() {
        leftHandle?.synchronizeFile()
        rightHandle?.synchronizeFile()
        gpsHandle?.synchronizeFile()
        batteryHandle?.synchronizeFile()
    }

    func appendLeft(_ record: SensorSampleRecord) { append(record, to: leftHandle) }
    func appendRight(_ record: SensorSampleRecord) { append(record, to: rightHandle) }
    func appendGPS(_ record: GPSRecord) { append(record, to: gpsHandle) }
    func appendBattery(_ record: BatteryRecord) { append(record, to: batteryHandle) }

    private static let newline = Data([0x0A])

    private func append<T: Encodable>(_ record: T, to handle: FileHandle?) {
        guard let handle, var data = try? encoder.encode(record) else { return }
        data.append(SessionStorage.newline) // 合并成一次 write()，减半 syscall 次数
        handle.write(data)
    }

    func writeMeta(_ meta: SessionMeta) {
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: metaURL)
    }

    func close() {
        fsyncTimer?.invalidate()
        syncToDisk() // 收尾：确保上一次定时 fsync 之后写入的数据也落盘
        leftHandle?.closeFile()
        rightHandle?.closeFile()
        gpsHandle?.closeFile()
        batteryHandle?.closeFile()
    }
}
