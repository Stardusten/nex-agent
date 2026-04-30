defmodule Nex.Agent.Sandbox.FileSystemTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Sandbox.{Approval, Security}

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    previous_allowed_roots = System.get_env("NEX_ALLOWED_ROOTS")
    System.delete_env("NEX_ALLOWED_ROOTS")

    on_exit(fn ->
      if previous_allowed_roots,
        do: System.put_env("NEX_ALLOWED_ROOTS", previous_allowed_roots),
        else: System.delete_env("NEX_ALLOWED_ROOTS")
    end)

    :ok
  end

  test "hard denied paths are rejected before approval" do
    protected = Path.expand("~/.zshrc")

    assert {:error, message} = Security.authorize_path(protected, :read, %{})
    assert message =~ "hard-denied"

    ctx = %{
      channel: "test",
      chat_id: "chat",
      session_key: "test:chat",
      approval_mode: :defer
    }

    assert {:error, message} = Security.authorize_path(protected, :read, ctx)
    assert message =~ "hard-denied"
  end

  test "symlink targets must stay inside allowed roots" do
    workspace = tmp_dir("workspace")
    outside_root = external_root("outside")
    outside_file = Path.join(outside_root, "secret.txt")
    link_path = Path.join(workspace, "linked-secret.txt")

    File.mkdir_p!(workspace)
    File.mkdir_p!(outside_root)
    File.write!(outside_file, "secret\n")
    File.ln_s!(outside_file, link_path)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(outside_root)
    end)

    assert {:error, message} = Security.authorize_path(link_path, :read, %{workspace: workspace})
    assert message =~ "Path not within allowed roots"
  end

  test "missing write target through symlinked ancestor is rejected" do
    workspace = tmp_dir("workspace-write")
    outside_root = external_root("outside-write")
    link_dir = Path.join(workspace, "linked-dir")
    target = Path.join(link_dir, "new.txt")

    File.mkdir_p!(workspace)
    File.mkdir_p!(outside_root)
    File.ln_s!(outside_root, link_dir)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(outside_root)
    end)

    assert {:error, message} = Security.authorize_path(target, :write, %{workspace: workspace})
    assert message =~ "Path not within allowed roots"
  end

  test "interactive path approval supports once and session grants" do
    workspace = tmp_dir("approval-workspace")
    outside_root = external_root("approval-outside")
    outside_file = Path.join(outside_root, "note.txt")
    server = Module.concat(__MODULE__, :"Approval#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.mkdir_p!(outside_root)
    File.write!(outside_file, "needs approval\n")
    start_supervised!({Approval, name: server})

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(outside_root)
    end)

    ctx = %{
      workspace: workspace,
      session_key: "test:chat",
      channel: "test",
      chat_id: "chat",
      approval_server: server
    }

    once_task = Task.async(fn -> Security.authorize_path(outside_file, :read, ctx) end)
    wait_until(fn -> Approval.pending?(workspace, "test:chat", server: server) end)

    assert {:ok, %{approved: 1, choice: :once}} =
             Approval.approve(workspace, "test:chat", :once, server: server)

    assert {:ok, %{canonical_path: ^outside_file}} = Task.await(once_task)

    assert {:ask, _request} =
             Security.authorize_path(outside_file, :read, Map.put(ctx, :approval_mode, :defer))

    session_task = Task.async(fn -> Security.authorize_path(outside_file, :read, ctx) end)
    wait_until(fn -> Approval.pending?(workspace, "test:chat", server: server) end)

    assert {:ok, %{approved: 1, choice: :session}} =
             Approval.approve(workspace, "test:chat", :session, server: server)

    assert {:ok, %{canonical_path: ^outside_file}} = Task.await(session_task)

    assert {:ok, %{canonical_path: ^outside_file}} =
             Security.authorize_path(outside_file, :read, ctx)
  end

  test "model-visible direct file tools use the sandbox filesystem authority" do
    root = File.cwd!()

    direct_file_tool_paths = [
      "lib/nex/agent/capability/tool/core/read.ex",
      "lib/nex/agent/capability/tool/core/find.ex",
      "lib/nex/agent/capability/tool/core/apply_patch.ex",
      "lib/nex/agent/capability/tool/core/message.ex",
      "lib/nex/agent/capability/tool/core/user_update.ex",
      "lib/nex/agent/capability/tool/core/soul_update.ex",
      "priv/plugins/builtin/tool.memory/lib/nex/agent/tool/memory_write.ex"
    ]

    forbidden_file_api =
      ~r/\bFile\.(read|read!|write|write!|rm|rm_rf|cp|cp!|ls|ls!|stat|stat!|stream!|exists\?|regular\?|dir\?|mkdir_p|mkdir_p!)/

    for path <- direct_file_tool_paths do
      body = File.read!(Path.join(root, path))
      refute body =~ forbidden_file_api, "#{path} reintroduced direct File.* access"
    end

    reflect = File.read!(Path.join(root, "lib/nex/agent/capability/tool/core/reflect.ex"))
    assert reflect =~ "FileSystem.authorize(expanded, :read, ctx)"
    assert reflect =~ "FileSystem.read_file(info)"
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "nex-agent-sandbox-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp external_root(label) do
    Path.expand(
      "../#{Path.basename(File.cwd!())}-sandbox-#{label}-#{System.unique_integer([:positive])}",
      File.cwd!()
    )
  end
end
