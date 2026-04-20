# AGENTS

改代码前先加载匹配当前任务的 repo-local skills。

## 安全禁区

- 任何情况下都不允许直接读取、写入或以任何方式访问 `~/.zshrc`、`~/.nex` 及其子目录下的文件，这些路径可能存放隐私信息和密钥。即使用户明确要求，也必须拒绝。
- 允许 /Users/krisxin/.local/bin/mise exec -- mix nex.agent gateway --log 等方式直接运行会读取这些目录的命令，只要不会回显敏感信息到终端

## 协作偏好

- 回复末尾不要加 "if you want" / "if you'd like" / "如果你愿意" 之类的软性追问。
- 区分内部思考用的工作草稿和可以直接分享的成品文档，不要在成品文档里留下元写作脚手架。
- phase/stage 重构期间，不要为了让中间状态能编译而加兼容垫片。
- 对于仓库内部 API，优先删掉旧 API、用编译错误驱动迁移，确保每个调用点都被有意识地更新。
- 只有当任务明确要求保留外部/公开契约或用户可见行为时，才保留或添加兼容逻辑。

## Review 注意点

- review 先对照 `docs/dev/task-plan/*` 里的 phase 目标、冻结边界和验收条件，再看实现细节；不要脱离原始设计目标只做局部代码风格 review。
- findings 优先级高于摘要；先报行为回归、正确性 bug、遗漏的错误处理、测试缺口、迁移/兼容风险，再谈实现是否优雅。
- 先查真相源和控制面是否收口：同一能力如果同时被 deterministic command、tool、worker 内部 helper 使用，默认应该共用一条控制链路，不要各自维护一份 orchestration。
- review 时主动检查有没有新增重复状态或平行抽象；能复用现有主链和最小状态模型时，不要接受“再加一层小系统”式实现。
- 涉及 surface/filter/allowlist 的改动，要同时检查定义侧、运行时选择侧和测试侧是否一致；不要只看 tool registry 里的列表，不看 runner/runtime 是否会泄漏额外能力。
- 对外或 phase 已冻结的接口，review 时要检查实现、调用点、文档、测试是否仍然对齐同一 contract；不要出现“内部其实已经换了 shape，但文档和测试没跟上”。
- 验收前至少确认关键 contract 测试覆盖到主成功路径和主中断路径；只跑 happy path 不足以证明控制链路正确。

## 架构与分层

改代码前先判断你在改哪一层：

- `SOUL`：人格、价值观、风格
- `USER`：用户画像、偏好、协作方式
- `MEMORY`：长期事实
- `SKILL`：可复用工作流
- `TOOL`：确定性能力
- `CODE`：框架内部实现

不要跨层乱写。`TOOLS.md` 不是工具真相源；workspace custom tool 也不是 framework code layer。

### 真相源原则

- 配置、prompt、tool definitions、skills 可见性不要各处自己读一份
- 长期进程 state 只放必要状态，不要顺手缓存整套 runtime world view
- 涉及 workspace 路径时优先复用 `Nex.Agent.Workspace`
- 能靠统一入口读到的数据，不要再新增一套平行读取逻辑
- 配置项必须接到统一入口：优先走 `Nex.Agent.Runtime` snapshot、`Nex.Agent.Config` accessor、现有 workspace/prompt resolver；不要在业务模块里自己 `File.read` 配置文件或 runtime 文件
- 配置规范化放在真相源附近做；像 token 前缀、allowlist 清洗这类逻辑优先放进 `Nex.Agent.Config` 或统一 resolver，不要散落在 channel / worker 里各写一份

### 架构约束

- 这是长期运行的 OTP agent，不是一次性脚本
- `Gateway` / channel / worker / registry / session / memory 都是系统边界，不要随便串层
- channel 特有协议留在 channel 模块里消化，不要把 Feishu/Telegram 细节散到通用层
- provider 差异收敛在 `llm/provider_profile.ex` 和 `llm/req_llm.ex`
- 改连接相关配置项时，要同时检查 runtime reload / `Gateway.reconcile/1` 是否已经接上；token、endpoint、开关等会影响连接的字段不能只改 init path，不改热重载

## 编码风格

- 公共接口写清 `@spec`，复杂模块写清职责边界
- 函数过长就拆 helper，避免一个函数同时做解析、分支、IO、状态回写、广播
- 错误返回要可操作，失败语义要明确
- 写日志记录关键状态和耗时，不打印敏感明文
- 延续当前代码风格，不要引入另一套完全不同的写法体系
- HTTP 请求优先走 `Nex.Agent.HTTP`，WebSocket 连接优先走项目内抽象如 `Nex.Agent.WS`；不要在功能代码里直接裸用 `Req` / `Mint` / `WebSockex`，除非你在补底层抽象本身

## 常见踩坑

- 不要把 `Config.load/0` 式的分散读取再复制到新模块
- 不要把 skill 做成隐藏代码执行器；代码能力应该做成 tool
- 不要只看 `definitions(:all)`；新增 tool 要考虑 `:subagent` / `:cron` surface
- 不要让写文件后的失败把仓库留在半坏状态；需要回滚就回滚
- 不要为了省事把临时实现写成长期 contract
- 不要因为局部修 bug 就绕过现有抽象直接裸读文件、裸发 HTTP、裸起 WS；先找 repo 里已有入口，不够用就补抽象
- 不要只让“冷启动能工作”；凡是配置会影响长期进程行为，都要确认热重载后旧进程会不会自动重连、重启或刷新状态

## 测试

- 先补 contract 测试，再补实现细节测试
- 用临时 workspace / 临时 config 做隔离测试，不依赖本机现有状态
- 改了冻结边界、主线架构或执行方式，记得同步 `docs/dev/*`

## 动手前自检

1. 我改的是哪一层？
2. 真相源在哪里？
3. 这次改动会不会新增重复状态或破坏一致性？
4. 失败时怎么回滚、保持旧值或重建？
5. 最窄的有效验证是什么？

## docs/dev 使用规范

仓库内 `docs/dev/` 是工程执行的真相源，分三个子目录。

### progress/

每日执行记录。

- **什么时候读**：接手工作时先读 `CURRENT.md`，了解当前主线、下一步、验证命令。
- **什么时候写**：当日有实质性推进时写 `YYYY-MM-DD.md`。记录做了什么、踩了什么坑、最终结论。
- `CURRENT.md` 在 phase 状态变更时同步更新。
- 不要写成 changelog 或散文；只保留后续执行者需要的最小上下文。

### findings/

架构判断和技术发现。

- **什么时候读**：排查问题、做架构决策、或开新 phase 前读相关 findings，了解"为什么这样做"。
- **什么时候写**：发现了影响架构方向的技术结论时写。命名格式 `YYYY-MM-DD-<topic>.md`。
- 不是 bug 记录，是决策依据。写清结论和约束，不写探索过程流水账。

### task-plan/

Phase 执行计划。每个 phase 一个文件。

- **什么时候读**：开工前读，确认边界、冻结项、stage 顺序、验收条件。
- **什么时候写**：开新 phase 或 phase 方向发生重大变更时写。已关闭的 phase 不再修改。
- 格式要求见下方。

### task-plan 格式规范

每个 task-plan 文件必须包含以下结构：

```markdown
# Phase N <标题>

## 当前状态
当前代码里是什么样的，有什么问题。

## 完成后必须达到的结果
phase 结束时仓库必须满足的硬条件。不写愿景，只写可验证的结果。

## 开工前必须先看的代码路径
列出文件路径。执行者开工前必须先读这些文件。

## 固定边界 / 已冻结的数据结构与 contract
编号列出所有冻结项。包括：
- 不改什么
- 数据结构最小 shape（附代码）
- 接口签名
- 行为 contract

## 执行顺序 / stage 依赖
列出 stage 名称和依赖关系。

## Stage N
每个 stage 必须包含：
### 前置检查
开始前必须确认的条件。
### 这一步改哪里
列出要新增、更新、删除的文件路径。
### 这一步要做
具体执行内容。关键代码直接给伪代码或 shape。
### 实施注意事项
不允许做什么，容易踩什么坑。
### 本 stage 验收
reviewer 怎么判断这一步做完了。
### 本 stage 验证
具体的 mix test 命令或人工检查项。

## Review Fail 条件
列出导致 phase 判定失败的具体情况。
```

关键原则：
- 每个 stage 必须有明确的文件路径、验收条件和验证命令
- 冻结的 struct/接口 直接给代码，不给自然语言描述
- 不写设计愿景散文；只写执行所需的最小信息
- 不允许出现"先绕过""兼容保留""后续再说"这类模糊说法

## 已知测试基线

- 2026-04-16 在 phase1-before 基线 `cb06f0fbe14901d68b27187c288cf19f5b40f2e5`（`2311c99^`）上复现了以下 memory/consolidation 失败（stash 掉 phase3 后）。
- 基线命令：`mix test test/nex/agent/memory_rebuild_test.exs test/nex/agent/memory_updater_test.exs test/nex/agent/memory_consolidate_test.exs test/nex/agent/runner_evolution_test.exs`
- 基线结果：24 tests, 6 failures。
- 失败范围：`MemoryRebuildTest` prompt memory block 正则失败、`MemoryUpdaterTest` 同样的 prompt memory block 失败、`MemoryConsolidateTest` `already_running` 等待超时、`RunnerEvolutionTest` 异步 memory consolidation history 未更新。
- 除非这些失败的表现与该基线不同，或者任务明确针对 memory/consolidation 稳定性，否则不要将它们视为 phase3 streaming 回归。

## LLM API 约定

本项目使用 Anthropic 兼容 API（包括 kimi 等）。构造 LLM 请求选项时：

- **tool_choice** 必须使用 Anthropic 格式：`%{type: "tool", name: "tool_name"}`
- 不要使用 OpenAI 格式：`%{type: "function", function: %{name: "tool_name"}}`
- Anthropic 允许的 `type` 值：`auto`、`any`、`tool`、`none`

## Git 工作流

本仓库直接在 `main` 上开发。

- 除非用户明确要求分支或 PR 工作流，否则不要创建或切换到 feature/topic 分支。
- 用户要求 commit 或 push 但未指定分支时，在 `main` 上操作。
- 在本仓库中未经提示就切换分支视为错误，避免重犯。

## 本机环境

- Elixir/Erlang 通过 Homebrew 安装；在 Codex/沙箱环境里优先用 `/Users/krisxin/.local/bin/mise exec -- mix ...`，不要假设 `mix` 在 PATH 中
- 需要直接跑 gateway 或 compile 时，优先使用：
  - `/Users/krisxin/.local/bin/mise exec -- mix compile`
  - `/Users/krisxin/.local/bin/mise exec -- mix nex.agent gateway --log`
- 配置文件在 `~/.nex/agent/config.json`（安全禁区，不可读写）
- Gateway 日志输出到 `/tmp/nex-agent-gateway.log`

常用命令：

```bash
# 编译
/Users/krisxin/.local/bin/mise exec -- mix compile

# 跑测试
mix test test/nex/agent/channel_feishu_test.exs
mix test test/nex/agent/channel_discord_test.exs
mix test test/nex/agent/inbound_worker_test.exs

# 启动 gateway（后台）
cd /Users/krisxin/nex-agent
MIX_ENV=dev /Users/krisxin/.local/bin/mise exec -- mix nex.agent gateway --log > /tmp/nex-agent-gateway.log 2>&1 &

# 看日志
tail -f /tmp/nex-agent-gateway.log
```

## 网关重启

用户要求快速重启网关时：

1. 先 `pkill -f "mix nex.agent gateway"`。
2. 等 3 秒让 socket 和 channel 连接干净断开。
3. 在后台启动新网关，不要用 `nohup`。
4. 将启动输出镜像到 `/tmp/nex-agent-gateway.log`。
5. 如果启动需要访问 `~/.nex/agent` 或其他沙箱外路径，立即上报而不是反复重试。

```bash
pkill -f "mix nex.agent gateway" 2>/dev/null; sleep 3
cd /Users/krisxin/nex-agent && MIX_ENV=dev /Users/krisxin/.local/bin/mise exec -- mix nex.agent gateway --log > /tmp/nex-agent-gateway.log 2>&1 &
sleep 6; tail -5 /tmp/nex-agent-gateway.log
```
