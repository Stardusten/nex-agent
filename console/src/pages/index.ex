defmodule NexAgentConsole.Pages.Index do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params), do: {:redirect, "/evolution"}

  def render(assigns), do: AdminUI.page_shell(assigns)
end
