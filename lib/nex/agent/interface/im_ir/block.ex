defmodule Nex.Agent.Interface.IMIR.Block do
  @moduledoc false

  @type type ::
          :paragraph | :heading | :list | :quote | :code_block | :table | :new_message

  @enforce_keys [:type, :canonical_text]
  defstruct [
    :type,
    :canonical_text,
    text: "",
    complete?: true,
    level: nil,
    items: [],
    rows: [],
    lang: nil
  ]

  @type t :: %__MODULE__{
          type: type(),
          canonical_text: String.t(),
          text: String.t(),
          complete?: boolean(),
          level: pos_integer() | nil,
          items: [String.t()],
          rows: [String.t()],
          lang: String.t() | nil
        }
end
