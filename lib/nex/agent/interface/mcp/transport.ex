defmodule Nex.Agent.Interface.MCP.Transport do
  @moduledoc """
  Transport adapter contract for MCP clients.

  Transports own I/O lifecycle plus wire encoding/framing.
  `Nex.Agent.Interface.MCP.Client` owns JSON-RPC request assembly, request ids,
  pending responses, and protocol methods.
  """

  @type start_opts :: keyword() | map()

  @callback start_link(start_opts()) :: GenServer.on_start()
  @callback send_request(pid(), map()) :: :ok | {:error, term()}
  @callback stop(pid()) :: :ok
end
