---
type: reference
review: ../review.md#reference
---

# AttSensorKit 接口参考

## 总览

AttSensorKit（`AttSensorKit/`）是一个本地 Swift Package，定义设备适配层的接口契约：app 和任何设备实现都只依赖这些接口。本文只描述契约，不涉及任何具体设备的协议或实现。

- 设备适配器协议 `DeviceAdapter`，以及它输出的整理后的采样 `DeviceSample`；
- 设备不一定具备的能力协议：`BatteryReporting`、`MagneticFieldProviding`、`EulerAngleProviding`、`OutputRateConfigurable`；
- 设备适配器工厂 `DeviceAdapterFactory` 和注册表 `DeviceAdapterRegistry`；
- 通用的设备管理器 `DeviceManager` 和扫描列表里的 `DiscoveredDevice`；
- 回传速率 `OutputRate`；
- 仅用于测试和 DEBUG 构建的 `MockAdapter`。

## DeviceAdapter

一个姿态传感器在使用方眼里的全部样子。适配器只重整、不切片、不保存历史：窗口怎么切、历史留多久是使用方的事。

| 成员 | 含义 |
| --- | --- |
| `id` | 稳定的设备身份，校准结果按它对应回具体设备 |
| `isReady` / `isReadyPublisher` | 连接是否就绪（订阅好数据通知）。断线后为 false，自动重连成功后重新为 true。发布发生在值改变之前，订阅者要用回调给出的值 |
| `lastRealtimeAt` | 最近一次收到实时数据的时间。电量等其他响应不算 |
| `timeOrigin` | 时间零点，见「时间语义」 |
| `onSample` | 每整理出一个样本回调一次，按采样顺序、`t` 单调递增。同一时刻只有一个订阅者，后设置的覆盖先前的 |
| `resetStream()` | 开始一条新的流：帧序号从 0 重新计数，时间轴估计回到冷启动 |
| `start()` | 设备管理器在外设连接成功（含断线后自动重连成功）后调用：适配器接手外设。可能被调用多次 |
| `connectionDidDrop()` | 设备管理器在外设意外断开时调用：适配器把 `isReady` 置为 false |

## DeviceSample

| 属性 | 含义 |
| --- | --- |
| `index` | 在当前这条流里的帧序号，从 0 起，`resetStream()` 后重新计数 |
| `t` | 重建后的时间（秒）：严格单调，是估计值，不是到达时间 |
| `accel` | 加速度，g |
| `gyro` | 角速度，deg/s |
| `arrival` | 该样本所在数据包到达手机的时刻。同一个数据包里的样本共用同一个值。唯一实测的时间，无论 `t` 如何重建都保留 |

物理量由适配器统一成上面的单位。

## 时间语义

- `t` 的基准由 `timeOrigin` 决定：
  - 不设（nil）：每条流的第一个样本 `t` = 0，之后按重建的间隔递增。
  - 设了：流的第一个样本 `t` = 它的到达时间 − `timeOrigin`，之后按重建的间隔递增，使 `t` 与调用方的其他数据流在同一基准上。
- 流每次重开（`resetStream()`、断线重连）都用重开后第一个样本重新锚定，断线的缺口因此保留在时间轴上。
- 多个传感器共用同一个 `timeOrigin` 时，各自重建时间，起点对着同一个手机时钟时刻，对齐精度受到达时间的粒度限制。
- `arrival` 永远是绝对时间（`Date`），`timeOrigin` 不影响它。

## 能力协议

使用方用 `as?` 判断设备是否具备某项能力，不具备就跳过，不要求每个设备都实现。

| 协议 | 成员 | 用途 |
| --- | --- | --- |
| `BatteryReporting` | `batteryPercent`、`batteryPercentPublisher`、`requestBattery()` | 电量百分比，还没读到时为 nil。`requestBattery()` 请求读一次，响应到达后更新 |
| `MagneticFieldProviding` | `onMagneticField`、`requestMagneticField()` | 磁场读数（µT）和到达时间 |
| `EulerAngleProviding` | `onSampleWithAngle` | 每个实时样本回调一次：样本和同一帧设备自带的欧拉角（deg）。与 `onSample` 同时触发，各自独立订阅 |
| `OutputRateConfigurable` | `setOutputRate(_:)` | 设置回传速率，同时按新速率重开采样流 |

## DeviceAdapterFactory 与注册表

一类设备对应一个工厂：

| 成员 | 含义 |
| --- | --- |
| `serviceUUIDs` | 这类设备广播的服务 UUID：用于扫描过滤、认领设备和连接后的确认。设备必须把其中至少一个放进广播包，否则扫描时会被过滤掉 |
| `confirm(discoveredServices:)` | 连接后确认。默认实现是"实际发现的服务里包含任一 `serviceUUIDs`"，需要更严检查的工厂可以覆盖 |
| `makeAdapter(for:)` | 为已认领、已确认的外设创建适配器 |

`DeviceAdapterRegistry` 保存已注册的工厂：

| 成员 | 含义 |
| --- | --- |
| `register(_:)` | 注册一个工厂 |
| `serviceUUIDs` | 所有工厂的服务 UUID，去重、保持注册顺序。为空表示没有可用的设备支持，此时不应启动扫描 |
| `factory(forAdvertisedServices:)` | 用广播里的服务 UUID 认领设备。多个工厂同时命中时注册在前的优先 |

## DeviceManager 与 DiscoveredDevice

`DeviceManager` 是通用的连接管理，不认识任何具体协议：

- 状态：`discovered`（已认领的设备列表）、`isScanning`、`bluetoothReady`、`hasDeviceSupport`（注册表非空时为 true）。
- 扫描：按注册表汇总的服务 UUID 过滤。注册表为空时 `startScan()` 不启动扫描。每次 `startScan()` 都重新开始：清空已发现列表和此前的连接意愿，重新扫描不属于意外断线，不受自动重连约束。
- 认领：发现设备时用广播里的服务 UUID 与各工厂比对，命中的设备才出现在 `discovered` 列表里。
- 连接后确认：发现服务并交给归属工厂 `confirm`；通过才创建适配器并调用 `start()`，不通过就断开，该设备的 `failure` 为"不是支持的设备"。
- 断线自动重连：用户要求连接过的外设意外断开后自动重新连接；重连成功后再次调用适配器的 `start()`。

`DiscoveredDevice` 是列表里的一项，供界面订阅：

| 成员 | 含义 |
| --- | --- |
| `id` | 外设标识（CoreBluetooth 在这台手机上给的 UUID） |
| `name` | 设备名 |
| `adapter` | 确认后才有 |
| `isReady` | 连接是否就绪 |
| `batteryPercent` | 设备不具备电量能力时一直是 nil |
| `failure` | 连接或确认失败的提示 |

## OutputRate

| 成员 | 含义 |
| --- | --- |
| `label` | 显示名（"50Hz"） |
| `nominalPeriod` | 名义采样周期（0.02 秒） |
| `framesPerNotify` | 一次 BLE 通知带多少帧 |

## MockAdapter（仅测试和 DEBUG 构建）

测试里直接设置属性、调用 `emit(_:)` 推送样本。DEBUG 构建里，`DeviceManager.addSimulatedDevice()` 往列表里加一个模拟设备，连接后按 50Hz 推送静止的数据并回报电量。Release 构建不包含 `MockAdapter`。

## 契约约束

实现方必须遵守，使用方可以依赖：

1. `onSample` 按采样顺序回调，`t` 严格单调。
2. `index` 从 0 起，`resetStream()` 和断线重连后重新计数。
3. 断线造成的缺口保留在时间轴上，不被抹平。
4. `arrival` 如实保留，不受 `t` 重建方式影响。
5. 物理量使用统一单位：加速度 g，角速度 deg/s，磁场 µT，欧拉角 deg。
6. 适配器不保存样本历史，没有订阅者时样本直接丢弃。
7. `lastRealtimeAt` 只在收到实时数据时刷新。
8. 重连后适配器把采样流恢复到干净的起点：丢掉断线前没收完的数据，重开采样流。
9. 如何估计丢帧、`t` 的精度如何，是各适配器内部的事，契约不规定。

## 已知限制

- 设备必须把服务 UUID 放进广播包，不广播服务 UUID 的设备无法接入。
- 多个传感器之间的时间对齐精度受到达时间的粒度限制。
