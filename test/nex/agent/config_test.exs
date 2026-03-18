defmodule Nex.Agent.ConfigTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Config

  test "config validity accepts API key from environment for current provider" do
    previous = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "sk-env-test")

    on_exit(fn ->
      if previous do
        System.put_env("OPENAI_API_KEY", previous)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    config = %Config{Config.default() | provider: "openai"}

    assert Config.get_current_api_key(config) == "sk-env-test"
    assert Config.valid?(config)
  end
end
