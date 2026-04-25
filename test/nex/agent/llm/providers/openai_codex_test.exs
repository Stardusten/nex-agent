defmodule Nex.Agent.LLM.Providers.OpenAICodexTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Config
  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.OpenAICodex.Stream
  alias Nex.Agent.Tool.Registry
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

  test "OAuth request body keeps web_search as function tool contract" do
    model =
      ReqLLM.model!(%{
        id: "gpt-5.5",
        provider: :openai,
        base_url: "https://chatgpt.com/backend-api/codex"
      })

    context = ReqLLM.Context.new([ReqLLM.Context.user("find recent Elixir release notes")])

    config = %Config{
      Config.default()
      | tools: %{
          "web_search" => %{
            "strategy" => "provider_native",
            "mode" => "live"
          }
        }
    }

    web_search_tool =
      Registry.definitions(:all,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )
      |> Enum.find(&(&1["name"] == "web_search"))

    assert {:ok, request} =
             Stream.attach_stream(
               model,
               context,
               [
                 base_url: "https://chatgpt.com/backend-api/codex",
                 provider_options: [
                   auth_mode: :oauth,
                   access_token: "oauth-access-token",
                   instructions: "You are a coding assistant."
                 ],
                 tools: [web_search_tool]
               ],
               ReqLLM.Finch
             )

    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    assert Enum.any?(body["tools"], fn tool ->
             tool["type"] == "function" and tool["name"] == "web_search"
           end)
  end

  test "OAuth request body keeps image_generation as function tool contract" do
    model =
      ReqLLM.model!(%{
        id: "gpt-5.5",
        provider: :openai,
        base_url: "https://chatgpt.com/backend-api/codex"
      })

    context = ReqLLM.Context.new([ReqLLM.Context.user("generate a lighthouse watercolor")])

    config = %Config{
      Config.default()
      | tools: %{
          "image_generation" => %{
            "strategy" => "provider_native",
            "output_format" => "webp"
          }
        }
    }

    image_generation_tool =
      Registry.definitions(:all,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )
      |> Enum.find(&(&1["name"] == "image_generation"))

    assert {:ok, request} =
             Stream.attach_stream(
               model,
               context,
               [
                 base_url: "https://chatgpt.com/backend-api/codex",
                 provider_options: [
                   auth_mode: :oauth,
                   access_token: "oauth-access-token",
                   instructions: "You are a coding assistant."
                 ],
                 tools: [image_generation_tool]
               ],
               ReqLLM.Finch
             )

    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    assert Enum.any?(body["tools"], fn tool ->
             tool["type"] == "function" and tool["name"] == "image_generation"
           end)
  end

  test "ProviderProfile.default_api_key(:openai_codex) resolves through Codex facade" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-codex-profile-#{System.unique_integer([:positive])}"
      )

    auth_path = Path.join([tmp_dir, "auth.json"])
    previous_home = System.get_env("CODEX_HOME")
    previous_token = System.get_env("OPENAI_CODEX_ACCESS_TOKEN")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if previous_home do
        System.put_env("CODEX_HOME", previous_home)
      else
        System.delete_env("CODEX_HOME")
      end

      if previous_token do
        System.put_env("OPENAI_CODEX_ACCESS_TOKEN", previous_token)
      else
        System.delete_env("OPENAI_CODEX_ACCESS_TOKEN")
      end
    end)

    System.put_env("CODEX_HOME", tmp_dir)
    System.delete_env("OPENAI_CODEX_ACCESS_TOKEN")
    File.mkdir_p!(tmp_dir)

    File.write!(
      auth_path,
      Jason.encode!(%{
        "tokens" => %{
          "access_token" => signed_token(System.system_time(:second) + 3600),
          "refresh_token" => "refresh-token"
        }
      })
    )

    assert is_binary(ProviderProfile.default_api_key(:openai_codex))
  end

  defp function_target(fun) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    {module, name, arity}
  end

  defp signed_token(exp) do
    encode_segment(%{"alg" => "none", "typ" => "JWT"}) <>
      "." <> encode_segment(%{"exp" => exp}) <> ".sig"
  end

  defp encode_segment(map) do
    map
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
