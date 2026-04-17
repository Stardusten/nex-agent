# 2026-04-16 Streaming Phase4 Polish

## 结论

phase3a 已经把最重的结构债处理掉了：

- `Runner` 的 raw stream drain/assemble 已收进 `Assembler`
- conversation 与 consolidation 共用同一套 raw stream accumulation machinery
- `MultiMessageSession` 命名已收敛
- transport finalize 主路径已收口到 `%Nex.Agent.Stream.Result{}`

剩下的问题不再是 phase3a blocker，更适合作为 phase4 前或 phase4 初期的架构 polish。

## 建议继续跟进的问题

### 1. transport implementation selector 仍依赖实现顺序

当前 `Transport.open_session/4` 通过实现列表顺序扫描，谁先返回 `{:ok, session}` 就采用谁。

现状下这个行为是可用的，因为：

- `FeishuSession.open_session/4` 只匹配 `"feishu"`
- `MultiMessageSession.open_session/4` 是兜底

但如果后面加入 Slack native stream、Telegram edit-message、Discord edit-message 之类的新实现，这种“顺序竞争”模式会有隐性风险：

- 匹配条件写宽的实现可能 silently 抢走会话创建权
- 行为正确性依赖实现顺序，而不是显式 selector 规则

更自然的下一步是引入显式 selector：

- 先确定 channel / capability / metadata 对应哪个实现
- 再把 `open_session/4` 委托给那个实现

这不需要上大 registry，只需要把“选择”从“尝试直到成功”改成“明确决策后委托”。

### 2. `TransportActions` 仍是一个共享执行器

phase3a 已经把平台特例从 `InboundWorker` 入口层移走，但 `TransportActions` 仍是 multi-message 路径的共享动作执行器。

当前它的问题不是错误，而是：

- 如果以后出现更多 action shape
- 或者某个平台需要不同 publish policy

那它可能再次长成新的中心 dispatcher。

现阶段建议：

- 如果后续只保持 `{:publish, channel, chat_id, content, metadata}` 这一种通用动作，保留 `TransportActions` 也可以
- 如果 phase4 引入更多平台特化 action，就把动作解释进一步下沉到各 implementation

### 3. `Runner` 里还保留少量 streaming policy

现在 `Runner` 已经不再持有 raw stream machinery，但仍决定一部分 streaming policy：

- 何时 suppress current reply stream
- tool 前是否发 `text_commit`
- suppress state 何时写回 assembler

这比 phase3 前已经轻很多，因为它们是 policy，不是底层组装状态机。

因此当前判断是：

- 这块不需要为了“更干净”继续立即抽象
- 只有当 phase4 出现第二套/第三套不同 policy 需求时，再考虑从 orchestrator 里继续抽出

## 建议优先级

1. phase4 前优先做：
   - transport selector 显式化
2. phase4 视需求决定：
   - `TransportActions` 是否继续下沉
3. 暂时不建议主动做：
   - 为了纯粹分层继续拆 `Runner` policy
