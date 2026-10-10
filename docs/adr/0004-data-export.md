---
type: adr
status: 生效
review: ../review.md#adr
---

# 0004 开放 Documents 目录到 Files App，作为数据导出方式

## 决策

开放 App 的 Documents 目录，使其在设备本地的 Files App（"我的 iPhone"分类下）中可见、可浏览、可导出。做法是在 Info.plist 中启用两个键：

- `LSSupportsOpeningDocumentsInPlace`：使 Documents 目录出现在 Files App 中。
- `UIFileSharingEnabled`：同时支持通过 Mac Finder（USB 连接）浏览和导出文件。

## 依据

- 需求：[F-012](../prd.md#f-012)（数据可导出）。
- 录制数据写入 App 沙盒的 Documents 目录。iOS 沙盒默认私有，不开放时只能通过 Xcode 的"Devices and Simulators"窗口手动导出容器，日常使用不现实。数据录了拿不出来等同于没录，而 MVP 的目标是先攒数据、再用 `jq`、pandas 等工具分析。
- 日常分析通常需要一次性访问多趟数据（如脚本批量读取多个 session 目录），开放整个目录能直接满足，实现成本只是两个 Info.plist 开关。

## 备选方案

### App 内"分享"按钮（未采纳）

只导出当前查看的那一趟，不暴露内部目录结构，也不会因用户在系统层面误删或移动文件导致 App 状态与磁盘不一致。但需要额外代码（打包目录、调用分享面板），且一次只能导出一趟，不能像 Files App 那样批量操作整个 `Sessions/` 目录。它更适合"分享单条数据给别人"，MVP 阶段优先级更低。

### 两者都做（未采纳）

MVP 阶段没必要维护两条导出路径，增加不必要的复杂度。

## 影响

- 用户能在 Files App 里直接浏览所有历史 session，用 Finder 连接线也能批量导出，与 App 内历史记录列表（[F-007](../prd.md#f-007)）是两条互补的访问路径。
- 整个 Documents 目录结构对用户可见，包括可能存在的异常或半途失败的 session；用户可以直接删除或移动文件，App 不会感知。历史记录列表每次打开都重新读取目录、不缓存，所以影响很小：最多是列表里少一条记录，不会显示"幽灵数据"。
- 没有"分享单个 session"的聚焦体验（如 AirDrop 直接发给别人）。需要时可以叠加 App 内分享按钮，不与本决策冲突。
