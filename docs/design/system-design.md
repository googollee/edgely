# 系统设计：Edgely MVP

| 字段 | 内容 |
| --- | --- |
| 状态 | 活文档，随代码更新 |
| 最后更新 | 2026-10-08 |
| 说明 | 本文档描述系统**当前实际**的运作方式。记录"为什么这样设计"的因果关系在 ADR 或对应的参考文档（如硬件协议参考文档）里，本文档只记录"现在是怎样"，不重复展开决策过程——涉及具体决策依据时以链接指向对应文档，不在本文档内复述。 |

## 模块结构

代码分三部分：

- **AttSensorKit/**（本地 Swift Package，见 ADR-0016）：设备适配层的接口契约——`DeviceAdapter` 协议、整理后的采样 `DeviceSample`、能力协议、设备适配器工厂和注册表、通用的设备管理器 `DeviceManager`、仅测试和 DEBUG 用的 `MockAdapter`。接口细节见 `docs/reference/att-sensor-kit-protocol.md`。app 只依赖这个包，不认识任何具体设备。
- **设备实现包（可选）**：放在项目根目录的 `EdgelyDevices/` 下，被版本管理忽略。`scripts/gen_proj.sh`（`make proj`）检测到该目录存在，就把它加入编译并设置编译条件 `EDGELY_DEVICES`；不存在则忽略，app 仍可编译，只是注册表为空（见「设备注册与连接」）。
- **Edgely/**（app 本体），按职责划分：
  - **Calibration/**：F2 校准，逻辑见 ADR-0012。
    - `CalibrationEngine.swift`：步骤状态机、单步超时、失败重置、UI 状态（指令文案、身份判定提示）。只依赖 `DeviceAdapter` 协议，可以脱离蓝牙单测（测试用 `MockAdapter`）。
    - `CalibrationStreamBuffer.swift`：累积整个校准会话的样本，按点击时刻切窗口，从站立锚点连续积分出迈步窗口的起点姿态（ADR-0012 §5 步骤 2）。
    - `CalibrationMath.swift`：纯计算，对应 ADR-0012 §3–§5（抬脚峰值速度 `motionPeakSpeed`、站立基准 `standingDown`、活动段 `activeSegment`、前轴 `segmentedFrame`、身份比较 `compare`），判定参数也定义在这里。
    - `CalibrationRecorder.swift`：校准数据落盘（ADR-0012 §7，格式见「持久化策略」）。
  - **Recording/**：`RecordingSession.swift`（F3/F4/F6 录制主流程，见「录制阶段」）、`LocationLogger.swift`（GPS 记录；同文件里的 `LocationPermission` 在 App 启动时申请定位权限）。
  - **App/**：`EdgelyApp.swift`、`RootView.swift`（`AppCoordinator` 阶段协调与根视图）、`DeviceRegistration.swift`（设备实现的注册点，见「设备注册与连接」），以及 `BatteryMonitor.swift`（电量百分比的颜色规则与电量监控，见「传感器电量显示」）。
  - **Storage/**：`SessionStorage.swift`，JSON Lines 落盘（见 ADR-0001）。
  - **Models/**：落盘用的 Codable 数据结构。
  - **UI/**：SwiftUI 视图，按 F1→F2→F3/F4→F7→F5 的流程串联，由 `App/RootView.swift` 里的 `AppCoordinator` 统一协调阶段切换。`AppPhase` 状态机：

    ```
    .connect --(选传感器)--> .calibrate --> .ready --> .recording --(结束录制)--> .connect
       |                                                                            ^
       +--(历史记录入口)--> .history --(选中某个 session)--> .review --(返回)--> .history
                               |
                               +--(返回)--> .connect
    ```

    录制结束（`AppCoordinator.stopRecording()`）后直接回到 `.connect`（不经过 `.review`），清空当前的 `calibration`/`recording` 状态，但已连接的传感器保持连接，不需要重新走一遍蓝牙连接流程。`.review`（F5 回放页）唯一的进入路径是从 `.history`（F7 历史记录列表）选中一个 session，退出后也回到 `.history`，不回到 `.connect`。

## 传感器电量显示

准备录制、录制中两个页面的顶部显示传感器电量（`UI/BatteryBar.swift`），连接页把电量放在设备行最左侧，校准、回放和历史记录页不显示。PRD 非功能需求「传感器电量显示」，决策见 ADR-0015。

- **电池条布局**：一行分成左右两半，左脚传感器在左半边、右脚传感器在右半边，各自靠自己那一半的左侧对齐，内容是"左脚 85%"；只有一个传感器时另一半留空。没判定出左右脚的传感器放到还空着的那一半（`BatteryBar.slots`）。不画电量条，只显示百分比。
- **挂载位置**：`RootView` 用 `safeAreaInset(edge: .top)` 把电池条挂在根视图上，只在 `.ready`、`.recording` 阶段显示；没有被监控的传感器时不占空间。连接页的百分比由 `SensorRow` 直接读设备适配器的 `batteryPercent`，已连接才显示。不拦截任何操作。
- **数据来源**：`AppCoordinator` 持有一个 `BatteryMonitor`，随 `phase` 切换监控对象：连接页监控所有已发现的传感器，校准、准备录制、录制中监控用户选的那几个，历史和回放页停止监控。传感器就绪（含重连）时立刻读一次电量，之后每 60 秒轮询。`Reading` 带左右脚信息（来自 `calibration.resolvedLeft/Right`）。`RecordingSession` 每分钟的电量快照照旧，两者互不影响。
- **颜色规则**（`BatteryLevelPolicy`）：目前接入的设备给出的电量是分档的，只有 100/90/75/60/50/40/30/20/15/10/5/0 这些档位，10% 一档对应的电压范围很宽，所以"低电量"按 ≤ 10%。只有百分比变色（红色），标签不变色。没有滞回：档位刚好在 10% 和 15% 之间跳时颜色会跟着变。还没读到电量时显示"--%"，不算低电量。
- **断线时**：不显示百分比，也不保留旧值。连接页该设备行不显示电量；准备录制、录制中槽位保留，显示"左脚 已断线"。重连后收到新读数前显示"--%"。传感器没电关机后想查最后的电量，看录制的 `battery.jsonl`（实际案例：一次录制里左脚 0% 电量，数据在 90 秒处中断）。
- 只针对传感器，不含手机电量，没有震动、声音等其他提醒。

## 设备注册与连接

app 不认识任何具体设备，设备由注册表接入（ADR-0016，接口见 `docs/reference/att-sensor-kit-protocol.md`）：

- **注册**：`App/DeviceRegistration.swift` 创建 `DeviceAdapterRegistry`。设备实现包存在时（编译条件 `EDGELY_DEVICES`）调用它的注册入口，把自己的工厂注册进来；不存在时注册表为空。`AppCoordinator` 用这个注册表创建 `DeviceManager`。
- **扫描**：`DeviceManager` 用注册表汇总的服务 UUID 过滤扫描；发现设备后用广播里的服务 UUID 认领，命中的设备才进入列表。注册表为空时不启动扫描，连接页提示"没有可用的设备支持"并禁用扫描按钮。DEBUG 构建里连接页有"添加模拟设备"按钮（`MockAdapter`）。
- **连接确认**：用户点"连接"后，管理器发现服务并交给归属工厂确认；通过才创建适配器并让它接手外设，不通过就断开，该行显示"不是支持的设备"。适配器出现之前，列表里的设备没有适配器，`ConnectView` 只能选择已就绪（`isReady`）的设备，选中后用它们的适配器进入校准。
- **能力判断**：电量、磁场、欧拉角、回传速率设置都是可选能力，消费者用 `as?` 判断。例如电池条只监控具备电量能力的设备，录制只对具备磁场能力的设备轮询磁场。

## 连接与重连

`DeviceManager` 记录用户要求连接的外设。这些外设意外断开后，管理器通知适配器连接中断（`connectionDidDrop()`），并立刻对它们重新发起连接；CoreBluetooth 的连接请求没有超时，设备回来就连上，不需要自己重试计时。蓝牙关闭后重新开启时，也会对仍未就绪的外设重新连接；连接失败的外设隔 1 秒再试。校准、录制期间的行为相同。

重连成功后管理器再次调用适配器的 `start()`，适配器重新接手外设；按契约，适配器在重连后要把采样流恢复到干净的起点（丢掉断线前没收完的数据，重开采样流，帧序号从 0 重新计数）。因此：

- 录制期间：断线时 `RecordingSession` 已经写入 `gap_start`；重连后收到数据，写入 `gap_end`，缺口结束。
- 校准期间：窗口内出现帧序号重新计数，说明采样流中断过，这一步按失败处理（ADR-0012 §6）。传感器在点击时仍处于断线状态的情形没有单独检测。

## 数据流

```
设备数据（经 DeviceManager 接手的外设，主线程回调）
  → 适配器（设备实现）：解析、统一单位、重建时间 → DeviceSample
  → onSample（设备适配层的标准输出，ADR-0011），两个出口：
     - 校准阶段：CalibrationEngine 订阅，CalibrationStreamBuffer 累积整个会话、按点击切窗口
     - 录制阶段（F3 录制中）：RecordingSession 订阅，逐条编码后写入 SessionStorage；`t` 取自采样流，落盘后不再修改。
       设备带欧拉角（`EulerAngleProviding`）时，订阅 `onSampleWithAngle`，样本和同一帧的欧拉角一起落盘。
```

两个阶段用的是同一路采样流，但用途和生命周期不同——录制阶段的数据是 session 的正式内容，逐条落盘、不能丢；校准阶段的数据由校准流程自己累积（设备适配层不保存历史），其中交给判定的窗口另行复制一份落盘留档，累积的样本本身是临时工作区。

### 时间戳来源

设备的实时数据通常不携带时间信息，所以 app 看到的 `DeviceSample` 带两种时间（含义见接口参考文档）：`arrival`（数据包到达手机的时刻，实测）和 `t`（适配器按协议和经验重建的时间，估计值）。两个阶段的用法不同：

- **采样流（两个阶段共用）**：`t` 严格单调，没有丢帧的地方间隔均匀，丢帧处由适配器估计补上；样本发出时 `t` 就定了，之后不再修改。同一个数据包里的样本共用同一个 `arrival`。
  - 适配器的 `timeOrigin`（可选）决定 `t` 的基准：不设时每条流的第一个样本 `t` 为 0（校准用）；设了则第一个样本的 `t` 是它的到达时间相对零点的秒数，之后按重建间隔递增。流每次重开（`resetStream()`、断线重连）都用重开后第一个样本重新锚定，断线的缺口保留。
  - 丢帧只能靠到达时间推断，`t` 的精度取决于具体适配器的估计方法，ADR-0014 记录了目前一种实现的做法与精度。
- **校准阶段**：交给算法的 `t` 是采样流的 `t`（`timeOrigin` 为空，窗口内再平移成相对窗口第一个样本）。原始到达时间保留为 `arrivalT`，随校准数据一起落盘。窗口只有几秒，丢帧修正在这里可以忽略。
- **录制阶段**：`RecordingSession.start()` 把设备的 `timeOrigin` 设为录制开始的时刻并重开采样流，`stop()` 时还原为空（设备之后还会用于校准）。`sample` 记录的 `t` 是采样流的重建时间，和 GPS、电量在同一基准（相对录制开始的秒数）；`arrivalT` 是到达时间（同基准，同一个数据包的样本相同），`wallClock` 是到达时刻的手机绝对时间（Unix 秒），`frameIndex` 是帧在当前采样流里的序号（断线重连后重新从 0 计）。`magnetic`、`gap_start`、`gap_end` 没有采样序号，`t` 就是到达时间（`gap_start` 是超时检测触发的时刻，不是收到数据的时刻）。双传感器各自重建，起点都锚定在手机时钟上，对齐精度仍受到达时间的粒度限制；PRD 里"双传感器时间戳同步误差 < 50ms"指的就是这一点。
- 旧数据（ADR-0014 之前的录制）没有 `arrivalT`/`frameIndex`/`wallClock`，其 `t` 就是到达时间；曾经落盘过 `tCausal` 字段的文件，该字段已废弃，读取时忽略。

## 校准阶段

校准的步骤、判定、算法与失败处理见 **ADR-0012**，本节只描述代码怎么运行。

- **进入校准阶段**（`AppCoordinator.sensorsConnectedReadyForCalibration()`）：对每个已连接的传感器设置回传速率为 50Hz（具备 `OutputRateConfigurable` 能力的调用 `setOutputRate`，同时按新速率重开一条采样流：帧序号从 0 重新计数，时间轴估计回到冷启动；不具备的只调用 `resetStream()`）。传感器在两趟录制之间保持连接，所以每次校准都要重新设置一次，保证从一条新流开始。随后创建 `CalibrationEngine` 和 `CalibrationRecorder`，引擎订阅各传感器的采样流。
- **单步超时**：`CalibrationEngine` 在每个窗口起点（引擎创建、每次点击、超时重置）启动一个一次性计时器，到点即判「动作太慢」并整体重来，重来的这一刻成为新窗口的起点；校准完成或 `close()` 时取消。
- **每次点击确认**（`CalibrationEngine.confirmCurrentStep()`）：先再检查一次距上一次点击是否超过单步时限（计时器之外的兜底）；再从 `CalibrationStreamBuffer` 按 [上一次点击, 这一次点击] 的到达时间区间切出每个传感器的窗口，`t` 平移成相对窗口第一个样本；窗口内帧序号不连续（采样流中断过，见「连接与重连」）则这一步直接判失败；否则把窗口交给 `CalibrationMath` 对应的函数，并通过 `CalibrationRecorder` 落盘原始窗口和判定结果。失败时 `resetToStart` 丢弃全部中间状态、记录失败的尝试、回到第一步。
- **UI**（`CalibrationView`）：显示当前指令、单步倒计时、失败提示（`retryNote`）与身份判定提示（`lastNote`）。倒计时由视图本地计时器驱动。
- **校准结束**（`AppCoordinator.calibrationFinished()`，阶段从 `.calibrate` 切到 `.ready`）：引擎 `close()` 取消订阅、丢弃累积的样本、收尾落盘；成功那次的校准 id 随后写进 session 的 `meta.json`。

## 录制阶段

`AppCoordinator.startRecording()` 创建 `RecordingSession`（F3/F4/F6）：

- **创建时**：把采样流（设备带欧拉角的用 `onSampleWithAngle`）和磁场回调接到各传感器，设置回传速率（固定 50Hz，设备具备 `OutputRateConfigurable` 能力时），写入初始 `meta.json`（`endedAt` 为空）。
- **`start()`**：把两个适配器的 `timeOrigin` 设为录制开始的时刻并重开采样流（init 到 start 之间收到的帧不属于这次录制），开始定位，并启动几个计时器——界面计时 0.2 秒、断线检查 0.5 秒、磁场轮询 0.5 秒（ADR-0013）、电量快照 1 分钟；同时读一次各传感器的电量（具备电量能力的），约 1 秒后记录开始时刻的电量快照。电量快照包含已连接传感器（具备电量能力的）和手机的电量。
- **断线检测（F4）**：每 0.5 秒检查各传感器的 `lastRealtimeAt`（最近一次收到实时数据的时间），超过 2 秒就写一条 `gap_start`（每段缺口只写一次）；之后收到下一帧实时数据时写 `gap_end`。只看实时数据，电量、磁场等响应不刷新这个时间，否则实时数据流停了而其他读取仍有回应时，缺口会被遮住。
- **`stop()`**：停掉计时器和定位，把适配器的 `timeOrigin` 还原为空，再读一次电量；约 1 秒后（等设备回应）记录结束时刻的电量快照、写入带 `endedAt` 的 `meta.json`、关闭存储（含最后一次 fsync）。这个收尾闭包强引用会话——调用方在 `stop()` 之后马上释放会话，用弱引用的话收尾会整体被跳过。
- **后台运行**：靠 Info.plist 的 `UIBackgroundModes`（`bluetooth-central`、`location`）和定位的 `allowsBackgroundLocationUpdates`，App 切到后台后仍能收蓝牙数据、记录 GPS。

## 姿态渲染（F5）

`Pose3DView`（SceneKit，见 ADR-0002）渲染一个简化的、不对称的鞋形组合几何体（不是精细雪靴/雪板模型），具体姿态计算方式见 **ADR-0005**：

- **渲染世界坐标系**：`Pose3DView` 的几何体和相机机位预先约定好"脚尖=+Z、鞋底=-Y"，相机从 -Z 一侧朝 +Z 看，使静止姿态下脚尖朝屏幕里、脚跟朝屏幕外、鞋底朝下。
- **传感器坐标系 → 渲染世界坐标系（常量，一个 session 内只计算一次）**：用该 session 对应传感器的 `SensorOrientationFrame`（`front`/`down`/`left`，来自 F2 校准、随 session 存入 `meta.json`）算出这个换算旋转（`PoseAlignment.sensorToWorld`）。传感器和鞋是刚性固定的，这个换算关系在整个 session 内不变；不能把传感器原始读数直接当渲染世界坐标用，两者是不同的坐标系。
- **实时倾斜（回放拖动时间轴时，每个时间点计算）**：不使用 Angle 字段（欧拉角旋转顺序/正负号约定尚未验证，见硬件协议参考文档「坐标系与单位定义」），改用该时刻的原始加速度计读数，先换算到渲染世界坐标系，再算出相对世界"下"方向的最短路径旋转，驱动模型。
- **数据缺失（PRD F4）**：回放页读取 `left.jsonl`/`right.jsonl` 时把 `gap_start`/`gap_end` 配成缺口区间（`DataGap`）。区间起点取缺口前最后一个采样点的时刻（`gap_start` 记录的是连续 2 秒没数据才判定的时刻，真正缺数据的时间更早开始），终点是 `gap_end`；录制在断线期间结束时，最后一段缺口补到录制结束。回放页在时间轴下方画出缺口条，拖动到缺口内时显示"此时间段数据缺失"并隐藏该侧模型，不用缺口前的旧读数填充；摘要里列出每段缺口的起止时间。
- **已知局限**：只用加速度计只能还原倾斜（俯仰+横滚），不含绕重力轴的偏航，渲染结果不会体现脚绕纵轴转向的动作，这是方案本身的局限，不是缺陷（见 ADR-0005 的后果）。

## 缓冲区生命周期规则

设备适配层（`DeviceAdapter`）**不保存历史**：样本整理出来就交给订阅者，没人订阅时直接丢弃。校准阶段需要的历史由校准流程自己累积（ADR-0011）。

1. **进入校准阶段时**创建 `CalibrationEngine`，每个传感器一个 `CalibrationStreamBuffer`，从此累积该传感器的全部样本。
2. **校准期间**累积量有上限：四步、每步时限 10 秒，至多约 40 秒，50Hz 下每个传感器约 2000 条，内存可以忽略。
3. **校准结束时**（`close()`）取消订阅并丢弃累积的样本。录制阶段不使用这份数据（录制走独立的落盘路径）。
4. 累积的样本不是任何 session 的正式数据来源；落盘到 `Calibrations/` 的是交给判定的窗口副本，不是累积样本的完整内容。

## 持久化策略

### Session 数据

- **落盘方式**：`SessionStorage` 对每路数据流各持有一个 `FileHandle`，每条记录到达即编码为一行 JSON、`write()` 追加，不在应用层做批量缓冲（呼应 ADR-0001"数据完整性优先"的诉求）。
- **按传感器数量生成文件**：`left.jsonl`/`right.jsonl` 只为本次 session 实际使用的传感器创建（1 个或 2 个），`gps.jsonl`/`battery.jsonl` 始终生成。`meta.json` 记录本次使用的传感器数量和实际生成的数据文件名列表，供后续读取时判断这次 session 包含哪些数据流。
- **`left.jsonl`/`right.jsonl` 的行类型**：每行是一个 `SensorSampleRecord`，靠 `type` 字段区分四种记录：`sample`（正常采样点，含加速度/角速度/角度，随实时数据帧按回传速率自动推送）、`gap_start`（F4 判定断线的时刻）、`gap_end`（重新收到数据、缺口结束的时刻）、`magnetic`（磁场读数，见下）。`gap_start`/`gap_end` 记录只有 `t` 字段有值，其余传感器数据字段为 `null`。用于表示 F4 的断线标记，不是单独的文件。
- **`sample` 记录的时间字段**：`t`（相对录制开始的秒数，采样流的重建时间）、`arrivalT`（到达时间，同基准）、`wallClock`（到达时刻的手机绝对时间，Unix 秒）、`frameIndex`（帧在采样流里的序号，重连后重新计）。字段含义见「时间戳来源」。
- **磁场数据（`magnetic` 记录）**：MVP 阶段只为留档尽量多采集，不参与任何计算：方向校准只用加速度和角速度（见 ADR-0012），回放渲染只用加速度计（见 ADR-0005），都不依赖磁场。具备磁场能力（`MagneticFieldProviding`）的设备由 `RecordingSession` 按固定间隔（0.5s）主动轮询（`requestMagneticField()`），适配器把响应换算成 µT 后回调，并落盘为独立的一行 `type: "magnetic"` 记录（字段 `magX/magY/magZ`）。轮询频率与落盘方式的决策见 ADR-0013。
- **落盘 ≠ 持久化**：`FileHandle.write()` 只保证数据进入 OS 页缓存，不保证立刻写入闪存。真正的持久化保证由**每 10 秒一次的 `synchronizeFile()`（fsync）**兜底，具体选择这个间隔的理由和备选方案见 **ADR-0003**。
- 实际效果：崩溃/被系统杀掉的极端场景下，每路数据流最坏情况丢失约 10 秒内的数据，而不是整个 session。

### 校准数据

校准数据是独立于 `SessionStorage` 的一条落盘路径，由 `CalibrationRecorder` 负责（决策见 ADR-0012 §7）。

- **目录**：`Documents/Calibrations/<校准 id>/`，与 `Sessions/` 平级。校准 id 是进入校准阶段的时间戳（`yyyyMMdd-HHmmss-SSS`），成功后写进 session `meta.json`。
- **三个 JSON Lines 文件**，贯穿同一次校准阶段的所有尝试，每条记录带 `attempt` 编号（从 1 起，每次失败重置后加 1），不覆盖、不合并：
  - `samples.jsonl`：每一步每个传感器的完整窗口原始样本，一行一个采样点（`CalibrationSampleRecord`）。字段：`type`（恒为 `sample`）、`attempt`、`step`、`sensorId`、`t`（重建时间，相对窗口第一个样本）、`arrivalT`（到达时间，相对窗口第一个样本）、`frameIndex`（本次校准内的帧序号）、`wallClock`（到达时的手机绝对时间，Unix 秒）、`accelX/Y/Z`（g）、`gyroX/Y/Z`（deg/s）。
  - `judgments.jsonl`：每一步每个传感器一条判定记录（`CalibrationJudgmentRecord`）。`result` 取值：`motion`（抬脚窗口，只有 `peakSpeed`）、`standingDown`（站立，基准轴写在 `downStart`）、`frame`（迈步成功，带 `front`/`down`/`left`）、`insufficientData`、`driftTooLarge`、`directionUnclear`。迈步窗口另带 ADR-0012 §5 的全部中间量：`downStart`/`downEnd`、`driftDegrees`、`startDriftDegrees`、`startAttitudeSource`（`continuous` | `aligned`）、`peakSpeed`、`coherence`、积分区间的 `windowDuration`/`sampleCount`、`segmentStartT`/`segmentEndT`。
  - `attempts.jsonl`：每次尝试一条结局（`CalibrationAttemptRecord`）：`outcome`（`completed` | `failed`）、失败时的 `failedAtStep` 与 `failureReason`（即提示文案）、完成时的左右传感器 id 与参考系。
- **步骤标签**（`step` 字段）：`liftLeft`、`liftRight`、`standing`、`stride`。
- **兼容旧数据**：较早落盘的数据可能没有 `type`、`arrivalT`、`frameIndex`、`wallClock`，其 `t` 是到达时间；还可能含 `type: "chipTime"` 的片上时钟读数记录（ADR-0010 的实验数据），读取时按 `type` 过滤。
- **写入失败不阻断校准流程**。单次体积在百 KB 量级，不做自动清理，用户可从 Files App 手动删除。

## 数据导出

App 的 Documents 目录（`Sessions/`、`Calibrations/` 所在的目录）对用户可见：可以在设备本地的 Files App（"我的 iPhone"分类下）里直接浏览、删除、导出，也能通过 Mac Finder（USB 连接）访问，具体理由和备选方案见 **ADR-0004**。这意味着用户可以在系统层面直接操作这些文件，App 本身不会感知到外部的增删改；历史记录列表（F7，`HistoryView`）每次进入都重新读取目录内容、不缓存，所以这个风险影响很小。

## 已知的开放项（与本设计相关）

- 10 秒的 fsync 间隔是否合适，需要现场测试后依据实际 I/O 开销和可接受的丢失窗口调整（见 ADR-0003 的"对后续工作的影响"）。
- 校准相关的待验证项（判定参数、加速度符号约定、运动方向与脚尖朝向的差异、雪场坡度的影响）见 ADR-0012「后果」；阈值以代码为准，调整不需要新建 ADR。
- 丢帧修正（ADR-0014）：算法参数和精度数字来自真实记录加合成数据，需要更多真实记录（不同手机、蓝牙环境、更差的链路）验证并回填。
- 按服务 UUID 过滤要求设备把服务 UUID 放进广播包（ADR-0016「后果」）；接入新设备前需要先验证这一点。
