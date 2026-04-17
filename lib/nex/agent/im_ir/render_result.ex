defmodule Nex.Agent.IMIR.RenderResult do
  @moduledoc false

  @enforce_keys [:payload, :text, :complete?, :new_message?, :canonical_text, :warnings]
  defstruct [
    :payload,
    :text,
    :complete?,
    :new_message?,
    :canonical_text,
    :warnings
  ]

  @type t :: %__MODULE__{
          payload: term(),
          text: String.t(),
          complete?: boolean(),
          new_message?: boolean(),
          canonical_text: String.t(),
          warnings: [term()]
        }

  @spec from_block(Nex.Agent.IMIR.Block.t(), keyword()) :: t()
  def from_block(%Nex.Agent.IMIR.Block{} = block, opts \\ []) do
    %__MODULE__{
      payload: Keyword.get(opts, :payload, block),
      text: Keyword.get(opts, :text, block.text),
      complete?: Keyword.get(opts, :complete?, block.complete?),
      new_message?: Keyword.get(opts, :new_message?, block.type == :new_message),
      canonical_text: Keyword.get(opts, :canonical_text, block.canonical_text),
      warnings: Keyword.get(opts, :warnings, [])
    }
  end
end
