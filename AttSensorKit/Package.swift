// swift-tools-version:5.9
import PackageDescription

// 设备适配层的接口契约（ADR-0011、ADR-0016）：app 和各设备实现包都只依赖它。
// "Att" 取 attitude（姿态）之意。
let package = Package(
    name: "AttSensorKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AttSensorKit", targets: ["AttSensorKit"]),
    ],
    targets: [
        .target(name: "AttSensorKit"),
        .testTarget(name: "AttSensorKitTests", dependencies: ["AttSensorKit"]),
    ]
)
