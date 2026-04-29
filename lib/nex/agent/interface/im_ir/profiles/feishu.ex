defmodule Nex.Agent.Interface.IMIR.Profiles.Feishu do
  @moduledoc false

  @new_message_token "<newmsg/>"

  @type t :: %{
          name: atom(),
          new_message_token: String.t()
        }

  @spec profile() :: t()
  def profile do
    %{
      name: :feishu,
      new_message_token: @new_message_token
    }
  end
end
