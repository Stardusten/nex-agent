defmodule Nex.Agent.Conversation.CommandParserTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Conversation.Command.Invocation
  alias Nex.Agent.Conversation.Command.Parser

  test "parses approval commands from builtin command catalog" do
    assert {:ok, %Invocation{name: "approve", args: ["all"], raw: "/approve all"}} =
             Parser.parse("/approve all")

    assert {:ok, %Invocation{name: "approve", args: ["session"], raw: "/approve session"}} =
             Parser.parse("/approve session")

    assert {:ok, %Invocation{name: "deny", args: ["all"], raw: "/deny all"}} =
             Parser.parse("/deny all")
  end

  test "unknown slash command remains unmatched" do
    assert Parser.parse("/unknown nope") == :no_match
  end
end
