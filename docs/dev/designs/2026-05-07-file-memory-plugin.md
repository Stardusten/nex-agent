# File Memory Plugin

这份文档保留 file memory 的定位，但它不再是默认 memory 主线。插件系统和 Hindsight 的主设计以 `docs/dev/designs/2026-05-07-plugin-runtime-extension-primitives.md` 为准。

## 定位

Hindsight 是默认必须接入的 memory 插件。File memory 可以继续存在，但角色变成辅助：

- 本地人工可读备份。
- Hindsight 状态和导出的落盘位置。
- 没有网络或调试时的透明检查材料。
- agent 自己整理 workspace knowledge 的普通 Markdown 区域。

它不应该推动 core 增加 memory 专用接口。

## 目标形态

File memory 也是普通插件能力组合：

```text
workspace files
  memory/INDEX.md
  memory/INBOX.md

hooks
  prompt.build.before 读取 INDEX/INBOX 中需要常驻的部分

tools
  memory__write
  memory__read

skills
  memory-files/SKILL.md

permissions
  read/write workspace:memory/**
```

prompt 注入仍然走 hook。ContextBuilder 不直接读这些文件。

## 和 Hindsight 的关系

File memory 不替代 Hindsight。

两者自然分工：

- Hindsight 负责长期检索、retain、mental model。
- File memory 负责人能直接看的本地文件、导出、索引和调试材料。
- 如果同一条事实同时进入 Hindsight 和 file memory，必须有 source pointer，能追回本地原始会话或文件。

## 文件结构

推荐结构：

```text
memory/
  INDEX.md
  INBOX.md
  hindsight/
    status.json
    exports/
```

`INDEX.md` 是地图。`INBOX.md` 是未整理条目。`memory/hindsight/` 是 Hindsight 插件的状态、缓存或导出。

## 工具

File memory 可以提供两个清晰工具：

- `memory__write`：往 `memory/` 下追加或更新文件。
- `memory__read`：分页读取 `memory/` 下文件。

这两个工具的所有路径判断都走 PermissionRule 和 sandbox 文件授权。

## 成功状态

- 禁用 file memory 插件后，`memory__write` / `memory__read` 不可见也不可执行。
- `memory/INDEX.md` 或 `memory/INBOX.md` 进入 prompt 是 hook 的结果，不是 ContextBuilder 特判。
- 写文件失败不会留下半条内容。
- file memory 的存在不会让 Hindsight 变成可选项。
