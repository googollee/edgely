import AttSensorKit
import SwiftUI

/// F-003：录制前配置（采样率固定 50Hz，不可选）
struct PreRecordingView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 24) {
            Text("准备录制").font(.title2).bold()

            Text("采样率 \(OutputRate.hz50.label)").foregroundStyle(.secondary)

            Spacer()

            Button("开始录制") {
                coordinator.startRecording()
            }
            .buttonStyle(BigButtonStyle(color: .green))
        }
        .padding()
    }
}

/// F-003/F-004：录制中界面，展示计时和左右脚连接/断线状态
struct ActiveRecordingView: View {
    @ObservedObject var session: RecordingSession
    let coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 24) {
            Text("录制中").font(.title2).bold()

            Text(formatted(session.elapsed))
                .font(.system(size: 48, weight: .bold, design: .monospaced))

            HStack(spacing: 40) {
                if session.hasLeft {
                    statusBadge(label: "左脚", connected: session.leftConnected, gaps: session.leftGapCount)
                }
                if session.hasRight {
                    statusBadge(label: "右脚", connected: session.rightConnected, gaps: session.rightGapCount)
                }
            }

            Spacer()

            Button("结束录制") {
                coordinator.stopRecording()
            }
            .buttonStyle(BigButtonStyle(color: .red))
        }
        .padding()
    }

    private func statusBadge(label: String, connected: Bool, gaps: Int) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.red)
                .frame(width: 16, height: 16)
            Text(label)
            if gaps > 0 {
                Text("断线 \(gaps) 次").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func formatted(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
