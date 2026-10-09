import AttSensorKit
#if EDGELY_DEVICES
import EdgelyDevices
#endif

/// 设备实现的注册点（ADR-0016）。设备实现包 `EdgelyDevices` 存在时才参与编译（由 `scripts/gen_proj.sh` 决定是否带入，并设置 `EDGELY_DEVICES` 编译条件），
/// 缺少它 app 仍可编译，只是注册表为空、扫描不启动。
enum DeviceRegistration {
    static func makeRegistry() -> DeviceAdapterRegistry {
        let registry = DeviceAdapterRegistry()
        #if EDGELY_DEVICES
        EdgelyDevices.registerAll(into: registry)
        #endif
        return registry
    }
}
