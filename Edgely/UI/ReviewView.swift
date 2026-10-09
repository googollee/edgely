import SwiftUI
import simd

/// F5：从历史记录列表（F7）选中某个 session 后展示可拖动时间轴 + 姿态回放，以及数据质量概览。
/// 姿态计算方式（鞋形几何体 + 校准对齐 + 加速度计倾斜锚定）见 ADR-0005。
struct ReviewView: View {
    let sessionId: String
    let directory: URL
    let coordinator: AppCoordinator

    @State private var hasLeft = false
    @State private var hasRight = false
    @State private var leftFrame: SensorOrientationFrame?
    @State private var rightFrame: SensorOrientationFrame?
    @State private var leftSamples: [(t: Double, accel: SIMD3<Float>)] = []
    @State private var rightSamples: [(t: Double, accel: SIMD3<Float>)] = []
    @State private var leftGaps: [DataGap] = []
    @State private var rightGaps: [DataGap] = []
    @State private var duration: Double = 0.01
    @State private var scrubTime: Double = 0
    @State private var summary: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("回放：\(sessionId)").font(.headline)

            Pose3DView(
                leftOrientation: orientation(at: scrubTime, samples: leftSamples, frame: leftFrame, gaps: leftGaps),
                rightOrientation: orientation(at: scrubTime, samples: rightSamples, frame: rightFrame, gaps: rightGaps)
            )
            .frame(height: 280)

            Slider(value: $scrubTime, in: 0...duration)
            GapTimelineBar(duration: duration, rows: gapRows)
            Text(String(format: "%.1f s / %.1f s", scrubTime, duration))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !missingSensorNames.isEmpty {
                Text("此时间段数据缺失：" + missingSensorNames.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                Text(summary)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("← 返回历史记录") {
                coordinator.returnToHistory()
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: load)
    }

    /// 有缺口的传感器（只列有缺口的），供时间轴下方的缺口条使用
    private var gapRows: [(label: String, gaps: [DataGap])] {
        var rows: [(label: String, gaps: [DataGap])] = []
        if !leftGaps.isEmpty { rows.append(("左脚", leftGaps)) }
        if !rightGaps.isEmpty { rows.append(("右脚", rightGaps)) }
        return rows
    }

    /// 当前时间点落在缺口里的传感器（F4：复盘时要看得出这段数据缺失）
    private var missingSensorNames: [String] {
        var names: [String] = []
        if leftGaps.contains(where: { $0.contains(scrubTime) }) { names.append("左脚") }
        if rightGaps.contains(where: { $0.contains(scrubTime) }) { names.append("右脚") }
        return names
    }

    /// 见 ADR-0005：先按最近邻取该时刻的原始加速度计读数，再算"校准对齐 + 实时倾斜"的最终旋转。
    /// 没有校准参考系（旧版本录制的数据可能没有）时返回 nil，不渲染。
    /// 落在数据缺口里时也返回 nil：不用缺口前的旧读数填充（PRD F4），模型隐藏，配合下方"数据缺失"提示。
    private func orientation(at t: Double, samples: [(t: Double, accel: SIMD3<Float>)], frame: SensorOrientationFrame?, gaps: [DataGap]) -> simd_quatf? {
        guard let frame, !samples.isEmpty, !gaps.contains(where: { $0.contains(t) }) else { return nil }
        var lo = 0
        var hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return PoseAlignment.renderOrientation(frame: frame, currentAccel: samples[lo].accel)
    }

    private func load() {
        hasLeft = FileManager.default.fileExists(atPath: directory.appendingPathComponent("left.jsonl").path)
        hasRight = FileManager.default.fileExists(atPath: directory.appendingPathComponent("right.jsonl").path)

        let meta = loadMeta()
        leftFrame = meta?.leftCalibration?.frame
        rightFrame = meta?.rightCalibration?.frame
        // 录制在断线期间结束时，最后一段缺口没有 gap_end，补到录制结束
        let sessionLength = meta?.endedAt.map { $0.timeIntervalSince(meta?.startedAt ?? $0) }

        var lines: [String] = []
        var maxT: Double = 0

        if hasLeft {
            let loaded = SessionFileLoader.loadSamples(url: directory.appendingPathComponent("left.jsonl"), sessionLength: sessionLength)
            leftSamples = loaded.samples
            leftGaps = loaded.gaps
            maxT = max(maxT, loaded.samples.last?.t ?? 0, loaded.gaps.last?.end ?? 0)
            lines.append("左脚采样点数：\(loaded.samples.count)，断线次数：\(loaded.gaps.count)" + (leftFrame == nil ? "（无校准参考系，不渲染姿态）" : ""))
            lines.append(contentsOf: gapLines(loaded.gaps))
        }
        if hasRight {
            let loaded = SessionFileLoader.loadSamples(url: directory.appendingPathComponent("right.jsonl"), sessionLength: sessionLength)
            rightSamples = loaded.samples
            rightGaps = loaded.gaps
            maxT = max(maxT, loaded.samples.last?.t ?? 0, loaded.gaps.last?.end ?? 0)
            lines.append("右脚采样点数：\(loaded.samples.count)，断线次数：\(loaded.gaps.count)" + (rightFrame == nil ? "（无校准参考系，不渲染姿态）" : ""))
            lines.append(contentsOf: gapLines(loaded.gaps))
        }
        duration = max(maxT, 0.01)
        lines.append("时长：\(String(format: "%.1f", duration)) 秒")

        let battery = SessionFileLoader.loadBattery(url: directory.appendingPathComponent("battery.jsonl"))
        if let first = battery.first, let last = battery.last {
            var parts: [String] = []
            if hasLeft { parts.append("左 \(percentText(first.leftPercent))→\(percentText(last.leftPercent))") }
            if hasRight { parts.append("右 \(percentText(first.rightPercent))→\(percentText(last.rightPercent))") }
            parts.append("手机 \(percentText(first.phonePercent))→\(percentText(last.phonePercent))")
            lines.append("电量（开始→结束）：" + parts.joined(separator: "，"))
        }
        summary = lines.joined(separator: "\n")
    }

    private func loadMeta() -> SessionMeta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMeta.self, from: data)
    }

    private func gapLines(_ gaps: [DataGap]) -> [String] {
        gaps.map { String(format: "　数据缺失 %.1f–%.1f 秒（%.1f 秒）", $0.start, $0.end, $0.end - $0.start) }
    }

    private func percentText(_ v: Int?) -> String {
        v.map { "\($0)%" } ?? "-"
    }
}

/// 一段数据缺失的时间区间（相对录制开始的秒数）。
/// 起点取"缺口前最后一个采样点"的时刻：`gap_start` 记录的是连续 2 秒没收到数据时才判定的时刻（PRD F4），
/// 真正缺数据的时间从最后一个采样之后就开始了。终点是重新收到数据（`gap_end`）的时刻。
struct DataGap: Equatable {
    let start: Double
    let end: Double

    /// 严格落在缺口内部（端点上各有一个真实采样点）
    func contains(_ t: Double) -> Bool { t > start && t < end }
}

/// 回放页下方的缺口条：和时间轴同宽，橙色段是该传感器数据缺失的时间。
private struct GapTimelineBar: View {
    let duration: Double
    let rows: [(label: String, gaps: [DataGap])]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                Text("\(rows[row].label)数据缺失（橙色）").font(.caption2).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                        ForEach(rows[row].gaps.indices, id: \.self) { i in
                            let gap = rows[row].gaps[i]
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: max(2, geo.size.width * (gap.end - gap.start) / duration))
                                .offset(x: geo.size.width * gap.start / duration)
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }
        }
    }
}

enum SessionFileLoader {
    static func loadSamples(url: URL, sessionLength: Double? = nil) -> (samples: [(t: Double, accel: SIMD3<Float>)], gaps: [DataGap]) {
        guard let data = try? Data(contentsOf: url) else { return ([], []) }
        return parseSamples(data, sessionLength: sessionLength)
    }

    /// 解析 `left.jsonl`/`right.jsonl`：取出采样点，并把 `gap_start`/`gap_end` 配成缺口区间。
    /// 录制在断线期间结束时最后一个缺口没有 `gap_end`，终点取 `sessionLength`（没有时取文件里最后一条记录的时刻）。
    static func parseSamples(_ data: Data, sessionLength: Double? = nil) -> (samples: [(t: Double, accel: SIMD3<Float>)], gaps: [DataGap]) {
        var samples: [(t: Double, accel: SIMD3<Float>)] = []
        var gaps: [DataGap] = []
        var openGapStart: Double?
        var lastRecordT = 0.0
        let decoder = JSONDecoder()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(SensorSampleRecord.self, from: lineData) else { continue }
            lastRecordT = max(lastRecordT, record.t)
            switch record.type {
            case "sample":
                if let x = record.accelX, let y = record.accelY, let z = record.accelZ {
                    samples.append((record.t, SIMD3<Float>(x, y, z)))
                }
            case "gap_start":
                openGapStart = samples.last?.t ?? record.t
            case "gap_end":
                if let start = openGapStart {
                    gaps.append(DataGap(start: start, end: record.t))
                    openGapStart = nil
                }
            default:
                break
            }
        }
        if let start = openGapStart {
            let end = max(sessionLength ?? lastRecordT, start)
            gaps.append(DataGap(start: start, end: end))
        }
        return (samples, gaps)
    }

    static func loadBattery(url: URL) -> [BatteryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> BatteryRecord? in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(BatteryRecord.self, from: lineData)
        }
    }
}
