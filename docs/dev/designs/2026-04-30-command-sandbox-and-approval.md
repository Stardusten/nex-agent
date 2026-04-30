# 2026-04-30 Command Sandbox And Approval

## 背景

当前 NexAgent 已经有 `Nex.Agent.Sandbox.Security`，但它主要保护直接文件工具：

- `read` 用 `Security.validate_path/2`。
- `find` 用 `Security.validate_path/2` 后直接 `System.cmd(rg ...)`。
- `apply_patch` 用 `Security.validate_write_path/2`。
- `bash` 只做命令黑名单和 pattern 拦截，然后直接 `Port.open(sh -c ...)`。

这不是可靠沙盒。只要 `bash` 能执行 `cat`、`sed`、`python`、`node`、`git` 或任意子进程，工具层路径授权就能被绕过。Claude Code 官方权限文档也明确指出：Read/Edit deny 规则不阻止 Bash 子进程，必须启用 OS sandbox 才能挡住 `cat .env` 这类绕过；权限规则和 sandbox 是互补层，不是替代关系。

本设计目标是把 NexAgent 的安全边界从“工具内字符串检查”升级为：

```text
Permission decision layer + OS sandbox execution layer
```

第一版只实现 macOS Seatbelt backend，但接口必须能自然扩展到 Linux 和 Windows。

## 外部参考

- Codex macOS 实现使用固定路径 `/usr/bin/sandbox-exec`，动态生成 Seatbelt profile，并用 `-DKEY=path` 参数传入可读/可写 root，避免依赖 PATH 中的可疑 `sandbox-exec`。
- Codex 的模型是通用 permission profile 先被解析成 runtime filesystem/network policy，再由平台 backend 转成 Seatbelt、Linux sandbox 或 Windows sandbox。
- Codex 的 `apply_patch` 不是裸写文件：handler 先计算 patch 涉及的路径和 additional permissions，然后 runtime 调用 `codex_apply_patch::apply_patch(..., fs, sandbox)`；`fs` 是 `ExecutorFileSystem`，`sandbox` 是 `FileSystemSandboxContext`。本地环境在需要 sandbox 时会通过 filesystem helper 子进程执行实际读写，再由 `SandboxManager` 包到平台 sandbox 里。
- Codex 当前开源主线没有和 NexAgent 完全同构的通用 `read` / `write` 工具；`list_dir` 这类只读 helper 仍有直接 in-process 读目录实现，只用 read-deny policy 过滤。因此不能把 Codex 理解成“所有 direct read 都被 Seatbelt 自动保护”，更准确的结论是：direct file operation 必须有统一 filesystem authority，不能散落裸 `File.*`。
- Claude Code 的安全模型把权限规则、审批、sandbox 分开：
  - permissions 决定工具/文件/域名是否允许、询问或拒绝；
  - sandbox 对 Bash 及其 child processes 做 OS 层文件和网络限制；
  - 用户可以批准一次，也可以把常用安全 action allowlist 到当前 session 或配置里，以减少 prompt fatigue。

参考链接：

- https://github.com/openai/codex/blob/main/codex-rs/sandboxing/src/seatbelt.rs
- https://github.com/openai/codex/blob/main/codex-rs/sandboxing/src/manager.rs
- https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/runtimes/apply_patch.rs
- https://github.com/openai/codex/blob/main/codex-rs/file-system/src/lib.rs
- https://github.com/openai/codex/blob/main/codex-rs/exec-server/src/sandboxed_file_system.rs
- https://code.claude.com/docs/en/permissions
- https://code.claude.com/docs/en/permission-modes
- https://code.claude.com/docs/en/security

## 设计原则

1. `Runtime.Snapshot` 仍是长期进程世界观。
   - sandbox config 只能从 `Nex.Agent.Runtime.Config` 规范化后进入 snapshot。
   - tool、runner、executor、MCP 不得自己读 config 文件。

2. `Security` 不再只是 path helper。
   - 直接文件工具走 `Sandbox.FileSystem`，由它调用 `Security.authorize_path/3`。
   - completed 子进程执行走 `Sandbox.Exec.run/2`，long-running stdio 子进程走 `Sandbox.Exec.open/2`，都由 OS sandbox 执行。
   - 两者消费同一份 sandbox/permission runtime policy。

3. sandbox backend 是平台实现细节。
   - macOS: Seatbelt via `/usr/bin/sandbox-exec`。
   - Linux later: Landlock/bwrap/seccomp backend。
   - Windows later: restricted token/job object/AppContainer 或外部 sandbox backend。

4. 不把整个 BEAM VM 放进 sandbox。
   - Gateway、Runner、Runtime、ControlPlane 是长期进程本体。
   - sandbox 约束 agent 触发的 external commands 和 MCP child processes。
   - 直接 BEAM 内文件 IO 仍必须经过 `Sandbox.FileSystem`。

5. 不把 permission approval 做成 LLM 对话。
   - approval 是 deterministic control lane。
   - `/approve`、`/deny` 和未来按钮必须绕过 busy queue。
   - slash command 可见性来自 `builtin:command.core` plugin contribution 和 bounded command handler table。
   - pending approval、session grant、always grant 只有一个状态机。

6. 不再靠 Bash 字符串黑名单作为安全边界。
   - 命令分类只用于 prompt 和 grant key。
   - 真正的文件/网络隔离由 OS sandbox enforced。
   - 复杂 shell command 第一版可以保守地只支持 exact command/session grant。

## 分层模型

### Permission decision layer

回答这个 action 是否可以开始：

```text
allow -> execute
ask -> create pending approval request
deny -> fail before execution
```

它处理：

- direct file tool read/write/list/search
- bash command execute
- external executor execute
- stdio MCP server start
- network access policy
- protected paths
- previously approved grants

### OS sandbox execution layer

只处理 child process：

```text
Sandbox.Exec.run(%Command{})
  -> select backend
  -> compile platform policy
  -> spawn wrapped command
  -> collect output / timeout / cancellation / observations
```

For long-running stdio processes such as MCP:

```text
Sandbox.Exec.open(%Command{})
  -> select backend
  -> compile platform policy
  -> spawn wrapped port
  -> expose write/close and data/eof/exit events
```

它不询问用户，不解释权限，不保存 grants。

### Existing direct tools

直接工具不通过 shell；如果它们在主 BEAM VM 里直接调用 `File.*`，Seatbelt 保护不了这次 IO。正确的 Codex-style 结论不是“只在 `File.*` 前做一次路径字符串检查”，而是把 direct file IO 收口到一个统一 filesystem authority：

- `read`
- `find` 的 scope validation
- `apply_patch`
- `message` 的 `attachment_path` / `attachment_paths` / `local_image_path`
- `reflect source path`
- `memory_write`
- `user_update`
- `soul_update`
- channel upload paths that consume model-provided attachment local paths
- future file-like tools

这些工具必须通过 `Nex.Agent.Sandbox.FileSystem` 进入实际 IO。`Security.authorize_path/3` 只负责作出 allow/ask/deny 决策；`Sandbox.FileSystem` 负责 canonical path、symlink/missing-target 处理、审批接入、审计事件，以及最终的读写执行。

第一版可以在同一个 BEAM 进程里执行已授权 `File.*`，但接口必须长成可替换的 filesystem runtime：

```elixir
Nex.Agent.Sandbox.FileSystem.read_file(path, ctx)
Nex.Agent.Sandbox.FileSystem.list_dir(path, ctx)
Nex.Agent.Sandbox.FileSystem.stat(path, ctx)
Nex.Agent.Sandbox.FileSystem.stream_file(path, ctx)
Nex.Agent.Sandbox.FileSystem.write_file(path, bytes, ctx)
Nex.Agent.Sandbox.FileSystem.remove(path, ctx)
```

这样后续可以像 Codex 一样把 direct file IO 下沉到 sandboxed helper 子进程，而不需要再迁移所有 tool 调用点。

`apply_patch` 不能在 parser/helper 里直接 `File.read` / `File.write` / `File.rm`。它应该先解析出 affected paths 以便生成 approval key；真正读取原文件、写入新文件、删除/移动文件时都经过 `Sandbox.FileSystem`。

`message` 的附件路径要在工具层经过 `Sandbox.FileSystem` 授权并形成 authorized attachment；Feishu 等 channel 只允许上传这个授权后的附件，不能重新打开任意 model-provided path。

`reflect source path` 必须先做 protected/out-of-policy path 判定，再检查文件是否存在，避免把 hard-denied path 的存在性泄漏给模型。

`find` 还会启动 `rg`，因此它需要两层：

1. scope path 通过 `Sandbox.FileSystem.authorize(path, :search, ctx)` 或等价 `Security.authorize_path/3`。
2. `rg` 子进程通过 `Sandbox.Exec.run/2` 以 read-only policy 启动。

## Proposed modules

```text
lib/nex/agent/sandbox/policy.ex
lib/nex/agent/sandbox/filesystem.ex
lib/nex/agent/sandbox/command.ex
lib/nex/agent/sandbox/result.ex
lib/nex/agent/sandbox/exec.ex
lib/nex/agent/sandbox/process.ex
lib/nex/agent/sandbox/backend.ex
lib/nex/agent/sandbox/backends/noop.ex
lib/nex/agent/sandbox/backends/seatbelt.ex
lib/nex/agent/sandbox/approval.ex
lib/nex/agent/sandbox/approval/request.ex
lib/nex/agent/sandbox/approval/grant.ex
lib/nex/agent/sandbox/permission.ex
```

`Approval` is the single pending/grant state source. `Permission` is pure-ish policy evaluation and request building. `Exec` is child process orchestration.

## Policy shape

First frozen target:

```elixir
%Nex.Agent.Sandbox.Policy{
  mode: :workspace_write,
  backend: :auto,
  network: :restricted,
  filesystem: [
    %{path: {:special, :minimal}, access: :read},
    %{path: {:special, :workspace}, access: :write},
    %{path: {:path, "/tmp"}, access: :write},
    %{path: {:path, "/Users/krisxin/nex-agent"}, access: :write},
    %{path: {:path, "/Users/krisxin/.zshrc"}, access: :none},
    %{path: {:path, "/Users/krisxin/.nex/agent/config.json"}, access: :none}
  ],
  protected_names: [".git", ".agents", ".codex"],
  env_allowlist: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "NO_COLOR"],
  raw: %{}
}
```

Semantic modes:

- `:read_only`: platform defaults + explicit read roots, no writes except child process stdio/tmp if configured.
- `:workspace_write`: read allowed roots, write workspace/project roots/tmp, protect metadata names.
- `:danger_full_access`: no OS sandbox unless explicitly required by caller.
- `:external`: caller asserts an outer sandbox exists; NexAgent still applies permission decisions.

Network:

- `:restricted`: no outbound network from child process.
- `:enabled`: full network for first version.
- future: domain/port allowlist when backend supports it.

## Runtime config shape

External config should be normalized by `Nex.Agent.Runtime.Config`:

```json
{
  "tools": {
    "sandbox": {
      "enabled": true,
      "backend": "auto",
      "default_profile": "workspace_write",
      "network": "restricted",
      "auto_allow_sandboxed_bash": false,
      "allow_read_roots": [],
      "allow_write_roots": [],
      "deny_read": [],
      "deny_write": [],
      "protected_paths": [
        "~/.zshrc",
        "~/.nex/agent/config.json"
      ],
      "approval": {
        "default": "ask",
        "allow_session_grants": true,
        "allow_always_grants": true
      }
    }
  }
}
```

Compatibility with current `tools.file_access.allowed_roots`:

- Stage 1 may keep reading it as an input to sandbox defaults.
- It must not remain a separate truth source after the migration.
- Final contract should prefer `tools.sandbox.allow_read_roots` / `allow_write_roots`.

## Approval model

Approval choices:

```text
allow once
allow exact command in this session
allow similar command in this session
allow this path operation in this session
always allow this path operation
deny once
deny all pending
approve all pending once
```

第一版必须支持：

- once grant: only releases the current pending request.
- session grant: in-memory, scoped by `{workspace, session_key, grant_key}`.
- always grant: persisted under workspace, scoped by `{workspace, grant_key}`.
- approve all pending once: releases all pending requests in the current session and does not create session or always grants.

Persistent path:

```text
<workspace>/permissions/grants.json
```

Do not persist full command output, env, prompt, or secrets.

Grant shape:

```elixir
%{
  "version" => 1,
  "grants" => [
    %{
      "kind" => "path" | "command" | "mcp" | "network",
      "operation" => "read" | "write" | "list" | "search" | "execute" | "connect",
      "subject" => String.t(),
      "grant_key" => String.t(),
      "scope" => "always",
      "created_at" => String.t()
    }
  ]
}
```

Session grants stay in memory and are cleared by `/new`; pending approvals are cancelled by `/stop`.

## Command grant keys

The grant key must be stable enough to reduce repeated prompts but conservative enough not to approve unrelated commands.

First version:

```elixir
%{
  exact_key: "command:execute:exact:<sha256 normalized command>",
  family_key: "command:execute:family:<program>:<normalized safe prefix>",
  risk_key: "command:execute:risk:<risk_class>"
}
```

Examples:

- `mix test test/nex/agent/bash_tool_test.exs`
  - exact: full normalized command
  - family: `mix:test`
- `/Users/krisxin/.local/bin/mise exec -- mix test ...`
  - family: `mise:mix:test`
- `git status --short`
  - family: `git:status`
- `curl ... | sh`
  - risk: `download_execute`
  - first version must ask exact with a risk hint; never offer broad similar allow.
- `base64 ... | sh`
  - risk: `encoded_shell`
  - must ask exact even when the default sandbox approval mode is allow.
- `D=$(...) && ...` / `` `...` `` / `cat <(...)`
  - risk: `command_substitution` / `process_substitution`
  - must ask exact with a risk hint instead of hard-denying before approval.
- `ruby -e` / `node -e` / `perl -e` / `bash -c`
  - risk: `interpreter_code` / `shell_escape`
  - must ask exact with a risk hint; broad similar grants are not offered.
- `rm -rf path`
  - risk: `destructive_delete`
  - no broad similar allow in first version.

For compound shell commands, pipelines, command substitution, env wrappers, or redirects:

- OS sandbox still enforces filesystem/network.
- Permission UI should default to exact command.
- Approval UI should display a short risk hint for high-risk forms.
- Similar/session family option appears only when parser can identify a safe family.

## Path authorization

Replace brittle path matching with canonical path authorization:

```elixir
Security.authorize_path(path, operation, ctx)
```

Operations:

- `:read`
- `:write`
- `:list`
- `:search`

Return:

```elixir
{:ok, expanded_path}
| {:error, reason}
```

Canonicalization shape:

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

Rules:

- allowed/denied checks use `canonical_path`.
- symlink target and symlink path both matter.
- denied path wins over allowed path.
- path boundary checks must not let `/repo` match `/repo-other`.
- protected paths are hard deny:
  - `~/.zshrc`
  - `~/.nex/agent/config.json`
- protected metadata names under writable roots are read-only unless explicitly approved by owner policy:
  - `.git`
  - `.agents`
  - `.codex`

## Seatbelt backend

`Nex.Agent.Sandbox.Backends.Seatbelt` compiles `Sandbox.Policy` into SBPL and argv:

```text
/usr/bin/sandbox-exec -p <policy> -DREADABLE_ROOT_0=/... -DWRITABLE_ROOT_0=/... -- <cmd> ...
```

Rules:

- Only use `/usr/bin/sandbox-exec`.
- Never resolve `sandbox-exec` through PATH.
- Use `-D` params for paths instead of string interpolation where possible.
- Start from `(deny default)`.
- Allow process fork/exec so child processes inherit the same sandbox.
- Allow file reads for platform minimum and configured read roots.
- Allow file writes only for configured write roots and temp roots.
- Deny protected paths and metadata carveouts.
- Default network restricted.
- Return `{:error, :seatbelt_unavailable}` if not on macOS or executable missing.

First version can use a smaller SBPL than Codex, but tests must prove:

- command can execute basic shell.
- read allowed file works.
- read denied file fails.
- write allowed root works.
- write denied root fails.
- network is restricted when policy says restricted.

## Linux and Windows future shape

Do not leak macOS terms into public callers.

Backend behavior:

```elixir
@callback available?() :: boolean()
@callback wrap(Sandbox.Command.t(), Sandbox.Policy.t()) ::
  {:ok, Sandbox.Command.t()} | {:error, term()}
```

`Sandbox.Exec` owns:

- timeout
- cancellation
- env filtering
- stdout/stderr collection
- ControlPlane observations

Backend owns only:

- platform availability
- policy compilation
- command wrapping

Future backend mapping:

- Linux: Landlock when enough for filesystem, bwrap/seccomp for stronger process/network isolation.
- Windows: restricted token/job object first; AppContainer or external sandbox later.
- Unsupported platform: fail closed when `sandbox.enabled == true`, or use `Noop` only when policy mode is explicitly `:danger_full_access` / `:external`.

## Tool integration

Must migrate:

- `Nex.Agent.Capability.Tool.Core.Bash`
- `Nex.Agent.Capability.Tool.Core.Find`
- `Nex.Agent.Capability.Executor`
- `Nex.Agent.Interface.MCP`

Should review and either migrate or explicitly exempt:

- `Nex.Agent.Self.Update.Deployer` test command execution
- `Nex.Agent.Self.Update.Planner` git status
- `Nex.Agent.Knowledge.ProjectMemory` git root detection
- `Nex.Agent.Turn.ContextBuilder` git root detection

Internal read-only metadata probes may stay direct if reviewed, but user/tool-triggered external execution must use `Sandbox.Exec`.

## ControlPlane observations

Add structured observations:

```text
sandbox.exec.started
sandbox.exec.finished
sandbox.exec.failed
sandbox.exec.denied
sandbox.exec.timeout
sandbox.approval.requested
sandbox.approval.approved
sandbox.approval.denied
sandbox.approval.timeout
```

`attrs` may include:

- sandbox backend
- policy mode
- network policy
- command family
- result status
- denial reason
- duration

Do not include:

- full env
- full command if it may contain secrets
- command stdout/stderr beyond bounded summary
- protected path contents

## Open questions

1. Whether `workspace_write` should read full disk like Codex/Claude or only explicit allowed roots.

   Proposed answer for NexAgent: do not allow full disk read. The agent is long-running and chat-connected, so default read roots should be workspace + configured project roots + platform minimum.

2. Whether sandboxed Bash can be auto-allowed.

   Proposed answer: config supports `auto_allow_sandboxed_bash`, but default is false until Seatbelt tests and approval UX are stable.

3. Whether `always` grants should be editable from Workbench/Admin.

   Proposed answer: not in first phase, but store shape should support future Admin UI.

4. How much shell parsing to implement.

   Proposed answer: enough for stable safe families (`git status`, `mix test`, `mise exec -- mix test`, package manager install under lockfile roots later). Complex shell remains exact approval.

## Non-goals

- No full auto-mode classifier in first phase.
- No platform-native approval buttons in first phase.
- No generic arbitrary workspace plugin code sandboxing claim.
- No promise that custom Elixir tools loaded into BEAM are sandboxed.
- No Windows/Linux backend implementation in first phase.
- No compatibility layer that lets old `file_access.allowed_roots` remain a second truth source permanently.
