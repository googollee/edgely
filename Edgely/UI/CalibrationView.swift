import Combine
import SwiftUI

/// F-002：功能性方向校准——双传感器、单传感器走同一套四步流程，不需要用户手动选左右脚（见 ADR-0012）。
/// 每一步有单步时限（每一步相同，见 ADR-0012「窗口与时限」），本视图用一个本地计时器驱动倒计时显示。
struct CalibrationView: View {
    @ObservedObject var engine: CalibrationEngine
    let coordinator: AppCoordinator

    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var secondsRemaining: Int {
        let elapsed = now.timeIntervalSince(engine.windowStartedAt)
        return max(0, Int((engine.currentStepTimeLimit - elapsed).rounded(.up)))
    }

    var body: some View {
        VStack(spacing: 32) {
            Text("功能性方向校准").font(.title2).bold()

            Text(engine.instruction)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding()

            if !engine.isDone {
                Text("\(secondsRemaining) 秒")
                    .font(.title)
                    .monospacedDigit()
                    .foregroundStyle(secondsRemaining <= 1 ? .red : .secondary)
            }

            if let retryNote = engine.retryNote {
                Text(retryNote)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if let note = engine.lastNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if engine.isDone {
                Button("完成，进入录制") {
                    coordinator.calibrationFinished()
                }
                .buttonStyle(BigButtonStyle(color: .green))
            } else {
                Button(engine.buttonTitle) {
                    engine.confirmCurrentStep()
                }
                .buttonStyle(BigButtonStyle(color: .accentColor))
            }
        }
        .padding()
        .onReceive(ticker) { now = $0 }
    }
}
