# Phase 21 Command Sandbox And Approval

## 当前状态

`Nex.Agent.Sandbox.Security` 目前只保护直接文件工具的一部分路径访问。`read`、`find`、`apply_patch` 会做 allowed-roots 校验，但 `bash` 可以直接执行 shell 子进程绕过这些检查。`find`、external executor、stdio MCP server、self-update test runner 等生产路径也存在直接 `System.cmd` 或 `Port.open` 调用。

当前安全模型的问题：

- path permission 是工具局部逻辑，不是统一 permission contract。
- `bash` 依赖 brittle command blacklist/pattern，不能阻止 `cat secret`、`python -c`、`node` 等子进程读取文件。
- 子进程默认继承进程环境，存在泄漏 token/env 的风险。
- 没有统一 approval state，也没有 once/session/always grant 来降低重复弹窗。
- macOS sandbox 尚未接入，Linux/Windows 未来扩展接口也未冻结。

## 完成后必须达到的结果

1. 新增平台无关 `Nex.Agent.Sandbox.Policy`、`Command`、`Result`、`Exec`、`Backend` contract。
2. macOS 下新增 Seatbelt backend，使用固定 `/usr/bin/sandbox-exec` 包裹 child process，不通过 PATH 查找。
3. `bash` 不再直接 `Port.open(sh -c ...)`，必须通过 `Sandbox.Exec`，默认受到文件和网络 sandbox 限制。
4. `find` 的 `rg`、external executor、stdio MCP server 不再直接 `System.cmd` / `Port.open`，必须通过 `Sandbox.Exec` 的 completed-command 或 long-running stdio process contract，或者明确 reviewed exemption。
5. 所有 model/user-controllable 文件路径 IO 从 tool-local `File.*` / helper IO 迁移到 `Sandbox.FileSystem`，由 `Security.authorize_path/3` 做 canonical path、symlink-aware、deny-first 的统一 permission decision。
6. protected paths hard deny：
   - `~/.zshrc`
   - `~/.nex/agent/config.json`
7. 新增 deterministic approval state，支持：
   - allow once
   - allow exact command in this session
   - allow similar safe command family in this session
   - allow path operation in this session
   - always allow path operation
   - deny once / deny all pending
8. `/approve` / `/deny` approval control lane 绕过 busy queue，不进入 LLM。
9. Approval grants 有唯一真相源；session grants 在内存，always grants 持久化在 workspace。
10. Sandbox 和 approval 生命周期进入 ControlPlane observations。
11. Runtime config/snapshot 是 sandbox policy 的唯一配置入口；`tools.file_access.allowed_roots` 最终不能继续作为平行 truth source。
12. 所有核心 contract 有 focused tests 覆盖主成功路径和主中断/拒绝路径。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-04-30-command-sandbox-and-approval.md`
- `docs/dev/findings/2026-04-27-file-access-allowed-roots.md`
- `docs/dev/findings/2026-04-29-plugin-runtime-boundary.md`
- `lib/nex/agent/sandbox/security.ex`
- `lib/nex/agent/sandbox/filesystem.ex`
- `lib/nex/agent/capability/tool/core/bash.ex`
- `lib/nex/agent/capability/tool/core/find.ex`
- `lib/nex/agent/capability/tool/core/read.ex`
- `lib/nex/agent/capability/tool/core/apply_patch.ex`
- `lib/nex/agent/capability/tool/core/message.ex`
- `lib/nex/agent/capability/tool/core/reflect.ex`
- `lib/nex/agent/capability/tool/core/user_update.ex`
- `lib/nex/agent/capability/tool/core/soul_update.ex`
- `priv/plugins/builtin/tool.memory/lib/nex/agent/tool/memory_write.ex`
- `lib/nex/agent/knowledge/memory.ex`
- `priv/plugins/builtin/channel.feishu/lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/capability/executor.ex`
- `lib/nex/agent/interface/mcp.ex`
- `lib/nex/agent/turn/runner.ex`
- `lib/nex/agent/conversation/inbound_worker.ex`
- `lib/nex/agent/conversation/command/catalog.ex`
- `priv/plugins/builtin/command.core/nex.plugin.json`
- `lib/nex/agent/runtime/config.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/workspace.ex`
- `lib/nex/agent/observe/control_plane/log.ex`
- `test/nex/agent/bash_tool_test.exs`
- `test/nex/agent/find_tool_test.exs`
- `test/nex/agent/apply_patch_tool_test.exs`
- `test/nex/agent/tool_registry_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Sandbox policy struct：

```elixir
defmodule Nex.Agent.Sandbox.Policy do
  @type backend :: :auto | :seatbelt | :linux | :windows | :noop
  @type mode :: :read_only | :workspace_write | :danger_full_access | :external
  @type network :: :restricted | :enabled
  @type access :: :read | :write | :none
  @type path_ref ::
          {:path, String.t()}
          | {:special, :workspace | :minimal | :tmp | :slash_tmp}

  @type filesystem_entry :: %{
          required(:path) => path_ref(),
          required(:access) => access()
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          backend: backend(),
          mode: mode(),
          network: network(),
          filesystem: [filesystem_entry()],
          protected_paths: [String.t()],
          protected_names: [String.t()],
          env_allowlist: [String.t()],
          raw: map()
        }
end
```

2. Sandbox command/result structs：

```elixir
defmodule Nex.Agent.Sandbox.Command do
  @type t :: %__MODULE__{
          program: String.t(),
          args: [String.t()],
          cwd: String.t(),
          env: %{optional(String.t()) => String.t()},
          stdin: String.t() | nil,
          timeout_ms: pos_integer(),
          cancel_ref: reference() | nil,
          metadata: map()
        }
end

defmodule Nex.Agent.Sandbox.Result do
  @type status :: :ok | :exit | :timeout | :cancelled | :denied | :error
  @type t :: %__MODULE__{
          status: status(),
          exit_code: non_neg_integer() | nil,
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          sandbox: map(),
          error: String.t() | nil
        }
end
```

3. Backend behavior：

```elixir
defmodule Nex.Agent.Sandbox.Backend do
  @callback name() :: atom()
  @callback available?() :: boolean()
  @callback wrap(Nex.Agent.Sandbox.Command.t(), Nex.Agent.Sandbox.Policy.t()) ::
              {:ok, Nex.Agent.Sandbox.Command.t()} | {:error, term()}
end
```

4. Direct filesystem authority：

```elixir
defmodule Nex.Agent.Sandbox.FileSystem do
  @type operation :: :read | :write | :list | :search | :remove | :mkdir | :stat | :stream

  @spec authorize(Path.t(), operation(), map()) ::
          {:ok, map()} | {:ask, Nex.Agent.Sandbox.Approval.Request.t()} | {:error, term()}

  @spec read_file(Path.t(), map()) :: {:ok, binary()} | {:error, term()}
  @spec list_dir(Path.t(), map()) :: {:ok, [map()]} | {:error, term()}
  @spec stat(Path.t(), map()) :: {:ok, File.Stat.t()} | {:error, term()}
  @spec regular?(Path.t(), map()) :: {:ok, boolean()} | {:error, term()}
  @spec stream_file(Path.t(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  @spec write_file(Path.t(), iodata(), map()) :: :ok | {:error, term()}
  @spec mkdir_p(Path.t(), map()) :: :ok | {:error, term()}
  @spec remove(Path.t(), map()) :: :ok | {:error, term()}
end
```

No user-controlled path in a direct tool may call `File.*` directly once Stage 3 is complete.

5. `Sandbox.Exec.run/2` contract：

```elixir
@spec run(Nex.Agent.Sandbox.Command.t(), Nex.Agent.Sandbox.Policy.t()) ::
        {:ok, Nex.Agent.Sandbox.Result.t()} | {:error, Nex.Agent.Sandbox.Result.t()}
```

`Exec` owns timeout, cancellation, env filtering, output sanitization, and ControlPlane observations. Backend only wraps command.

6. Long-running sandbox process contract：

```elixir
defmodule Nex.Agent.Sandbox.Process do
  @type t :: %__MODULE__{
          id: String.t(),
          port: port(),
          command: Nex.Agent.Sandbox.Command.t(),
          policy: Nex.Agent.Sandbox.Policy.t(),
          sandbox: map()
        }

  @type event :: {:data, binary()} | :eof | {:exit_status, non_neg_integer()}
end

@spec Nex.Agent.Sandbox.Exec.open(Nex.Agent.Sandbox.Command.t(), Nex.Agent.Sandbox.Policy.t()) ::
        {:ok, Nex.Agent.Sandbox.Process.t()} | {:error, term()}

@spec Nex.Agent.Sandbox.Exec.write(Nex.Agent.Sandbox.Process.t(), iodata()) ::
        :ok | {:error, term()}

@spec Nex.Agent.Sandbox.Exec.close(Nex.Agent.Sandbox.Process.t()) :: :ok
```

`open/2` is required before MCP migration starts. It is the only contract stdio MCP may use for long-running bidirectional child processes.

7. macOS Seatbelt executable path freezes to:

```elixir
@seatbelt "/usr/bin/sandbox-exec"
```

Never use `System.find_executable("sandbox-exec")`.

8. `Security.authorize_path/3` contract：

```elixir
@spec authorize_path(String.t(), :read | :write | :list | :search, map()) ::
        {:ok, map()} | {:ask, Nex.Agent.Sandbox.Approval.Request.t()} | {:error, term()}
```

It must canonicalize the path before checking permission:

```elixir
%{
  input_path: String.t(),
  expanded_path: String.t(),
  canonical_path: String.t(),
  existing_ancestor: String.t(),
  existing_ancestor_realpath: String.t(),
  missing_suffix: [String.t()],
  target_exists?: boolean()
}
```

9. Hard denied paths:

```elixir
[
  Path.expand("~/.zshrc"),
  Path.expand("~/.nex/agent/config.json")
]
```

These paths cannot be read, written, listed, searched, or granted through approval.

10. Approval request struct：

```elixir
defmodule Nex.Agent.Sandbox.Approval.Request do
  @type t :: %__MODULE__{
          id: String.t(),
          workspace: String.t(),
          session_key: String.t(),
          channel: String.t() | nil,
          chat_id: String.t() | nil,
          kind: :path | :command | :mcp | :network,
          operation: atom(),
          subject: String.t(),
          description: String.t(),
          grant_key: String.t(),
          grant_options: [map()],
          metadata: map(),
          authorized_actor: map() | nil,
          requested_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          from: GenServer.from() | nil
        }
end
```

11. Approval result contract：

```elixir
{:ok, :approved}
| {:error, :denied}
| {:error, :timeout}
| {:error, {:cancelled, :new | :stop | :shutdown | atom()}}
| {:error, String.t()}
```

12. Grant shape：

```elixir
%{
  "kind" => "path" | "command" | "mcp" | "network",
  "operation" => String.t(),
  "subject" => String.t(),
  "grant_key" => String.t(),
  "scope" => "session" | "always",
  "created_at" => String.t()
}
```

13. Persistent grants file:

```text
<workspace>/permissions/grants.json
```

14. `Workspace.ensure!/1` must create `permissions/`.

15. Slash commands:

```text
/approve
/approve all
/approve session
/approve similar
/approve always
/deny
/deny all
```

No slash approval command may enter LLM or busy follow-up queue.

`/approve all` approves all currently pending approval requests for the current session once. It must not create session grants or always grants.

16. Command grant keys:

```elixir
%{
  exact_key: "command:execute:exact:<sha256>",
  family_key: "command:execute:family:<program>:<safe_family>",
  risk_key: "command:execute:risk:<risk_class>",
  risk_hint: String.t() | nil,
  requires_approval?: boolean()
}
```

`similar` may only use `family_key` when the command classifier marks the family safe for broad session grant.
High-risk shell forms such as command substitution, process substitution, shell escape, interpreter one-liners, and encoded shell pipelines must set `requires_approval?` and include a short `risk_hint`; sandbox default allow must not bypass that prompt.

17. The first implementation must not claim sandboxing for custom Elixir tools compiled into the BEAM VM.

18. `tools.file_access.allowed_roots` may be accepted as a migration input only. New code must normalize it into the sandbox runtime projection and consume only the sandbox projection afterward.

## 执行顺序 / stage 依赖

- Stage 1: Runtime sandbox config and pure policy structs.
- Stage 2: Approval GenServer, grant store, slash command control lane.
- Stage 3: Path authorization cutover for direct file tools.
- Stage 4: Sandbox Exec and macOS Seatbelt backend.
- Stage 5: Bash cutover to approval + sandbox execution.
- Stage 6: Migrate remaining child process call sites.
- Stage 7: Observability, prompt/docs, and final hardening.

Stage 2 depends on Stage 1.
Stage 3 depends on Stage 1 and Stage 2.
Stage 4 depends on Stage 1.
Stage 5 depends on Stage 2 and Stage 4.
Stage 6 depends on Stage 4.
Stage 7 depends on all earlier stages.

## Stage 1

### 前置检查

- Confirm no repo-local skill applies beyond normal docs/dev workflow.
- Confirm `docs/dev/designs/2026-04-30-command-sandbox-and-approval.md` is read.
- Confirm current `Config.file_access_allowed_roots/1` callers.

### 这一步改哪里

- `lib/nex/agent/runtime/config.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/sandbox/policy.ex` 新增
- `lib/nex/agent/sandbox/command.ex` 新增
- `lib/nex/agent/sandbox/result.ex` 新增
- `test/nex/agent/config_test.exs`
- `test/nex/agent/runtime_test.exs`
- 新增 `test/nex/agent/sandbox_policy_test.exs`

### 这一步要做

- 新增 sandbox config normalization：
  - `Config.sandbox_runtime/1`
  - normalize `tools.sandbox`
  - migrate `tools.file_access.allowed_roots` into read/write roots for runtime projection.
- `Runtime.Snapshot` 增加 `sandbox` projection。
- 新增 policy/command/result structs and constructors。
- Ensure protected paths are injected even when config omits them。
- Keep `tools.file_access.allowed_roots` accessor only as migration compatibility input, not as new call-site API.

### 实施注意事项

- 不要在 `Security`、`Bash`、`Find` 等业务模块里读取 raw config map。
- 不要把 Seatbelt-specific字段放进 public policy struct。
- 不要在 Stage 1 改 tool behavior。

### 本 stage 验收

- Runtime snapshot contains normalized sandbox policy.
- Protected paths are present in snapshot policy.
- Existing file_access allowed roots are represented in sandbox projection.
- No tool directly consumes raw `tools.sandbox`.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/config_test.exs test/nex/agent/runtime_test.exs test/nex/agent/sandbox_policy_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
```

## Stage 2

### 前置检查

- Stage 1 snapshot sandbox projection is available.
- Confirm `InboundWorker` command path can bypass busy queue for existing deterministic commands.
- Confirm outbound publish path for current channel/chat.

### 这一步改哪里

- `lib/nex/agent/sandbox/approval.ex` 新增
- `lib/nex/agent/sandbox/approval/request.ex` 新增
- `lib/nex/agent/sandbox/approval/grant.ex` 新增
- `lib/nex/agent/sandbox/permission.ex` 新增
- `lib/nex/agent/app/infrastructure_supervisor.ex`
- `lib/nex/agent/runtime/workspace.ex`
- `lib/nex/agent/conversation/command/catalog.ex`
- `lib/nex/agent/conversation/command/parser.ex`
- `lib/nex/agent/conversation/inbound_worker.ex`
- `priv/plugins/builtin/command.core/nex.plugin.json`
- `test/nex/agent/command_catalog_test.exs`
- 新增 `test/nex/agent/command_parser_test.exs`
- 新增 `test/nex/agent/sandbox_approval_test.exs`
- 新增 `test/nex/agent/sandbox_approval_command_test.exs`

### 这一步要做

- Add `Nex.Agent.Sandbox.Approval` GenServer.
- State shape:
  - `pending_by_session`
  - `pending_by_id`
  - `session_grants`
  - `always_grants`
- Load/save `<workspace>/permissions/grants.json`.
- Implement:
  - `request/1`
  - `approve/4`
  - `deny/3`
  - `pending?/2`
  - `approved?/3`
  - `grant_session/3`
  - `grant_always/2`
  - `cancel_pending/4`
  - `clear_session_grants/2`
  - `reset_session/3`
- Add slash parsing and deterministic handlers for `/approve` and `/deny`.
- Add `approve` and `deny` command contributions to `builtin:command.core`.
- Extend the command catalog bounded handler table and handler order for `approve` and `deny`.
- Add deterministic `InboundWorker` dispatch cases for `approve` and `deny`.
- `/approve all` resolves all current-session pending requests as once approvals with no session/always grant side effect.
- `/new` must reset session approval state.
- `/stop` must cancel pending approvals without clearing session grants.

### 实施注意事项

- Approval request must publish outbound text directly through Bus/channel path, not through `message` tool.
- No approval command may call LLM.
- Pending queue must be FIFO.
- Do not persist session grants.
- Do not store sensitive command output or env in grant file.

### 本 stage 验收

- Pending approval can be approved once and resumes caller.
- `/approve session` creates session grant and suppresses repeated request.
- `/approve always` persists grant and works in a new session.
- `/approve all` approves all current-session pending requests once and creates no grants.
- `/deny` resumes caller with denial.
- `/deny all` resolves all current session pending requests.
- Busy session approval bypass works.
- `/commands` lists `/approve` and `/deny` from the plugin contribution.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/sandbox_approval_test.exs test/nex/agent/sandbox_approval_command_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/command_catalog_test.exs test/nex/agent/command_parser_test.exs test/nex/agent/inbound_worker_test.exs
```

## Stage 3

### 前置检查

- Stage 2 approval state can block and resume tool execution.
- Confirm direct file tool call contexts include `workspace`, `runtime_snapshot`, `config`, `session_key`, `channel`, and `chat_id` when interactive.
- Run the direct file IO inventory command and classify every production hit as migrated, workspace-internal reviewed exemption, or not in scope.

### 这一步改哪里

- `lib/nex/agent/sandbox/security.ex`
- `lib/nex/agent/sandbox/filesystem.ex` 新增
- `lib/nex/agent/capability/tool/core/read.ex`
- `lib/nex/agent/capability/tool/core/find.ex`
- `lib/nex/agent/capability/tool/core/apply_patch.ex`
- `lib/nex/agent/capability/tool/core/message.ex`
- `lib/nex/agent/capability/tool/core/reflect.ex`
- `lib/nex/agent/capability/tool/core/user_update.ex`
- `lib/nex/agent/capability/tool/core/soul_update.ex`
- `priv/plugins/builtin/tool.memory/lib/nex/agent/tool/memory_write.ex`
- `priv/plugins/builtin/tool.memory/lib/nex/agent/tool/memory_rebuild.ex`
- `lib/nex/agent/knowledge/memory.ex`
- `priv/plugins/builtin/channel.feishu/lib/nex/agent/channel/feishu.ex`
- `test/nex/agent/read_tool_test.exs`
- `test/nex/agent/find_tool_test.exs`
- `test/nex/agent/apply_patch_tool_test.exs`
- `test/nex/agent/message_tool_test.exs`
- `test/nex/agent/reflect_tool_test.exs`
- memory/user/soul tool tests if present, otherwise add focused tests
- 新增 `test/nex/agent/sandbox_path_permission_test.exs`
- 新增 `test/nex/agent/sandbox_file_io_inventory_test.exs`
- `test/nex/agent/profile_path_guard_test.exs`

### 这一步要做

- Add `Security.authorize_path/3`.
- Add `Sandbox.FileSystem` as the only public filesystem authority for user/tool controlled paths.
- Implement canonical path info for existing and missing targets.
- Existing `validate_path/2` and `validate_write_path/2` should either delegate to `authorize_path/3` with non-interactive behavior or be deleted after callers migrate.
- Build and commit a production direct-file inventory from:
  - `lib/nex/agent/capability/tool/core/**/*.ex`
  - `priv/plugins/builtin/tool.*/lib/**/*.ex`
  - channel upload paths that consume model-provided attachment local paths
  - workspace/user-facing HTTP or bridge file surfaces
- Migrate model/user-controllable file IO so actual IO uses `Sandbox.FileSystem`, not direct `File.*`:
  - `read`: `read_file/2` and `list_dir/2`
  - `find`: scope authorization through `authorize/3`; `rg` process migration happens in Stage 6
  - `apply_patch`: all original-file reads, writes, removes, and moves through `Sandbox.FileSystem`
  - `message`: `attachment_path`, `attachment_paths`, and `local_image_path` use `Sandbox.FileSystem.stat/2` or `read_file/2`; outbound channel upload must consume an authorized attachment or a `Sandbox.FileSystem.stream_file/2` result, not re-open arbitrary model-provided paths unchecked.
  - `reflect source path`: protected path and out-of-policy checks happen before any `File.exists?` / source read so existence is not leaked.
  - `user_update`, `soul_update`, `memory_write`, and memory rebuild storage writes route through `Sandbox.FileSystem` or receive a narrow workspace-internal exemption with tests proving hard-denied paths cannot be targeted.
- Hard deny protected paths before approval.
- Out-of-policy path in interactive ctx creates approval request.
- Out-of-policy path without interactive ctx returns actionable error.

### 实施注意事项

- Deny wins over allow and approval.
- Path checks must be path-boundary aware.
- Symlink target must be checked.
- Missing write target must use nearest existing ancestor realpath.
- Do not widen workspace semantics; extra allowed roots are file access roots, not additional workspaces.
- Keep the `Sandbox.FileSystem` boundary shaped so a future sandboxed helper can replace in-process `File.*` without changing tool modules.

### 本 stage 验收

- Direct file tools cannot access protected paths.
- Read/search/write under allowed roots works.
- Read/search/write outside allowed roots asks for approval in interactive ctx.
- Symlink escape to outside root asks or denies.
- `/approve session` suppresses repeated path prompt for the same grant key.
- `message` cannot send a hard-denied path as `attachment_path`, `attachment_paths`, or `local_image_path`.
- `reflect source path` does not leak existence of hard-denied paths.
- `user_update`, `soul_update`, `memory_write`, and memory rebuild cannot target hard-denied paths through workspace/config manipulation.
- Inventory test fails on new model-visible file path IO unless the call site uses `Sandbox.FileSystem` or is listed as a reviewed workspace-internal exemption.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/read_tool_test.exs test/nex/agent/find_tool_test.exs test/nex/agent/apply_patch_tool_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/message_tool_test.exs test/nex/agent/reflect_tool_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/sandbox_path_permission_test.exs test/nex/agent/sandbox_file_io_inventory_test.exs test/nex/agent/profile_path_guard_test.exs
rg -n "File\\.|File\\.read|File\\.write|File\\.rm|File\\.ls|File\\.stat|File\\.stream!" lib/nex/agent/capability/tool/core priv/plugins/builtin/tool.* priv/plugins/builtin/channel.* -g "*.ex"
```

## Stage 4

### 前置检查

- Stage 1 policy structs exist.
- macOS host has `/usr/bin/sandbox-exec`; non-macOS tests must skip Seatbelt-specific assertions.

### 这一步改哪里

- `lib/nex/agent/sandbox/exec.ex` 新增
- `lib/nex/agent/sandbox/process.ex` 新增
- `lib/nex/agent/sandbox/backend.ex` 新增
- `lib/nex/agent/sandbox/backends/noop.ex` 新增
- `lib/nex/agent/sandbox/backends/seatbelt.ex` 新增
- 新增 `test/nex/agent/sandbox_exec_test.exs`
- 新增 `test/nex/agent/sandbox_process_test.exs`
- 新增 `test/nex/agent/sandbox_seatbelt_test.exs`

### 这一步要做

- Implement `Sandbox.Exec.run/2` with:
  - env filtering
  - stdin support
  - timeout
  - cancellation
  - bounded output sanitization
  - ControlPlane observations
- Implement `Sandbox.Exec.open/2`, `write/2`, and `close/1` for long-running stdio processes.
- Implement `Seatbelt.wrap/2`.
- Generate SBPL from policy:
  - closed by default
  - process fork/exec allowed
  - read roots
  - write roots
  - protected deny rules
  - restricted network default
  - minimal macOS platform read rules required for shell execution
- Implement `Noop` only for explicit `:danger_full_access` / `:external` policy or tests.

### 实施注意事项

- Never use PATH lookup for `sandbox-exec`.
- Do not pass full parent env.
- Do not log full env.
- Keep backend wrapping separate from process execution.
- If sandbox is enabled and no backend is available, fail closed.

### 本 stage 验收

- Seatbelt allows basic command execution.
- Seatbelt permits write inside writable root.
- Seatbelt blocks write outside writable root.
- Seatbelt blocks read of protected/denied path.
- Restricted network blocks outbound command.
- Timeout and cancellation terminate the child process.
- `Sandbox.Exec.open/2` can start a sandboxed bidirectional stdio process, write JSON lines, receive data/eof/exit events, and close cleanly.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/sandbox_exec_test.exs test/nex/agent/sandbox_process_test.exs test/nex/agent/sandbox_seatbelt_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
```

## Stage 5

### 前置检查

- Stage 2 approval works.
- Stage 4 sandbox exec works on macOS.
- Existing `bash_tool_test` timeout/cancellation expectations are understood.

### 这一步改哪里

- `lib/nex/agent/capability/tool/core/bash.ex`
- `lib/nex/agent/sandbox/permission.ex`
- 新增 `lib/nex/agent/sandbox/command_classifier.ex`
- `test/nex/agent/bash_tool_test.exs`
- 新增 `test/nex/agent/sandbox_bash_permission_test.exs`
- `test/nex/agent/tool_registry_test.exs`

### 这一步要做

- Replace direct `Port.open(sh -c ...)` with `Sandbox.Exec.run/2`.
- Keep shell command UX, but execute through configured shell under sandbox.
- Add command classifier:
  - exact key for every command
  - safe family key for known safe families
  - risk class, risk hint, and force-approval flag for high-risk command forms
- `Security.validate_command/1` stops only hard-deny commands.
- Approval required commands call `Approval.request/1`.
- Similar/session options only offered for safe families.
- Return bash output/error in existing tool-compatible shape.

### 实施注意事项

- Do not rely on command classifier as the sandbox boundary.
- Complex shell commands should not get broad similar grants in first version.
- Preserve cancellation through `cancel_ref`.
- Do not let `sandbox_permissions` style arbitrary escalation enter tool args.

### 本 stage 验收

- Bash cannot read/write denied paths even if command string tries.
- Bash can run allowed local test commands after approval.
- `/approve once` runs only current command.
- `/approve session` suppresses exact repeated command.
- `/approve similar` suppresses safe family repeated command.
- Denied command returns actionable error.
- Timeout and `/stop` still cancel bash.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/bash_tool_test.exs test/nex/agent/sandbox_bash_permission_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_registry_test.exs
```

## Stage 6

### 前置检查

- Stage 4 `Sandbox.Exec` is stable.
- Stage 5 bash cutover is green.
- Search all production `System.cmd` and `Port.open` call sites.

### 这一步改哪里

- `lib/nex/agent/capability/tool/core/find.ex`
- `lib/nex/agent/capability/executor.ex`
- `lib/nex/agent/interface/mcp.ex`
- `lib/nex/agent/self/update/deployer.ex`
- `lib/nex/agent/self/update/planner.ex` if not explicitly exempted
- `lib/nex/agent/knowledge/project_memory.ex` if not explicitly exempted
- `lib/nex/agent/turn/context_builder.ex` if not explicitly exempted
- `test/nex/agent/find_tool_test.exs`
- `test/nex/agent/executor_test.exs`
- MCP tests if present or newly added
- self-update tests if deployer command execution is migrated

### 这一步要做

- `find` uses `Sandbox.Exec` for `rg`.
- external executor uses `Sandbox.Exec`.
- stdio MCP server start uses `Sandbox.Exec.open/2`; `Port.open` is not called directly from MCP.
- self-update test command execution either migrates to `Sandbox.Exec` or receives explicit reviewed exemption in code comments/tests.
- Internal read-only git probes either migrate or are documented in a direct-command allowlist test.

### 实施注意事项

- MCP child process is long-running; do not start Stage 6 until Stage 4 `Sandbox.Exec.open/2` is implemented and tested.
- Do not break MCP stdio JSON framing.
- external executor stdin prompt file must not leak prompt after timeout/cancel.
- Avoid broad network enablement for external executors unless config says so.

### 本 stage 验收

- User/tool-triggered child processes no longer bypass sandbox.
- MCP stdio server runs under sandbox on macOS.
- `find` behavior remains structured and paginated.
- External executor records still persist runs.
- Reviewed exemptions are narrow and tested.

### 本 stage 验证

```bash
rg -n "System\\.cmd|Port\\.open|:os\\.cmd" lib priv/plugins/builtin -g '*.ex'
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/find_tool_test.exs test/nex/agent/executor_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/self_update_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
```

## Stage 7

### 前置检查

- Stages 1-6 pass focused tests.
- Confirm prompt/onboarding mentions old brittle path checks or unsafe bash guidance.

### 这一步改哪里

- `lib/nex/agent/turn/context_builder.ex`
- `lib/nex/agent/capability/tool/core/tool_list.ex`
- `docs/dev/progress/CURRENT.md`
- `README.md` if security section exists
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/control_plane_logger_cutover_test.exs` if observation allowlist changes

### 这一步要做

- Add ControlPlane observations for sandbox exec and approval lifecycle.
- Update tool descriptions for bash/find to mention sandbox and approvals.
- Update prompt guidance:
  - use `find/read/apply_patch` for code work
  - bash is sandboxed and may ask for approval
  - approvals can be once/session/similar/always depending on request
- Add docs for config shape and security model.
- Run final direct-command grep and document reviewed exceptions.

### 实施注意事项

- Do not include sensitive paths or command output in observations.
- Do not teach the model to ask the user in prose for approval; it must rely on deterministic approval requests.
- Do not make `auto_allow_sandboxed_bash` default true in this phase.

### 本 stage 验收

- User-facing tool docs and prompt align with implementation.
- ControlPlane can answer recent sandbox denials/approvals.
- No unreviewed child process execution remains in production code.
- Current `docs/dev/progress/CURRENT.md` names Phase 21 status and verification commands.

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/bash_tool_test.exs test/nex/agent/find_tool_test.exs test/nex/agent/apply_patch_tool_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
git diff --check
```

## Review Fail 条件

- `bash` 或 user/tool-triggered external executor 仍能绕过 sandbox 读取/写入 denied path。
- `read`、`apply_patch` 或 future file-like tools 仍在 tool 模块里对 user-controlled path 裸用 `File.*`。
- `message` attachments、`reflect source path`、memory/user/soul file-like tools 或 channel upload path 能绕过 `Sandbox.FileSystem` 访问 hard-denied path。
- `sandbox-exec` 通过 PATH 查找，而不是固定 `/usr/bin/sandbox-exec`。
- Runtime config、tool、runner、executor、MCP 各自解析 sandbox config，形成多个 truth source。
- `tools.file_access.allowed_roots` 继续作为新调用点直接消费的主 contract。
- protected paths 可以通过 direct tool、bash、find、executor、MCP 任一路径访问。
- `/approve` 或 `/deny` 没有从 `builtin:command.core` plugin contribution 进入 `Command.Catalog` 和 `/commands`。
- Approval pending state、session grants、always grants 被拆成多个平行状态源。
- `/approve` / `/deny` 进入 busy queue 或 LLM。
- `/approve all` 创建 session/always grant，或没有一次性批准当前 session 所有 pending request 的测试。
- `allow similar` 对复杂 shell、download-execute、destructive delete、unknown risk command 给出 broad session grant。
- MCP stdio 仍直接 `Port.open` 或迫使 Stage 6 修改已经冻结的 Exec contract。
- 子进程继承完整 parent env。
- ControlPlane observations 记录完整 env、敏感 path 内容、完整 stdout/stderr 或 secret-bearing command。
- Linux/Windows future backend 需要修改 bash/find/executor/MCP 调用方才能接入。
- 为了通过中间编译添加旧 API 兼容垫片，而不是迁移调用点。
