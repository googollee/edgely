import AttSensorKit
import Combine
import SwiftUI

enum AppPhase {
    case connect
    case calibrate
    case ready
    case recording
    case history
    case review(sessionId: String, directory: URL)
}

/// 串联 F1 -> F2 -> F3/F4/F6 -> F7 -> F5 的流程协调者。
/// 见 system-design.md「模块结构」：录制结束直接回 .connect；.review 唯一入口/出口是 .history。
final class AppCoordinator: ObservableObject {
    @Published var phase: AppPhase = .connect

    let sensorManager = DeviceManager(registry: DeviceRegistration.makeRegistry())
    /// 电池条的数据来源，见 `BatteryBar`
    let batteryMonitor = BatteryMonitor()
    /// 用户在 F1 勾选的传感器，校准、录制阶段监控它们的电量
    private var selectedSensors: [DeviceAdapter] = []
    private var cancellables: Set<AnyCancellable> = []
    /// 持有到进程结束：系统弹窗期间申请者不能被释放
    private let locationPermission = LocationPermission()
    private(set) var calibration: CalibrationEngine?
    private(set) var recording: RecordingSession?

    init() {
        // 蓝牙权限由 DeviceManager 创建时触发；定位权限在这里一并申请（PRD 非功能需求：启动时按需申请）
        locationPermission.requestIfNeeded()

        $phase.sink { [weak self] phase in self?.updateBatteryWatch(for: phase) }.store(in: &cancellables)
        // 连接页：新发现的传感器也要纳入监控（连接成功后才会有电量）
        // 适配器在连接确认后才创建，所以订阅设备列表之外还要订阅每个设备的适配器出现
        sensorManager.$discovered.sink { [weak self] discovered in
            guard let self else { return }
            self.deviceCancellables = discovered.map { device in
                device.$adapter.dropFirst().sink { [weak self] _ in self?.refreshConnectPageBatteryWatch() }
            }
            self.refreshConnectPageBatteryWatch()
        }.store(in: &cancellables)
    }

    /// 各阶段监控哪些传感器：连接页是所有已发现的（断线就隐藏）；校准、准备录制、录制中是用户选的那几个
    /// （断线后电池条里仍保留槽位，显示"已断线"）；历史、回放页不监控。
    private func updateBatteryWatch(for phase: AppPhase) {
        switch phase {
        case .connect:
            batteryMonitor.watch(batteryItems(for: sensorManager.discovered.compactMap(\.adapter), keepWhenDisconnected: false))
        case .calibrate, .ready, .recording:
            batteryMonitor.watch(batteryItems(for: selectedSensors, keepWhenDisconnected: true))
        case .history, .review:
            batteryMonitor.watch([])
        }
    }

    private var deviceCancellables: [AnyCancellable] = []

    private func refreshConnectPageBatteryWatch() {
        guard case .connect = phase else { return }
        batteryMonitor.watch(batteryItems(for: sensorManager.discovered.compactMap(\.adapter), keepWhenDisconnected: false))
    }

    /// 只有具备电量能力（`BatteryReporting`）的设备才进监控
    private func batteryItems(for sensors: [DeviceAdapter], keepWhenDisconnected: Bool) -> [BatteryMonitor.Item] {
        sensors.compactMap { sensor in
            guard let sensor = sensor as? BatteryReporting else { return nil }
            let side: BatteryMonitor.Side?
            if calibration?.resolvedLeft === sensor { side = .left }
            else if calibration?.resolvedRight === sensor { side = .right }
            else { side = nil }
            return BatteryMonitor.Item(adapter: sensor, side: side, keepWhenDisconnected: keepWhenDisconnected)
        }
    }

    /// - Parameter sensors: 用户在 F1 勾选的 1 个或 2 个已连接传感器
    func sensorsConnectedReadyForCalibration(_ sensors: [DeviceAdapter]) {
        selectedSensors = sensors
        // 进入校准阶段前，先把每个已连接传感器的回传速率设为 50Hz，再开始方向校准流程。
        // 不发送硬件加计校准（见 ADR-0012 §1）
        sensors.forEach {
            // 校准阶段的回传速率必须显式设定：录制阶段的速率由 RecordingSession 在开始录制时才设置，
            // 校准发生在那之前，不设的话用的是传感器寄存器里保存的历史值（可能是 10Hz）。
            // ADR-0012 的数值积分和端点取样都依赖足够的采样密度，10Hz 下一次迈步只有十几个点，不够用。
            // 设置速率同时会重开采样流：传感器在两趟录制之间保持连接不重连，帧序号和时间轴估计要从这次校准重新算起
            // （设备适配层不保存历史，校准流程自己订阅、自己累积，见 ADR-0011）。
            // 不能设置速率的设备（没有 `OutputRateConfigurable`）也要单独重开流
            if let configurable = $0 as? OutputRateConfigurable {
                configurable.setOutputRate(.hz50)
            } else {
                $0.resetStream()
            }
        }
        // 校准过程数据落盘（含失败尝试），见 ADR-0012；calibration 结束后其 id 会随 session 写进 meta.json
        calibration = CalibrationEngine(sensors: sensors, recorder: CalibrationRecorder())
        phase = .calibrate
    }

    func calibrationFinished() {
        calibration?.close()
        phase = .ready
    }

    func startRecording() {
        guard let cal = calibration, cal.resolvedLeft != nil || cal.resolvedRight != nil else { return }
        let session = RecordingSession(
            left: cal.resolvedLeft, right: cal.resolvedRight,
            outputRate: .hz50, leftFrame: cal.leftFrame, rightFrame: cal.rightFrame, calibrationId: cal.calibrationId
        )
        recording = session
        session.start()
        phase = .recording
    }

    func stopRecording() {
        guard let session = recording else { return }
        session.stop()
        returnToStart()
    }

    /// 返回开始界面，供用户开始下一趟录制。已连接的传感器保持连接，不需要重新走蓝牙连接流程。
    func returnToStart() {
        calibration = nil
        recording = nil
        phase = .connect
    }

    /// F7：进入历史记录列表
    func showHistory() {
        phase = .history
    }

    /// F7：从历史记录列表选中某个 session，进入回放页
    func openSession(sessionId: String, directory: URL) {
        phase = .review(sessionId: sessionId, directory: directory)
    }

    /// 从回放页返回历史记录列表（回放页唯一的出口，不回到起始界面）
    func returnToHistory() {
        phase = .history
    }
}

struct RootView: View {
    @StateObject var coordinator = AppCoordinator()

    /// 只在准备录制、录制中显示电池条：连接页把电量放在设备行里，校准过程不显示，回放、历史记录页不涉及传感器（ADR-0015）
    private var showsBatteryBar: Bool {
        switch coordinator.phase {
        case .ready, .recording: return true
        case .connect, .calibrate, .history, .review: return false
        }
    }

    var body: some View {
        Group {
            switch coordinator.phase {
            case .connect:
                ConnectView(coordinator: coordinator)
            case .calibrate:
                if let cal = coordinator.calibration {
                    CalibrationView(engine: cal, coordinator: coordinator)
                }
            case .ready:
                PreRecordingView(coordinator: coordinator)
            case .recording:
                if let session = coordinator.recording {
                    ActiveRecordingView(session: session, coordinator: coordinator)
                }
            case .history:
                HistoryView(coordinator: coordinator)
            case .review(let sessionId, let directory):
                ReviewView(sessionId: sessionId, directory: directory, coordinator: coordinator)
            }
        }
        // 电池条在根视图顶部，准备录制、录制中共用同一个位置；没有被监控的传感器时不占空间
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsBatteryBar { BatteryBar(monitor: coordinator.batteryMonitor) }
        }
    }
}
