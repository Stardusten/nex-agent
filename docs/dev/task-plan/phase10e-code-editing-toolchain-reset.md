# Phase 10e Code Editing Toolchain Reset

## 当前状态

Phase 10d 把 CODE deploy 控制面收口到了 `self_update`，但 agent 真正“看代码、改代码、准备 deploy”的前半段工具链仍然不顺手：

- `read` 仍是弱文件读取器：虽然支持 `offset/limit`，但大文件依旧会在 100KB 处硬截断，没有 `has_more` / `next_offset` / `total_lines` 等 continuation 元信息。
- `edit` 只有单次 search/replace，适合很小的点改，不适合多 hunk、跨文件、上下文敏感修改。
- `write` 仍是整文件覆盖，要求 agent 先可靠拿到完整文件内容；这和大文件截断天然冲突。
- `list_dir` 只解决目录罗列，不解决代码搜索、符号定位、路径发现；agent 现在仍经常被迫退回 `bash` + `rg`.
- `reflect source` 更适合 module-first 的 CODE 层阅读，但 path-first 的文件工作流仍依赖旧 `read`.
- prompt/onboarding 还在向 agent 暴露一套“能用但不人体工学”的编辑工具面，导致 agent 可能先选难用路径，再在长文件或复杂改动处卡住。

这不是局部补洞能解决的问题。10e 的目标不是给 `read/edit/write` 再打几层补丁，而是直接把代码查看/编辑工具面重置成一套更接近 Codex 当前工作流的主链：**find -> read -> apply_patch -> verify -> self_update deploy**。

## 完成后必须达到的结果

1. 旧 `edit` / `write` tool 删除，不保留兼容垫片，不保留转发入口。
2. 新 `apply_patch` 成为唯一的通用代码编辑入口：支持多 hunk、增删改文件、上下文不匹配时报错，不直接激活 runtime。
3. `read` 升级为结构化读取工具：支持稳定分页、目录查看、文件 metadata、明确的 continuation 信息；不再用“截断了但 agent 不知道怎么继续”的返回形状。
4. 新 `find` 成为唯一的 repo 文本搜索工具，覆盖当前 agent 主要依赖 `bash rg` 做代码定位的主路径。
5. `list_dir` 若被新 `read` 覆盖则删除；若保留，必须有明确非重叠职责。默认目标是删除平行查看工具。
6. prompt / onboarding / tool descriptions 全部切换到新工具工作流，不再教 agent 使用 `edit/write`。
7. `self_update` 继续保持唯一 CODE runtime activation 入口；10e 只重做“看代码/改代码”工具面，不新增第二条 deploy 主链。
8. 所有旧测试和调用点直接迁移到新工具 contract；通过编译错误与测试失败驱动更新，不写兼容层。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/phase10-self-iteration-foundation.md`
- `docs/dev/task-plan/phase10d-self-update-deploy-control-plane.md`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/edit.ex`（将删除）
- `lib/nex/agent/tool/write.ex`（将删除）
- `lib/nex/agent/tool/list_dir.ex`（默认将删除）
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/tool_list.ex`
- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/write_edit_tool_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/code_layer_boundary_test.exs`
- `test/nex/agent/admin_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 旧工具删除冻结为：

```text
delete:
- edit
- write
- list_dir (unless executor can prove a truly non-overlapping role remains; default is delete)
```

不保留 alias、wrapper、deprecated description、shadow registration。

2. 新工具面冻结为：

```text
code inspection/editing mainline:
find -> read -> apply_patch -> self_update status/deploy
```

`bash` 仍可作为 escape hatch，但不再是代码定位/阅读的默认主路径。

3. 新 `read` tool 名字继续使用 `"read"`，但 contract 直接升级，不做兼容。

输入冻结为：

```elixir
%{
  "path" => String.t(),
  optional("start_line") => pos_integer(),
  optional("line_count") => pos_integer(),
  optional("max_bytes") => pos_integer(),
  optional("include_stat") => boolean(),
  optional("directory") => %{
    optional("depth") => non_neg_integer(),
    optional("limit") => pos_integer()
  }
}
```

返回冻结为结构化 map，不再直接返回裸字符串：

```elixir
%{
  status: :ok,
  path: String.t(),
  kind: :file | :directory,
  truncated: boolean(),
  has_more: boolean(),
  next_start_line: pos_integer() | nil,
  content: String.t() | nil,
  total_lines: non_neg_integer() | nil,
  entries: [map()] | nil,
  stat: %{
    size: non_neg_integer() | nil,
    mtime: String.t() | nil
  } | nil
}
```

要求：
- 文件读取必须返回 `truncated` / `has_more` / `next_start_line`。
- 目录读取必须返回稳定排序的 `entries`。
- 不允许继续使用“超过 100KB 就静默切掉一段文本”的旧 contract。

4. 新 `find` tool。

```elixir
def name, do: "find"
def category, do: :base
```

输入冻结为：

```elixir
%{
  "query" => String.t(),
  optional("path") => String.t(),
  optional("glob") => String.t(),
  optional("limit") => pos_integer()
}
```

返回冻结为：

```elixir
%{
  status: :ok,
  query: String.t(),
  matches: [
    %{
      path: String.t(),
      line: pos_integer(),
      column: pos_integer() | nil,
      preview: String.t()
    }
  ],
  truncated: boolean()
}
```

实现优先用项目内统一入口或受控 shell，不允许每个调用点自己拼一套搜索逻辑。

5. 新 `apply_patch` tool。

```elixir
def name, do: "apply_patch"
def category, do: :base
```

输入冻结为：

```elixir
%{
  "patch" => String.t()
}
```

`patch` 文本 grammar 冻结为与 Codex `apply_patch` 一致的 patch block：

```text
*** Begin Patch
*** Update File: path
@@
-old
+new
*** End Patch
```

允许：
- `Add File`
- `Delete File`
- `Update File`
- `Move to`

返回冻结为：

```elixir
%{
  status: :ok,
  updated_files: [String.t()],
  created_files: [String.t()],
  deleted_files: [String.t()]
}
```

失败必须返回明确 patch error，不允许静默部分成功。

6. 编辑行为冻结为：

```text
apply_patch -> writes disk only
read/find -> no runtime side effects
self_update deploy -> only runtime activation path
```

10e 不得重新引入“编辑时自动 hot reload”。

7. tool surface 冻结为：

- `:all` / `:base` / `:subagent` 可见：`read`, `find`, `apply_patch`
- `:follow_up` / `:cron` 不暴露 `apply_patch`
- `self_update` 仍不出现在 `:subagent` / `:follow_up` / `:cron`

8. prompt guidance 冻结为：

```text
discover code: find
inspect file/module: read / reflect
modify code: apply_patch
activate runtime changes: self_update deploy
```

不再教 agent 使用 `edit` / `write`。

## 执行顺序 / stage 依赖

- Stage 1：重置工具 contract，删除旧工具面，先让仓库进入“只有新工具主链”的单一目标状态。
- Stage 2：实现 `read` / `find` / `apply_patch`，收口到统一可用的查看/编辑工作流。
- Stage 3：迁移 prompt / onboarding / admin / tests，确保 agent 默认会走新工具主链。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  

## Stage 1

### 前置检查

- 读清当前 `read/edit/write/list_dir` 的参数形状、返回形状和测试。
- 确认 prompt/onboarding 里仍有哪些文案在教 agent 使用旧工具。
- 确认 `Registry` / `ToolList` / `tool_alignment_test` 对工具名和 surface 的依赖点完整。

### 这一步改哪里

- `lib/nex/agent/tool/edit.ex`（删除）
- `lib/nex/agent/tool/write.ex`（删除）
- `lib/nex/agent/tool/list_dir.ex`（默认删除）
- `lib/nex/agent/tool/read.ex`
- 新增 `lib/nex/agent/tool/find.ex`
- 新增 `lib/nex/agent/tool/apply_patch.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/tool_list.ex`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- 从 registry 删除旧 `edit/write`，默认一并删除 `list_dir`。
- 新增 `find` / `apply_patch` 注册。
- 直接改 `read` contract 到新结构化 shape。
- 让仓库先编译失败在“旧测试/旧调用点还没迁移”的地方，而不是用兼容层托住。

### 实施注意事项

- 不允许保留 `edit -> apply_patch` 或 `write -> apply_patch` 的转发层。
- 不允许 `read` 同时支持旧裸字符串和新结构化 map 两套返回。
- 不允许把 `apply_patch` 做成隐藏 shell 执行器；它必须是 deterministic file mutation tool。

### 本 stage 验收

- runtime tool surface 中不再有 `edit` / `write`。
- `find` / `apply_patch` 已进入 registry。
- 编译错误只剩调用点和测试还在使用旧 contract 的地方。

### 本 stage 验证

- `mix compile`
- `mix test test/nex/agent/tool_alignment_test.exs`

## Stage 2

### 前置检查

- Stage 1 已完成，旧工具面已删除。
- 新工具 contract 已冻结，不再回头补兼容参数。

### 这一步改哪里

- `lib/nex/agent/tool/read.ex`
- 新增 `lib/nex/agent/tool/find.ex`
- 新增 `lib/nex/agent/tool/apply_patch.ex`
- `lib/nex/agent/security.ex`（如果新 patch/write path 校验需要扩展统一入口）
- `test/nex/agent/write_edit_tool_test.exs`（重写或改名）
- 新增 `test/nex/agent/read_tool_test.exs`
- 新增 `test/nex/agent/find_tool_test.exs`
- 新增 `test/nex/agent/apply_patch_tool_test.exs`

### 这一步要做

- `read`
  - 支持文件分页、目录查看、stat 信息、明确 continuation。
  - 大文件读取时返回结构化 continuation，不再用旧截断字符串。
- `find`
  - 提供 repo 文本搜索主路径，结果带 path/line/preview。
  - 默认结果数受限，返回 `truncated`.
- `apply_patch`
  - 解析 patch block grammar。
  - 支持 add/update/delete/move。
  - 上下文不匹配时 fail-fast，不做局部 silent success。
- 所有写盘路径继续经过统一 path validation / security 入口。

### 实施注意事项

- 不要在 `apply_patch` 里直接触发 `HotReload` 或 `self_update`.
- 不要把目录读取和文本搜索再次拆成两套平行实现；如果 `read` 已覆盖目录查看，就别再补回 `list_dir`.
- patch parser 和 file writer 失败时，必须给出可操作错误，不能只返回 generic bad request。

### 本 stage 验收

- agent 可以用 `find -> read -> apply_patch` 完成一个典型代码修改工作流，不需要退回 `bash rg` 才能找代码。
- 长文件读取有 continuation 信息，agent 知道如何继续读。
- patch 多 hunk 修改和新建文件都能稳定工作。

### 本 stage 验证

- `mix test test/nex/agent/read_tool_test.exs`
- `mix test test/nex/agent/find_tool_test.exs`
- `mix test test/nex/agent/apply_patch_tool_test.exs`

## Stage 3

### 前置检查

- Stage 2 已完成，新工具本身可用。
- prompt / onboarding / admin / tests 仍至少有一处在教 agent 使用旧工具或假设旧返回形状。

### 这一步改哪里

- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/admin.ex`
- `console/src/pages/code.ex`
- `console/src/api/admin/panels/code.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/code_layer_boundary_test.exs`
- `docs/dev/task-plan/index.md`
- `docs/dev/progress/2026-04-24.md`

### 这一步要做

- prompt/onboarding 文案统一切换到：
  - 定位：`find`
  - 阅读：`read` / `reflect`
  - 修改：`apply_patch`
  - 激活：`self_update`
- admin / console 如果还依赖旧 `write` 式心智，统一改成 patch/diff 工作流，或降为只读。
- 更新测试，确保：
  - follow-up / subagent surface 不暴露不该暴露的编辑能力
  - 旧工具名不再出现在文案、tool list、alignment tests 里

### 实施注意事项

- 不允许 prompt 继续把 `bash` 当默认代码搜索器。
- 不允许 `reflect list_modules` 和新编辑工作流产生新的重复抽象；它只做 CODE 层 introspection，不做 patch 入口。
- 不允许 admin / console 保留旧“整块源码贴进去覆盖”的主要工作流而不改文案。

### 本 stage 验收

- agent 默认会走 `find -> read -> apply_patch -> self_update`。
- 仓库文档、prompt、tests、admin/console 全部对齐新工具面。
- reviewer 不再能在主链里找到 `edit` / `write` 旧入口或旧文案残留。

### 本 stage 验证

- `mix compile`
- `mix test test/nex/agent/admin_test.exs`
- `mix test test/nex/agent/tool_alignment_test.exs`
- `mix test test/nex/agent/code_layer_boundary_test.exs`

## Review Fail 条件

- 旧 `edit` / `write` 以 wrapper、alias、deprecated tool、文案兼容等任何形式保留在主链。
- `read` 继续返回裸字符串，或继续静默截断大文件却不给 continuation 信息。
- `apply_patch` 不是 deterministic patch tool，而是退化成任意 shell/file executor。
- 代码查看主路径仍然依赖 `bash rg`，而不是明确的 `find`.
- 编辑工具重新引入 runtime hot reload 或第二条 CODE activation 主链。
- prompt / onboarding / admin / tests 对工具心智仍不一致。
- tool surface 让 `apply_patch` 泄漏到 `:follow_up` / `:cron`，或让 `self_update` 泄漏到 `:subagent`.
