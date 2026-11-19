# ADR-0001: 优化 QEMU/QGA 与 HarmonyOS 的接口调用

- 状态：Proposed
- 日期：2026-11-20
- 范围：`feature/hish_main` 的 QGA/QMP、native NAPI、状态栏轮询；不包含远程 HTTP 后端（仓库内不存在）

## 背景

HiSH 是单机 HarmonyOS 应用，"后端"实际是 QEMU（QGA/QMP）+ native NAPI。当前接口路径存在三类固定开销：

1. `VmStatusBar.refreshStatus()` 默认每 5 秒执行 10 次串行 QGA 命令：
   `ping`、`getHostName`、`getVcpus`、`getFilesystemInfo`，以及
   `getMemoryInfo` / `getCpuStats` / `isSshRunning` 各自的
   `guest-exec` + `guest-exec-status`。
2. `QemuAgent.sendCommand()` 每 50ms 轮询响应；`execAndGetOutput()` 每次
   `guest-exec-status` 前固定 `setTimeout(200)`。每轮至少 600ms 纯等待，
   叠加响应轮询后约 1 秒。
3. 静态信息（hostname、vCPU 数、文件系统）每轮重复查询；应用进入后台后
   `VmStatusBar` 定时器仍继续运行（`EntryAbility.onBackground` 只切换后台保活）。

另有 UI 线程阻塞：`RootfsManagementContent.showDiskInfo()` 同步调用
`napi.getImageInfo()`（qemu-img 子进程），`EmulatorListGrid` 同步调用
`napi.getSnapshots()`，`syncRootfsViewItems()` 与 `EmulatorItem.aboutToAppear()`
同步读取 qcow2 头；这些会直接卡主线程。

## 决策

按以下顺序实施，P0 完成后再评估 P1：

### P0-1 QGA 响应事件驱动

- `QemuAgent` 维护 `id -> pending Promise` 映射。
- socket `message` 回调按行解析、按 `id` 唤醒对应 Promise；删除 50ms 轮询。
- 保留 `guest-sync-delimited` 的 0xFF/行缓冲处理。
- 允许 hostname/vCPU 等独立查询流水线，由 `id` 匹配响应。
- 保留 `QemuAgentManager` 的 HIGH 抢占语义：`sendCommand` 增加优先级，HIGH 请求
  不得排在低优先级状态查询之后，可取消未发送的低优先级请求；电源/关机仍走 HIGH，
  必要时保留断开重连兜底。

### P0-2 合并动态指标 + 缓存静态信息

- 新增 `getGuestMetrics()`，用一次 `guest-exec` 执行：
  `sh -c 'cat /proc/meminfo; echo __HISH_SEP__; cat /proc/stat; echo __HISH_SEP__; pgrep sshd || pidof sshd'`
- 解析三段，替代 `getMemoryInfo()` + `getCpuStats()` + `isSshRunning()`。
- hostname、vCPU 按连接/60s 缓存；`getFilesystemInfo()` 的 used-bytes 是动态值，
  最多缓存 30s，或随动态指标每轮刷新。
- 删除 `refreshStatus()` 中独立的 `ping()`；后续命令失败即判定连接断开，
  已连接的 20s 心跳继续由 `QemuAgentManager` 负责。

### P0-3 后台暂停轮询

- `EntryAbility.onBackground/onForeground` 写入应用级前后台标志。
- `VmStatusBar` 订阅该标志；后台停止刷新定时器，前台恢复并立即刷新一次。

### P0-4 日志与死代码

- `QemuAgent` 每命令 INFO、`QemuAgentManager` acquire/release INFO、
  `WebTerminal.sendInput` 每键 INFO 降为 DEBUG 或删除。
- 删除未被引用的 `QemuMonitor.ets`（QMP 2s 轮询/原文日志从未运行）。
  保留 `-qmp` socket 供外部调试，除非确认完全无消费者。

### P1 阻塞调用移出 UI 线程

- `showDiskInfo()` 改用 `taskpool.execute(getImageInfoTask, path)`。
- `EmulatorListGrid.onExport` 改用 `getSnapshotsTask`。
- `syncRootfsViewItems()` / `EmulatorItem` 的 qcow2 头读取改为异步或批量 taskpool。
- `fileToDataUrl()` 的后台图/字体读取异步化或缓存。
- `checkPortUsed` 批量成一次 NAPI（VNC 端口随机探测最多 100 次）。

### 暂不做

- 不把 QGA 整体搬到 native/worker：P0-1/P0-2 后单轮只剩 1-2 次命令，
  搬线程的复杂度与收益不匹配。
- 不用 QMP 替代 QGA 指标：QMP 的 `query-cpus-fast`/`query-memory-size-summary`
  不提供 guest 内部 CPU 使用率与可用内存。
- 远程 HTTP 后端优化不在本 ADR 范围；仓库无此代码。若后续接入，另立 ADR
  评估 RCP 持久 Session/HTTP2、批量/推送、taskpool 解析。

## 备选方案

| 方案 | 结论 |
|---|---|
| 只缩短轮询间隔 | 拒绝：命令数不变，QGA/guest 负载反而上升 |
| 保留 50ms 轮询，只合并命令 | 部分采纳（P0-2），但每条命令仍有最多 50ms 延迟 |
| 用 QMP 查询资源 | 拒绝：QMP 看不到 guest 内部 CPU/内存使用 |
| 每次 QMP 新建连接 | 拒绝：连接/握手成本高；当前 QMP 客户端已是死代码 |
| QGA 放到 native 线程 | 暂缓：P0 后收益有限，先量化 |

## 影响

正向：

- 每 5 秒 QGA 命令数 10 → 2（合并 exec + status；fsinfo 每 30s 一次）；guest shell 3 → 1。
- 每轮固定等待从 ≥600ms 降到约 20–50ms。
- 后台不再轮询；日志量从 ~15–20 条/5s 降到接近 0。
- 同步 NAPI 从 UI 线程移除后，镜像信息/导出/列表刷新不再卡顿。

风险与缓解：

- QGA 并发/响应错配：严格按 `id` 匹配，保留 `guest-sync-delimited`。
- 优先级反转：去掉串行锁后，必须让 HIGH 电源/关机请求优先于状态查询；不能只靠
  FIFO，否则关机可能排在 5s 状态刷新后。保留 QemuAgentManager 的抢占或实现优先级取消。
- 磁盘数据陈旧：fsinfo 的 used-bytes 不能按 60s 静态缓存；上限 30s 或每轮刷新。
- 后台标志生命周期：`onForeground` 必须恢复定时器；无 UI 场景由
  `isComponentActive` 兜底。
- taskpool 与 NAPI 对象传递限制：只传字符串/数字，结果回主线程更新 UI。
- 合并命令的解析依赖分隔符：使用不会出现在 `/proc` 输出中的固定标记，
  并对缺失段做降级。

## 验证

1. 在 QGA 层加计数指标：命令数、平均/p95 延迟、exec 进程数、超时数。
2. 用已有 debug bridge（`hdc fport tcp:7300 tcp:7300`）在 guest 侧执行
   `cat /proc/stat` 等命令，确认响应顺序与并发安全。
3. 对比修改前后：5 秒刷新耗时应 ≤100ms，QGA 命令 ≤2，后台 0 命令。
4. 在状态刷新进行中触发关机/电源操作，确认 HIGH 请求不被低优先级查询阻塞，且 QGA
   不超时、不错位；必要时验证断开重连兜底。
5. 磁盘 usage 在 ≤30s 内更新，未出现长时间陈旧值。
6. 用 `VmStatusBar` 页面观察 1 分钟，确认 CPU/内存/SSH 数值正确、无错位。
7. 打开镜像详情/导出/列表，确认主线程无同步 qemu-img 调用。
8. 回归：电源操作、暂停/恢复、SSH 状态、快照操作。

## 参考

- `feature/hish_main/src/main/ets/lib/QemuAgent.ets:211-319`（50ms 轮询）
- `feature/hish_main/src/main/ets/lib/QemuAgent.ets:477-509`（200ms exec 轮询）
- `feature/hish_main/src/main/ets/components/VmStatusBar.ets:358-475`（每轮 10 次 QGA）
- `feature/hish_main/src/main/ets/lib/QemuAgentManager.ets:63-165`（acquire/release）
- `feature/hish_main/src/main/ets/entryability/EntryAbility.ets:359`（onBackground 未停轮询）
- `feature/hish_main/src/main/ets/components/RootfsManagementContent.ets:353,481`
- `feature/hish_main/src/main/ets/components/EmulatorListGrid.ets:202`
- QEMU Guest Agent: https://www.qemu.org/docs/master/interop/qemu-guest-agent.html
- QGA stream-output: https://patchwork.ozlabs.org/project/qemu-devel/cover/cover.1695034158.git.dxu@dxuuu.xyz/
- HarmonyOS 并发设计: https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/bpta-app-concurrency-design
- HarmonyOS native 跨线程: https://github.com/openharmony-rs/openharmony-docs/blob/master/zh-cn/application-dev/performance/native-threads-call-js.md
