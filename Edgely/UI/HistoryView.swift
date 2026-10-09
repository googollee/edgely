import SwiftUI

/// F7：历史记录列表——唯一显示 session id，选中后进入 F5 回放页。
/// 不是"手套操作"场景（见 PRD 非功能需求），用常规紧凑样式，不用大按钮。
struct HistoryView: View {
    let coordinator: AppCoordinator
    @State private var sessionIDs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("← 返回") { coordinator.returnToStart() }
                Spacer()
            }
            .padding()

            Text("历史记录").font(.title2).bold()
                .padding(.bottom, 8)

            if sessionIDs.isEmpty {
                Spacer()
                Text("还没有录制记录").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(sessionIDs, id: \.self) { sessionId in
                    Button {
                        coordinator.openSession(sessionId: sessionId, directory: HistoryView.sessionDirectory(for: sessionId))
                    } label: {
                        Text(sessionId)
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let dir = HistoryView.sessionsRootDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        sessionIDs = names.sorted(by: >)
    }

    static func sessionsRootDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions")
    }

    static func sessionDirectory(for sessionId: String) -> URL {
        sessionsRootDirectory().appendingPathComponent(sessionId)
    }
}
