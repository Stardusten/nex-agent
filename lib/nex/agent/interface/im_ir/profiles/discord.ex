defmodule Nex.Agent.Interface.IMIR.Profiles.Discord do
  @moduledoc false

  @new_message_token "<newmsg/>"

  @spec profile() :: map()
  def profile do
    %{
      name: :discord,
      new_message_token: @new_message_token,
      markdown: %{
        headings: true,
        lists: true,
        quotes: true,
        code_blocks: true,
        tables: true
      }
    }
  end
end
