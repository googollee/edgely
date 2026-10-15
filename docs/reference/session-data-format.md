---
type: reference
review: ../review.md#reference
---

# 录制与校准数据格式参考

## 总览

App 把每次录制（session）和每次校准的数据写入 App 的 Documents 目录，用户可以通过系统的"文件"App 或 Mac Finder 直接取出。本文描述这些文件的目录结构和字段，供读取方（回放页、分析脚本）依赖。

```
Documents/
├── Sessions/<sessionId>/
│   ├── meta.json
│   ├── left.jsonl         # 仅在本次使用了左脚传感器时生成
│   ├── right.jsonl        # 仅在本次使用了右脚传感器时生成
│   ├── gps.jsonl
│   └── battery.jsonl
└── Calibrations/<校准 id>/
    ├── samples.jsonl
    ├── judgments.jsonl
    └── attempts.jsonl
```

除 `meta.json` 外都是 JSON Lines：一行一个独立的 JSON 对象。`meta.json` 整体覆盖写入。

## meta.json

| 字段 | 含义 |
| --- | --- |
| `sessionId` | session 标识 |
| `outputRate` | 回传速率，如 `"50Hz"` |
| `startedAt` / `endedAt` | 开始、结束时刻，ISO 8601 格式；录制未正常结束时没有 `endedAt` |
| `sensorCount` | 本次使用的传感器数量，1 或 2 |
| `dataFileNames` | 本次实际生成的数据文件名列表 |
| `leftCalibration` / `rightCalibration` | 该侧传感器的校准参考系，`down`、`front`、`left` 三个单位向量（传感器坐标系下，各 3 个数）；没有则为空 |
| `calibrationId` | 本次使用的校准记录 id，对应 `Calibrations/<校准 id>/`；校准数据落盘失败时可能没有 |

## left.jsonl / right.jsonl

每行是一条记录，`type` 区分四种：

| `type` | 含义 |
| --- | --- |
| `sample` | 正常采样点，随实时数据帧按回传速率产生 |
| `gap_start` | 判定断线的时刻 |
| `gap_end` | 重新收到数据、缺口结束的时刻 |
| `magnetic` | 磁场读数，按固定间隔轮询 |

字段：

| 字段 | 含义 |
| --- | --- |
| `type` | 记录类型 |
| `t` | 相对录制开始的秒数，与 GPS、电量在同一基准 |
| `arrivalT` | 到达时间，相对录制开始的秒数；同一个数据包里的样本相同 |
| `wallClock` | 到达时刻的手机绝对时间，Unix 秒 |
| `frameIndex` | 帧在当前采样流里的序号，断线重连后重新从 0 计 |
| `accelX/Y/Z` | 加速度，g |
| `gyroX/Y/Z` | 角速度，deg/s |
| `angleX/Y/Z` | 设备自带的欧拉角，deg；设备不提供时为空 |
| `magX/Y/Z` | 磁场，µT；只在 `magnetic` 记录里有值 |

约束：

- `sample` 记录的 `t` 是采样流的重建时间，`arrivalT` 是实测到达时间。
- `magnetic`、`gap_start`、`gap_end` 没有采样序号，`t` 就是到达时间；`gap_start` 的 `t` 是超时检测触发的时刻，不是收到数据的时刻。
- `gap_start`、`gap_end` 只有 `t` 有值，其余传感器字段为空。
- 较早的录制没有 `arrivalT`、`frameIndex`、`wallClock`，其 `t` 就是到达时间；曾落盘过的 `tCausal` 字段已废弃，读取时忽略。

## gps.jsonl

| 字段 | 含义 |
| --- | --- |
| `t` | 相对录制开始的秒数 |
| `lat` / `lon` | 纬度、经度 |
| `altitude` | 海拔 |
| `speed` | 速度 |

## battery.jsonl

| 字段 | 含义 |
| --- | --- |
| `t` | 相对录制开始的秒数 |
| `leftPercent` / `rightPercent` | 左右脚传感器电量百分比；没有该传感器或没读到时为空 |
| `phonePercent` | 手机电量百分比 |

至少包含开始点、结束点和每分钟一次的中间快照。

## Calibrations/<校准 id>/

校准 id 是进入校准阶段的时间戳（`yyyyMMdd-HHmmss-SSS`）。三个文件贯穿同一次校准阶段的所有尝试，每条记录带 `attempt` 编号（从 1 起，每次失败重置后加 1），尝试之间不覆盖、不合并。

### samples.jsonl

每一步每个传感器的完整窗口原始样本，一行一个采样点。

| 字段 | 含义 |
| --- | --- |
| `type` | 恒为 `sample` |
| `attempt` | 尝试编号 |
| `step` | 步骤标签：`liftLeft`、`liftRight`、`standing`、`stride` |
| `sensorId` | 传感器标识 |
| `t` | 重建时间，相对窗口第一个样本 |
| `arrivalT` | 到达时间，相对窗口第一个样本 |
| `frameIndex` | 本次校准内的帧序号 |
| `wallClock` | 到达时刻的手机绝对时间，Unix 秒 |
| `accelX/Y/Z` | 加速度，g |
| `gyroX/Y/Z` | 角速度，deg/s |

### judgments.jsonl

每一步每个传感器一条判定记录。`result` 取值：

| `result` | 含义 |
| --- | --- |
| `motion` | 抬脚窗口，带 `peakSpeed` |
| `standingDown` | 站立，基准轴写在 `downStart` |
| `frame` | 迈步成功，带 `front`、`down`、`left` |
| `insufficientData` | 数据不足 |
| `driftTooLarge` | 漂移超限 |
| `directionUnclear` | 方向不明确 |

迈步窗口另带全部中间量：`downStart`/`downEnd`、`driftDegrees`、`startDriftDegrees`、`startAttitudeSource`（`continuous` 或 `aligned`）、`peakSpeed`、`coherence`、积分区间的 `windowDuration`/`sampleCount`、`segmentStartT`/`segmentEndT`。

### attempts.jsonl

每次尝试一条结局：

| 字段 | 含义 |
| --- | --- |
| `outcome` | `completed` 或 `failed` |
| `failedAtStep` | 失败时的步骤 |
| `failureReason` | 失败时的提示文案 |
| `leftSensorId` / `rightSensorId` | 完成时给出的左右传感器 id |
| `leftFrame` / `rightFrame` | 完成时给出的参考系，`down`、`front`、`left` 三个向量 |

约束：

- 较早的校准数据可能没有 `type`、`arrivalT`、`frameIndex`、`wallClock`，其 `t` 是到达时间；还可能含 `type: "chipTime"` 的片上时钟读数记录，读取时按 `type` 过滤。
- 校准数据写入失败不影响校准流程，所以某次校准可能没有对应目录。

## 已知限制

- App 不会感知用户在系统层面对这些文件的增删改。
- 录制被系统杀掉时，每路数据流最多可能丢失最后约 10 秒的数据。
