defmodule Nex.Agent.Channel.Feishu.StreamState do
  @moduledoc false

  alias Nex.Agent.Channel.Feishu.StreamConverter

  defstruct converter: nil,
            pending_text: "",
            flush_timer_ref: nil,
            trace_id: nil,
            started_at_ms: nil

  @type t :: %__MODULE__{
          converter: StreamConverter.t(),
          pending_text: String.t(),
          flush_timer_ref: reference() | nil,
          trace_id: String.t() | nil,
          started_at_ms: integer() | nil
        }
end
