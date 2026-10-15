import AttSensorKit
import SwiftUI

/// F-001：连接传感器，用户勾选要使用的 1 个或 2 个
struct ConnectView: View {
    let coordinator: AppCoordinator
    @ObservedObject var manager: DeviceManager
    @State private var selectedIDs: Set<UUID> = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.manager = coordinator.sensorManager
    }

    private var readyDevices: [DiscoveredDevice] {
        manager.discovered.filter { $0.isReady }
    }

    private var selectedDevices: [DiscoveredDevice] {
        readyDevices.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("连接鞋传感器").font(.title2).bold()
            Text(manager.bluetoothReady ? "蓝牙已就绪" : "等待蓝牙开启…")
                .foregroundStyle(.secondary)
            if !manager.hasDeviceSupport {
                // 没有任何已注册的设备支持：不扫描（ADR-0016）
                Text("没有可用的设备支持").foregroundStyle(.secondary)
            }

            Button(manager.isScanning ? "扫描中…" : "开始扫描") {
                manager.startScan()
            }
            .buttonStyle(BigButtonStyle(color: .accentColor))
            .disabled(!manager.bluetoothReady || manager.isScanning || !manager.hasDeviceSupport)

            #if DEBUG
            Button("添加模拟设备") { manager.addSimulatedDevice() }
                .foregroundStyle(.secondary)
            #endif

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(manager.discovered) { device in
                        SensorRow(
                            device: device,
                            manager: manager,
                            isSelected: selectedIDs.contains(device.id),
                            onToggle: { toggleSelection(device) }
                        )
                    }
                }
            }

            Text("最多选择 2 个传感器")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !selectedDevices.isEmpty {
                Button("使用选中的 \(selectedDevices.count) 个传感器，开始校准") {
                    coordinator.sensorsConnectedReadyForCalibration(selectedDevices.compactMap(\.adapter))
                }
                .buttonStyle(BigButtonStyle(color: .green))
            }

            Button("历史记录") {
                coordinator.showHistory()
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func toggleSelection(_ device: DiscoveredDevice) {
        if selectedIDs.contains(device.id) {
            selectedIDs.remove(device.id)
        } else if selectedIDs.count < 2 {
            selectedIDs.insert(device.id)
        }
    }
}

/// 单独订阅自己对应的 DiscoveredDevice，保证 isReady 变化时这一行会重新渲染
/// （ConnectView 本身只订阅了 DeviceManager，不会感知到某个设备内部的变化）
private struct SensorRow: View {
    @ObservedObject var device: DiscoveredDevice
    let manager: DeviceManager
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            // 电量在设备行最左侧（ADR-0015）；断线时不显示
            if device.isReady, device.adapter is BatteryReporting {
                BatteryPercentText(percent: device.batteryPercent)
            }
            VStack(alignment: .leading) {
                Text(device.name ?? device.id.uuidString)
                if let failure = device.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if device.isReady {
                Button(isSelected ? "已选中" : "选择") {
                    onToggle()
                }
                .foregroundStyle(isSelected ? Color.green : Color.accentColor)
            } else {
                Button("连接") { manager.connect(device) }
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 手套操作要求按钮足够大，见 PRD F-009
struct BigButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.bold())
            .padding()
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
