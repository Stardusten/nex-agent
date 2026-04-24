defmodule Nex.Agent.LLM.Providers.OpenAICodexTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.OpenAICodex.Stream
  alias ReqLLM.Message

  test "adapter selects Codex stream only for OAuth mode" do
    oauth = ProviderProfile.for(:openai_codex, [])
    api_key = ProviderProfile.for(:openai_codex, base_url: "https://proxy.example.com/codex")

    assert function_target(ProviderProfile.stream_text_fun(oauth)) ==
             {Stream, :stream_text, 3}

    assert function_target(ProviderProfile.stream_text_fun(api_key)) == {ReqLLM, :stream_text, 3}
  end

  test "OAuth request body applies Codex responses payload policy" do
    model =
      ReqLLM.model!(%{
        id: "gpt-5.5",
        provider: :openai,
        base_url: "https://chatgpt.com/backend-api/codex"
      })

    reasoning = %Message.ReasoningDetails{
      provider: :openai,
      encrypted?: true,
      signature: "encrypted-reasoning",
      index: 0,
      provider_data: %{"id" => "rs_123", "type" => "reasoning"}
    }

    assistant =
      "stored turn"
      |> ReqLLM.Context.assistant(metadata: %{response_id: "resp_123"})
      |> Map.put(:reasoning_details, [reasoning])

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user("first turn"),
        assistant,
        ReqLLM.Context.user("next turn")
      ])

    assert {:ok, request} =
             Stream.attach_stream(
               model,
               context,
               [
                 base_url: "https://chatgpt.com/backend-api/codex",
                 provider_options: [
                   auth_mode: :oauth,
                   access_token: "oauth-access-token",
                   instructions: "You are a memory refresh agent.",
                   previous_response_id: "resp_from_provider_options"
                 ],
                 max_tokens: 4096
               ],
               ReqLLM.Finch
             )

    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    assert body["instructions"] == "You are a memory refresh agent."
    assert body["store"] == false
    refute Map.has_key?(body, "previous_response_id")
    refute Map.has_key?(body, "max_output_tokens")

    assert %{"type" => "reasoning", "encrypted_content" => "encrypted-reasoning"} =
             Enum.find(body["input"], &(&1["type"] == "reasoning"))

    refute body["input"] |> Enum.find(&(&1["type"] == "reasoning")) |> Map.has_key?("id")
  end

  test "OAuth request body preserves forced tool choice as Responses API function choice" do
    model =
      ReqLLM.model!(%{
        id: "gpt-5.5",
        provider: :openai,
        base_url: "https://chatgpt.com/backend-api/codex"
      })

    context = ReqLLM.Context.new([ReqLLM.Context.user("refresh memory")])

    tool =
      ReqLLM.Tool.new!(
        name: "save_memory",
        description: "Save updated memory",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"action" => %{"type" => "string"}}
        },
        callback: fn _args -> {:ok, "ok"} end
      )

    assert {:ok, request} =
             Stream.attach_stream(
               model,
               context,
               [
                 base_url: "https://chatgpt.com/backend-api/codex",
                 provider_options: [
                   auth_mode: :oauth,
                   access_token: "oauth-access-token",
                   instructions: "You are a memory refresh agent."
                 ],
                 tools: [tool],
                 tool_choice: %{type: "tool", name: "save_memory"}
               ],
               ReqLLM.Finch
             )

    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    assert body["tool_choice"] == %{"type" => "function", "name" => "save_memory"}
  end

  defp function_target(fun) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    {module, name, arity}
  end
end
