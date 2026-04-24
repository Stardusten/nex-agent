# 2026-04-24 Self-Evolution User Guide

## Summary

当前的自进化系统已经从“会改代码”演进到“会观察自己、会复盘、会提出候选改进动作，并且可以在 owner 批准后按正式主链执行”。

它还不是一个会定期扫原始错误日志、然后自动修代码并自动上线的全自动系统。

最准确的用户心智是：

```text
持续观察
-> 阶段性触发复盘
-> 生成 candidate
-> owner 查看/批准/拒绝
-> 沿既有 deterministic lane 执行
```

## 用户会感受到什么

### 1. 平时不会频繁被打扰

系统平时主要是在后台记录结构化 observation，不会因为单次报错就主动跳出来打断用户。

当前默认行为不是：

- 每隔几分钟弹出“我发现有个地方可以改”
- 连续失败几次就自己开始大修代码
- 自动 deploy

### 2. 会在特定时机自动做“复盘”

当前真实存在的自动触发主要有两类：

- **记忆 consolidation 达到阈值后**
  - `Memory.consolidate/4` 成功后会调用 `Evolution.maybe_trigger_after_consolidation/1`
  - 当计数达到阈值时，触发一次 `post_consolidation` evolution cycle
- **周级定时复盘**
  - `Heartbeat` 维护 weekly evolution 状态
  - 系统支持按 `scheduled_weekly` 触发更深的 evolution cycle

这两种自动触发做的是“复盘并提出 candidate”，不是“自动执行高风险改动”。

### 3. candidate 默认不会主动推给用户

当前系统会把 candidate 写进 ControlPlane lifecycle observations，但默认不会主动在聊天里弹一句：

- “我发现最近 web_search 连续失败，要不要我修？”
- “我这里有两个 candidate，建议先看第一个”

当前用户体验更像：

- 系统后台自己想
- 把结果沉淀成 candidate
- 由用户/owner 主动查看和审批

## 用户怎么查看它的改进建议

当前主要有两类入口：

### 1. 在对话或 owner run 里查看

统一入口是：

```text
evolution_candidate
```

当前最小动作：

- `evolution_candidate list`
- `evolution_candidate show`
- `evolution_candidate approve`
- `evolution_candidate reject`

推荐心智：

- 想看最近有哪些候选动作：`list`
- 想看某个候选动作的证据和当前状态：`show`
- 同意它执行：`approve`
- 不同意：`reject`

### 2. 在反射/管理视图里查看

系统还支持从只读视角看 evolution 状态：

- `reflect evolution_status`
- `reflect evolution_history`
- `admin` recent signals / recent candidates / recent events

这些视图适合先看“最近发生了什么”，再决定是否进入 `evolution_candidate` 审批链。

## candidate 存在哪里

candidate **不是** 存在内存里，也 **不是** 存在 sqlite 里。

当前真相源是 workspace 下的 ControlPlane observation store：

```text
workspace/control_plane/observations/YYYY-MM-DD.jsonl
workspace/control_plane/state/gauges.json
workspace/control_plane/state/budget.json
```

candidate 本身不是一张单独的 `candidates.json` 表，而是 observation reduction 的结果。

也就是说，系统会先写这些 lifecycle events：

```text
evolution.candidate.proposed
evolution.candidate.approved
evolution.candidate.rejected
evolution.candidate.realization.generated
evolution.candidate.realization.failed
evolution.candidate.apply.started
evolution.candidate.apply.completed
evolution.candidate.apply.failed
evolution.candidate.superseded
```

然后运行时再把这些 events 归约成“当前 candidate 状态”。

所以更准确地说：

- **持久化介质**：workspace 内 JSONL observation files
- **状态来源**：ControlPlane lifecycle observations
- **展示结果**：运行时 reduction，而不是单独数据库表

## 它到底会不会“连续出错几次就自动开始 debug”

会自动开始的，是 **复盘和提案**，不是默认的 **代码修复并上线**。

真实行为更接近：

1. 某类失败被反复记录进 ControlPlane
2. aggregator 识别出 repeated pattern
3. evolution 在合适 trigger + budget 下生成 candidate
4. owner 查看 candidate
5. owner 批准后，系统才沿正式主链执行

所以答案是：

- **会自动收集和归纳问题**
- **会自动产出候选改进**
- **不会默认自动高风险执行**

## 当前已经能自动做什么

已经具备的能力：

- 持续收集运行事实
- 将失败、signal、当前 run 状态、budget 收口到 ControlPlane
- 自动触发 evolution cycle（阈值 / 周期）
- 生成带 `evidence_ids` 的 candidate
- owner 批准后，沿已有 deterministic lane 执行一部分 candidate

已接入的执行思路：

- `memory_candidate` -> `memory_write`
- `soul_candidate` -> `soul_update`
- `skill_candidate` -> `skill_create`
- `code_hint` -> 现有 CODE lane（`find/read/apply_patch/self_update`）

## 当前还不会做什么

当前仍然明确不做：

- 不靠扫原始日志文件做决策
- 不默认主动把 candidate 推送到用户聊天里
- 不默认自动 deploy 高风险代码改动
- 不绕过 owner 执行 `memory/skill/soul/code` 改动

尤其是 `code_hint`，当前心智应该理解为：

```text
默认更偏 plan
而不是默认直接 apply + deploy
```

## 现在最适合的使用方式

如果你作为 owner 使用这套系统，最顺手的方式是：

1. 正常使用 agent
2. 让系统在后台持续记录 observation
3. 遇到想确认“最近它自己发现了什么”时，主动看：
   - `reflect evolution_status`
   - `reflect evolution_history`
   - `evolution_candidate list`
4. 对值得推进的 candidate 做：
   - `show`
   - `approve` / `reject`
5. 再通过 `observe` / `admin` 看 execution lifecycle

## Conclusion

从用户视角看，当前自进化系统最像：

> 一个会在后台持续自查、会定期复盘、会整理候选改进动作、但执行前仍然需要 owner 拍板的助手。

它已经不是“瞎改代码”的阶段了，但也还不是“完全无人值守自我进化”的阶段。
