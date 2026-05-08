# Hindsight Memory Plugin

这份文档是 Hindsight 的补充说明。插件系统的主设计以 `docs/dev/designs/2026-05-07-plugin-runtime-extension-primitives.md` 为准。

## 定位

Hindsight 是 NexAgent 默认必须接入的 memory 插件。

它不是 core 里的特殊 backend，也不是另一个平行记忆系统。它通过普通插件能力进入 runtime：

```text
Hindsight MCP
  -> hindsight__recall / hindsight__retain / hindsight__mental_model tools
  -> prompt hook 注入相关记忆
  -> turn finished hook 触发 retain job
  -> PermissionRule 控制网络、文件和工具调用
  -> ControlPlane 记录状态和失败
```

NexAgent 仍然保留本地 session、workspace 文件、channel 补收和 ControlPlane 作为原始事实来源。Hindsight 保存的是整理后的长期记忆、mental model 和可检索索引。

## Bank 规则

Hindsight bank 必须有明确隔离规则，避免跨用户、跨 workspace 或跨项目污染。

默认目标：

```text
一个 workspace 对应一个 Hindsight bank
```

也可以配置为按 user、project、channel scope 做更细隔离，但不能让模型临场自由猜 bank。

## Prompt 注入

Hindsight 给 prompt 加内容只能走 hook。

目标 hook：

```text
prompt.build.before
  -> 调 hindsight__recall 或 hindsight__mental_model
  -> 把结果裁剪成有标题、有来源、有长度限制的一段内容
  -> 交给 ContextBuilder 排版
```

ContextBuilder 不知道 Hindsight。它只渲染 hook 的结果。

## 自动保存

Hindsight 保存长期记忆不靠模型每次手动想起来。

目标流程：

```text
conversation.turn.finished
  -> enqueue hindsight.retain job
  -> job 构造 bounded summary 和 source pointer
  -> 调 hindsight__retain
  -> 记录 operation id
  -> 后台查询 operation 状态
```

retain 内容必须带 source pointer，方便以后回到本地 session、文件或 ControlPlane 查原始事实。

## 模型可见工具

Hindsight 插件暴露少量包装后的工具：

- `hindsight__recall`：查相关长期记忆。
- `hindsight__retain`：保存明确值得长期记住的内容。
- `hindsight__mental_model`：读取 Hindsight 维护的长期模型。
- `hindsight__operation_status`：查看后台操作状态。

破坏性 MCP 工具不直接暴露给普通 turn。需要删除、清空、重建 bank 时，必须进入 owner-approved 管理流程。

## 权限

Hindsight 至少涉及三类权限：

- 连接 Hindsight endpoint。
- 调 Hindsight MCP tools。
- 读写本地 `memory/hindsight/**` 状态文件。

这些权限只走统一 PermissionRule。插件 manifest 可以声明自己需要什么，但不自己判定 allow/deny。

## 本地文件

Hindsight 插件可以使用本地文件保存状态、缓存、导出和人工可读备份，例如：

```text
memory/hindsight/status.json
memory/hindsight/exports/
```

这些文件仍然是普通 workspace artifact。它们不是 Hindsight bank 本身，也不是新的外部对象系统。

## Skill

Hindsight skill 应教 agent：

- 用户问长期上下文、跨会话偏好、反复出现的模式时，先考虑 Hindsight。
- 需要原文、精确时间线或可审计证据时，回查本地 session、文件或 ControlPlane。
- 保存记忆时只保存稳定事实、确认过的偏好、长期决策和可复用经验。
- 不保存密钥、临时输出、一次性中间状态和未经确认的猜测。
- recall 是取证据，mental model 是长期概括，reflect 类综合能力要谨慎使用。

## 成功状态

Hindsight 接入完成后，应满足：

- enabled plugin 后，Hindsight tools 出现在正确 surface。
- disabled plugin 后，Hindsight tools 不可见也不可执行。
- prompt 里的长期记忆来自 Hindsight hook。
- 一轮结束后会触发 retain job。
- retain、recall、operation polling 都有 ControlPlane 记录。
- 网络、工具、文件写入都能被 PermissionRule 解释和拦截。
- Hindsight 失败时，用户能看到明确诊断，runtime 不静默假装记忆正常。
