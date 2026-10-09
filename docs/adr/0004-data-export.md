# ADR-0004：开放 Documents 目录到 Files App，作为数据导出方式

| 字段 | 内容 |
| --- | --- |
| 状态 | 已采纳 |
| 日期 | 2026-09-20 |
| 决策者 | Googol Lee |
| 关联 PRD | docs/prd/mvp.md（非功能需求"数据可导出"） |

## 背景（Context）

`SessionStorage` 把录制数据写入 App 沙盒的 Documents 目录（`<Documents>/Sessions/<sessionId>/`，见 ADR-0001）。iOS App 沙盒默认是私有的，即使数据完整落盘，用户也没有直接手段把文件拿出设备——只能通过 Xcode 的"Devices and Simulators"窗口手动导出容器，这对日常使用完全不现实。PRD 明确"数据可导出"是非功能需求：数据录了但拿不出来，等同于没录，因为 MVP 的核心目标就是"先攒数据、后续用 `jq`/pandas 等工具分析"（见 ADR-0001）。

## 决策（Decision）

开放 App 的 Documents 目录，使其在设备本地的 **Files App**（"我的 iPhone" 分类下）中可见、可浏览、可导出。具体做法是在 Info.plist 中启用两个键：

- `LSSupportsOpeningDocumentsInPlace`：使 Documents 目录出现在 Files App 中。
- `UIFileSharingEnabled`：同时支持通过 Mac Finder（USB 连接）浏览/导出文件。

## 备选方案（Alternatives Considered）

### 方案 A：App 内"分享"按钮

- 优点：只导出用户当前正在看的这一趟 session，不暴露内部目录结构和其他历史记录；不用担心用户在系统层面误删/误移动文件导致 App 内存状态与磁盘不一致。
- 缺点：需要额外写代码（打包目录、调用分享面板）；即使配合历史记录列表（F7）逐条选择要导出的 session，也只能一次导出一趟，没法像 Files App 那样直接看到/批量操作整个 `Sessions/` 目录。
- 未采纳原因：日常分析场景通常需要一次性访问多趟数据（比如脚本批量读取多个 session 目录），"开放整个目录"能一次性满足这个需求，实现成本也低得多；方案 A 更适合"分享单条数据给别人"这类场景，MVP 阶段优先级更低。

### 方案 B：两者都做

- 未采纳原因：MVP 阶段没必要同时维护两条导出路径，增加不必要的复杂度。

## 后果（Consequences）

- 正面：
  - 实现成本极低（两个 Info.plist 开关，不需要写代码）。
  - 用户能在 Files App 里直接浏览所有历史 session，用 Finder 连接线也能批量导出，和 App 内的历史记录列表（F7）是两条互补的访问路径。
- 负面：
  - 整个 Documents 目录结构对用户可见，包括可能存在的异常/半途失败的 session；用户可以在 Files App 里直接删除或移动文件，而 App 本身不会感知到这些变化。历史记录列表（F7）每次打开时都是重新读取目录内容，不缓存，所以这个风险实际影响很小——最多是列表里少一条被删掉的记录，不会显示"幽灵数据"。
  - 相比方案 A，没有"分享单个 session"的聚焦体验（比如通过 AirDrop 直接发给别人）。
- 对后续工作的影响：
  - 如果后续要支持"分享单个 session 给别人"这类场景，可以在本决策之上叠加方案 A（历史记录列表页里对单个 session 提供"分享"按钮），不需要否定这条 ADR，是叠加而非取代。

## 相关链接

- 相关 ADR：ADR-0001（存储格式）
- 相关文档：docs/design/system-design.md
