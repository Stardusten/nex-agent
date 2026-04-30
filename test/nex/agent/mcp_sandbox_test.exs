defmodule Nex.Agent.MCPSandboxTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Interface.MCP
  alias Nex.Agent.Runtime.Config

  test "stdio MCP server is opened through sandbox exec process contract" do
    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "allow"}
          }
        }
      })

    script = """
    while IFS= read -r line; do
      case "$line" in
        *\\"initialize\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"tools":[]}}'
          ;;
        *\\"tools/list\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo"}]}}'
          ;;
      esac
    done
    """

    {:ok, pid} =
      MCP.start_link(
        command: "sh",
        args: ["-c", script],
        config: config,
        cwd: File.cwd!(),
        workspace: File.cwd!()
      )

    assert {:ok, %{"capabilities" => %{}}} = MCP.initialize(pid)
    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = MCP.list_tools(pid)
    assert :ok = MCP.stop(pid)
  end
end
