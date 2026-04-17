# NexAgent 代码规范

本文档基于当前仓库中的 `README`、`AGENTS.md`、`docs/dev/*`、核心实现与测试约束整理，目标不是给出一份通用 Elixir 风格指南，而是沉淀出适合 NexAgent 当前主线的工程规范。

它服务三个目的：

1. 让后续改动先对齐项目真实架构，再动手写代码。
2. 降低“局部看起来能跑，但破坏长期运行一致性”的改动概率。
3. 让 agent 和人类协作者在实现、测试、写文档时使用同一套判断标准。

如果本文档与以下文件冲突，优先级按下面顺序理解：

1. `AGENTS.md`
2. `docs/dev/progress/CURRENT.md`
3. `docs/dev/task-plan/*.md`
4. 本文档

## 1. 项目定位

NexAgent 不是一次性 CLI demo，也不是模型调用外面包一层 prompt 的薄壳。它的核心是一个长期运行、可在聊天应用中工作的 AI agent 系统，重点能力包括：

- 长期在线与多渠道接入
- 会话隔离与长期记忆
- 工具、技能、定时任务、后台任务
- 自我反思、技能沉淀与代码级进化
- 依赖 Elixir/OTP 获得监督、隔离、恢复和热更新能力

因此，仓库中的代码优先服务下面这些系统目标：

- 长生命周期，不是“一次请求结束就丢状态”
- 一致性优先，不接受 prompt、tools、skills、config 各自漂移
- 演进优先，允许系统逐步重构到更稳定的 runtime 架构
- 可验证优先，关键边界必须有测试或文档冻结

## 2. 当前架构认识

### 2.1 系统主链

当前核心链路可以按下面理解：

1. Channel 进程从 Telegram / Feishu / Discord / Slack / DingTalk 等入口接收事件
2. `Nex.Agent.Gateway` 协调各 channel 生命周期
3. `Nex.Agent.InboundWorker` 消费入站消息，按 `channel:chat_id` 维度路由会话
4. `Nex.Agent` 负责组装 agent 运行参数
5. `Nex.Agent.Runner` 执行一次 agent loop
6. `Nex.Agent.ContextBuilder` 构造 prompt 上下文
7. `Nex.Agent.LLM.ReqLLM` 统一接入 provider
8. `Nex.Agent.Tool.Registry` 提供工具定义与执行入口
9. `Nex.Agent.Skills` / `Nex.SkillRuntime` 提供技能发现、always instructions 与按轮次选择的 skill runtime 能力
10. `SessionManager`、`Memory`、`MemoryUpdater` 管理会话与长期记忆

### 2.2 OTP 结构

当前应用是 OTP 应用，不要把它当成一组普通脚本拼接。监督树层面至少要保持这些认识：

- `Nex.Agent.Application` 是总监督入口。
- `InfrastructureSupervisor` 承载 bus、tool registry、cron、heartbeat 等长期基础设施。
- `WorkerSupervisor` 承载入站 worker 与 subagent 相关 worker。
- `ChannelSupervisor` 承载各 channel 子进程。
- `Gateway` 是 channel orchestrator，而不是所有逻辑的汇总大对象。
- `:rest_for_one` 的存在有明确语义：上游基础设施重启时，下游 worker/channel/gateway 需要跟着重建订阅和依赖关系。

任何改动只要涉及监督树，都必须回答清楚：

- 这个进程为什么是长期进程，而不是普通函数调用？
- 它应该挂在哪一层 supervisor 下面？
- 它崩溃后谁应该一起重建？
- 它的 state 是缓存、真相源，还是临时派生物？

### 2.3 当前正在收敛的架构方向

根据 `docs/dev/findings/2026-04-16-runtime-reload-architecture.md` 和当前 task plan，项目主线正在从“各模块各自读取 config / prompt / tools”收敛到“统一 runtime snapshot 真相源”。

因此，新增实现或重构时应当主动靠拢以下方向：

- runtime world view 应该是一份一致快照，而不是模块各自拼接
- config、prompt layers、tool definitions、always-on skill instructions 应该朝同一版本绑定
- session history 可以保留，但 session 内缓存 agent 允许在 runtime version 变化后重建
- `Gateway` 不应依赖全量重启才能吃到配置变化

如果要写临时实现，也要避免把旧的分散读取模式再复制一遍。

## 3. 目录与职责边界

### 3.1 `lib/nex/agent`

这里是主 runtime 代码。默认按职责分层理解：

- `application.ex`、`*_supervisor.ex`：应用启动与监督树
- `gateway.ex`、`channel/*.ex`：外部渠道接入与消息收发
- `inbound_worker.ex`、`runner.ex`、`context_builder.ex`：请求主链
- `config.ex`、`workspace.ex`：配置与工作区定位
- `session*.ex`、`memory*.ex`：会话与记忆
- `tool/*.ex`、`tool/registry.ex`：工具定义、注册与执行
- `skills.ex`、`skills/loader.ex`、`skill_runtime/*`：技能系统与 skill runtime
- `llm/*`：模型接入与 provider 适配
- `evolution.ex`、`upgrade_manager.ex`、`code_upgrade.ex`：自我进化与代码升级

### 3.2 `test/`

测试不是补充材料，而是 contract 的一部分。尤其以下几类测试已经在表达边界：

- layer / prompt contract
- tool surface 和对外可见性
- code layer 与 custom tool 的边界
- config / provider / auth 行为
- write / edit 热更新失败时的回滚语义

修改这些边界前，先看测试表达的系统意图，不要只看当前实现细节。

### 3.3 `docs/dev/`

文档层应按仓库已有约定区分：

- `docs/dev/findings/`：架构结论、取舍与调查结果
- `docs/dev/progress/`：当前主线进度与状态
- `docs/dev/task-plan/`：执行计划，不写成长篇设计文

不要把设计结论、执行计划、进度记录混在同一篇文档里。

## 4. 代码风格总则

### 4.1 优先写清晰的状态流，而不是炫技巧

NexAgent 的难点不是算法，而是长期运行系统里的边界、一致性和状态管理。因此优先：

- 明确输入、输出和状态转换
- 明确同步 / 异步边界
- 明确哪一层拥有真相源
- 明确失败时是否回滚、丢弃、重试或降级

避免为了“写得短”而牺牲语义清晰度。

### 4.2 模块先讲职责，再讲实现

新模块或复杂模块优先满足这几点：

- `@moduledoc` 先讲职责与边界
- public API 名称反映用途，而不是内部实现
- 私有函数按调用流程聚拢，而不是随机堆砌
- 能用小而明确的 helper 拆开流程，就不要把所有逻辑塞进一个大函数

### 4.3 保持现有 Elixir 写法风格

从当前代码看，仓库倾向于：

- `alias` 按职责聚合，而不是过度缩写
- `@spec` 用在公共函数与关键 helper 上
- struct 明确字段，类型定义跟上
- `Keyword.get/3`、`Map.get/3` 显式处理默认值
- 用 `with`、`case`、小 helper 表达分支，而不是层层嵌套
- 用日志记录关键运行状态，但避免日志即业务逻辑

新增代码应延续这些风格，不要引入完全不同的写法体系。

### 4.4 复杂度控制

当前 Credo 配置已经明确这些约束：

- Cyclomatic complexity 尽量不超过 25
- 函数参数个数尽量不超过 10
- 嵌套层级尽量不超过 5

即便没有超过阈值，也要主动拆分：

- 一个函数同时处理“解析输入 + 业务判断 + IO + 状态回写 + 广播事件”，通常就太大了
- 同一分支逻辑重复出现两次以上，应抽 helper
- 复杂的 payload 组装应拆成具名函数，避免内联大 map

## 5. 状态、一致性与真相源规则

### 5.1 先判断真相源

在这个项目里，很多 bug 来自“多个地方都像是真相源”。改代码前先回答：

- 这是持久状态，还是派生缓存？
- 当前 authoritative source 在哪里？
- 读取方能否容忍旧值？
- 更新时是否要求原子一致？

典型例子：

- config 的真相源不应散落在长期进程的 init state 里
- tool visibility 的真相源是 tool definitions，不是 `TOOLS.md`
- workspace 解析应跟 `Workspace.root/1` 及当前冻结规则保持一致
- skill runtime 的 per-turn selected packages 不等于全局 runtime snapshot

### 5.2 避免重新引入分散读取

当前主线正在清理下面这种模式：

- A 模块直接 `Config.load/0`
- B 模块每次自己拼 prompt
- C 模块临时拉 tools
- D 模块把旧配置常驻在 state

新代码不要再复制这种模式。即使当前某个路径尚未完全重构，也应：

- 优先复用已有统一入口
- 没有统一入口时，至少把读取聚合在单一 helper 中
- 在代码中明确这是临时兼容路径还是长期路径

### 5.3 长期进程只持有必要 state

GenServer / Agent / Channel 进程中的 state 应尽量满足：

- 必须长期保存的才放 state
- 能从上游 authoritative source 重新读出的，不要固化副本
- 如果 state 可能 stale，要定义刷新或重建规则

不要为了“访问方便”把配置、上下文、定义、缓存都塞进长期 state。

## 6. 分层边界规则

### 6.1 Prompt / layer 边界必须清晰

从 `ContextBuilder` 和相关测试可见，layer contract 是重要边界：

- identity：运行时默认身份基线
- `AGENTS.md`：系统级操作指导
- `SOUL.md`：人格、价值观、行为风格
- `USER.md`：用户画像、偏好、协作方式
- `TOOLS.md`：工具说明，不是工具真相源
- `MEMORY.md`：长期事实与环境约定

因此：

- 不要把 USER 内容写进 SOUL 语义里
- 不要把 TOOLS 当成真实工具定义来源
- 不要让 identity / persona / memory 在多层互相抢所有权
- 如果发现 out-of-layer 数据，优先诊断、约束或迁移，而不是静默放任

### 6.2 进化层级要写对地方

项目对演化层级已经有清晰划分：

- `SOUL`：人格与价值观
- `USER`：用户偏好与协作方式
- `MEMORY`：长期事实
- `SKILL`：可复用工作流
- `TOOL`：确定性可执行能力
- `CODE`：框架内部实现

新增功能或修复时，不要跨层乱写：

- 用户偏好不要落进 MEMORY 当“世界事实”
- 临时问题处理流程不要直接写成 TOOL
- workspace 自定义工具或技能，不应越界修改 framework code layer

### 6.3 Code layer 与 workspace layer 分离

测试已经冻结一条重要规则：

- `reflect` / `upgrade_code` 面向 framework code layer
- workspace custom tool 不属于 framework code layer

因此涉及源码升级、源码反思、模块检查时，必须先判断目标属于哪一层，不能把 workspace 扩展内容混进核心 framework 代码边界。

## 7. Tool / Skill / Channel 规则

### 7.1 Tool 是确定性能力，不是说明文案

工具模块应满足：

- 实现 `Nex.Agent.Tool.Behaviour`
- `definition/0` 与 `execute/2` 保持一致
- description 清楚说明适用边界、特殊渠道行为和必要参数
- 对外错误信息可操作，不要只返回模糊失败

工具设计应优先考虑：

- 这个能力是否可重复、可确定执行？
- 是否应该是 tool，而不是 skill / memory / code 改动？
- 是否会暴露不该给某类 agent 的能力？

### 7.2 Tool surface 要考虑场景过滤

当前仓库明确存在不同 surface：

- `:all`
- `:subagent`
- `:cron`

因此新增工具时必须同时考虑：

- 它能不能给 subagent 用？
- 它会不会造成递归调度、重复外发消息或越权？
- 它是否应该出现在 base tools，而不是 skill-generated synthetic tools 中？

不要只在 `Registry.definitions(:all)` 下看起来正常，就认为完成了。

### 7.3 Skill 是 Markdown 工作流，不是隐藏代码执行器

当前技能系统的约束很明确：

- skills 默认是 Markdown-only
- code-based capability 应实现为 tool
- skills 支持 always instructions、discover/get/capture、draft/publish 流程
- skill runtime 的 selected packages 是 per-turn 数据

因此：

- 不要把复杂执行逻辑偷偷塞进 skill 描述，绕开 tool 边界
- 不要把 skill 展开成一堆伪工具名污染模型 surface
- 修改 skill 相关逻辑时，要区分缓存态全局技能与按轮次选择的运行时技能

### 7.4 Channel 特性必须局部封装

不同 IM channel 有真实差异，尤其 Feishu 已有相对细化的 native message 约定。规则是：

- 渠道特有协议、payload、上传/补发/patch 行为，尽量留在 channel 模块内部
- 通用 tool 层只暴露统一意图，不把渠道细节扩散到全系统
- 新增 channel 能力时，优先补充 channel 模块 contract 与测试，而不是把特殊逻辑散落在 runner / tool / worker 各处

## 8. 配置、工作区与路径规则

### 8.1 workspace 解析要统一

路径相关逻辑优先复用 `Workspace` 模块，不要自造一套：

- `Workspace.root/1`
- `Workspace.dir/2`
- `Workspace.memory_dir/1`
- `Workspace.skills_dir/1`
- 其他已存在目录 helper

如果某处路径解析与当前主线冻结规则不一致，应修正为统一 resolver，而不是继续增加例外。

### 8.2 配置对象优先保持结构化

`Nex.Agent.Config` 已经提供结构化 `defstruct` 与 accessor helper。新增配置时：

- 优先进入 `Config` struct
- 提供默认值合并逻辑
- 为关键配置提供 accessor / predicate helper
- 测试 save/load 往返与默认值行为

不要在业务模块里到处写字符串 key 解析逻辑，导致配置语义分裂。

### 8.3 CLI 只是 runtime host shell

README 已明确 CLI 不是独立任务系统产品入口。实现上应保持：

- CLI 管理 runtime、实例 targeting、状态查询与手动触发
- 实际能力仍应通过 agent loop、tools、skills 完成

不要把本该在 runtime 内完成的核心能力持续下沉到 Mix 任务里。

## 9. 失败处理与恢复规则

### 9.1 失败语义必须显式

关键路径要明确失败后发生什么：

- 返回错误并保持旧状态
- 回滚已写入文件
- 杀掉超时任务
- 丢弃 stale agent，下轮重建
- 发布错误消息给用户

不要让失败语义隐含在一串 `case` 或日志里。

### 9.2 写文件后能回滚的要回滚

从现有 `write` / `edit` 测试看，仓库已经接受这样的质量标准：

- Elixir 源文件写坏且热更新失败时，必须回滚
- 编辑失败不能把工作区留在半坏状态

所以新增“修改文件并尝试热加载”的逻辑时，必须考虑：

- 如何保存旧内容
- 哪些失败会触发回滚
- 回滚失败时如何向上报告

### 9.3 日志要为运维和排障服务

日志适合记录：

- 请求开始/结束
- 关键配置摘要
- iteration、tool 调用、streaming、reconnect、reload 等运行事件
- 失败原因与耗时

日志不应用来：

- 偷偷存业务状态
- 代替 contract
- 输出过多无结构的大对象，污染排障视野

敏感信息只记录 presence / shape，不直接明文打印。

## 10. 测试规范

### 10.1 先测 contract，再测实现细节

优先写这类测试：

- 对外 API contract
- layer / boundary contract
- 配置、tool surface、provider 行为
- 失败回滚和恢复语义
- runtime 状态切换语义

谨慎写纯实现细节测试，避免重构困难。

### 10.2 测试应尽量自给自足

现有测试大量采用临时 workspace / 临时配置文件。延续这套做法：

- 使用 `System.tmp_dir!()` 建隔离环境
- 用 `on_exit` 清理文件与 env
- 尽量显式创建需要的目录和 bootstrap 文件
- 不依赖开发机上已有 `~/.nex` 状态

### 10.3 测试名直接表达行为

仓库当前测试命名风格比较明确，应保持：

- `test "write rolls back invalid elixir source when hot reload fails"`
- `test "tool_list exposes split user and memory layers"`

即：一句话说清楚行为、条件、预期结果。

### 10.4 新增能力至少补一类验证

改动后至少补其中一种：

- 单元测试
- 集成测试
- contract characterization test
- 针对具体回归的回放测试

仅凭“手工看起来可以”不够。

## 11. 文档规范

### 11.1 文档要跟仓库现有结构对齐

新增文档前先判断类型：

- 架构结论、取舍、调查：放 `docs/dev/findings/`
- 执行中状态：放 `docs/dev/progress/`
- 可交付的阶段性执行计划：放 `docs/dev/task-plan/`
- 横跨仓库、长期适用的共识规范：可放类似本文这样的稳定规范文档

### 11.2 计划文档必须是执行文档

如果写 `docs/dev/task-plan/phase*.md`，必须符合仓库冻结规则：

- 按 `Stage` 组织
- 每个 stage 包含：
  - `前置检查`
  - `这一步改哪里`
  - `这一步要做`
  - `实施注意事项`
  - `本 stage 验收`
  - `本 stage 验证`

不要把 phase 文档写成动机散文。

### 11.3 文档写法要可执行、少空话

好的仓库文档应：

- 指向具体模块、函数、struct、contract
- 写清完成条件与验证命令
- 明确已冻结边界与非目标

避免：

- “后续可以考虑”
- “这里需要一些重构”
- “支持更灵活的能力”

这类没有执行价值的话。

## 12. LLM / Provider 约定

### 12.1 Provider 接入统一走 `ReqLLM`

新增 provider 行为或 provider 相关 bugfix 时，应优先收敛在：

- `Nex.Agent.LLM.ProviderProfile`
- `Nex.Agent.LLM.ReqLLM`

不要重新引入“一家 provider 一套手写客户端大分叉”。

### 12.2 Anthropic-compatible 请求格式要守约

仓库的 `AGENTS.md` 已冻结一条关键约定：

- `tool_choice` 使用 Anthropic 兼容格式
- 不要写成 OpenAI function calling 的旧格式

所有 LLM 请求格式改动必须先检查这个约束，不要按习惯乱改 payload。

### 12.3 Provider 差异应在适配层消化

例如：

- Ollama 走 OpenAI-compatible base url，但 API key 语义不同
- OpenAI Codex 有特殊 auth/base_url 语义
- system message 可能需要转成 provider_options

这类差异应尽量封装在 provider profile / req_llm 层，而不是把分支散到 runner、tool 或业务层。

## 13. 改代码时的最低检查清单

提交任何非纯文档改动前，至少自查：

1. 这次改动有没有破坏模块真相源或重复引入状态副本？
2. 是否遵守了现有 layer / tool / skill / code 边界？
3. 是否把 channel 特性错误地下沉到了通用层？
4. 是否为失败路径定义了明确回滚、重试或保持旧值策略？
5. 是否补了最窄但有效的测试？
6. 是否需要更新 `docs/dev/progress/CURRENT.md`、相关 findings 或 task plan？

## 14. 直接可执行的仓库约定

最后把最容易落地的规则收敛成一句话：

- 先认清真相源，再改状态。
- 先守住层次边界，再扩能力。
- 先补 contract，再谈重构。
- 先保证长期运行一致性，再追求局部省事。
- 能复用现有模块，就不要并行造第二套机制。
