# Edgely

Edgely 是一个 iOS App，用 1~2 个姿态传感器（IMU）采集各类运动中的脚部姿态数据，并在事后回放查看。目标是用现成的传感器搭一套低成本、可扩展的采集与分析方案。

当前处于 MVP 阶段：先把数据稳定、完整地采到，暂不做动作分段、姿态角度等分析算法。

## 功能

- **连接**：扫描并连接 1 个或 2 个姿态传感器。
- **校准**：用几步简单动作自动识别每个传感器对应左脚还是右脚，并确定传感器相对于靴子的朝向。
- **录制**：以 50Hz 持续录制，同步记录 GPS 轨迹和电量；断线会被检测并标记，不会无声丢数据。
- **历史记录**：列出本机保存的所有录制，随时进入回放；数据可通过"文件"App 或 Finder 导出。
- **回放**：回看任意时刻每只脚的姿态，以及相对一段时间内平均位置的位移，时间长度可选；数据缺失的时间段会明确标出。

全部功能不依赖网络。

## 项目结构

- `Edgely/`：App 本体（连接、校准、录制、历史、回放）。
- `AttSensorKit/`：本地 Swift Package，定义设备适配层的接口，App 只依赖它，不认识具体设备。
- `EdgelyDevices/`：具体设备的适配器（可选），不存在时 App 仍可编译，只是没有设备可连。
- `docs/`：PRD、设计、ADR 和参考文档，规则见 [docs/README.md](docs/README.md)。

## 构建

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，最低支持 iOS 17.0。

```sh
make proj      # 生成 Edgely.xcodeproj
make test      # 生成工程并运行单元测试
make build     # 生成工程并构建 App
make release   # 归档并上传到 App Store Connect（需要 appstoreconnect/config.mk 中的凭证）
make clean     # 清理构建产物与生成的工程文件
```

## 文档

- [PRD](docs/prd.md)：做什么、为谁做、不做什么
- [设计](docs/design.md)：当前系统的中高层设计
- [ADR](docs/adr/)：各项技术决策
- [参考](docs/reference/)：接口与落盘数据格式
