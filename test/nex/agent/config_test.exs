defmodule Nex.Agent.ConfigTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Auth.Codex
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

  test "skill_runtime config persists through save and load" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-config-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf!(path) end)

    config =
      %Config{
        Config.default()
        | skill_runtime: %{
            "enabled" => true,
            "max_selected_skills" => 3,
            "github_indexes" => [
              %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
            ]
          }
      }

    assert :ok = Config.save(config, config_path: path)

    loaded = Config.load(config_path: path)

    assert loaded.skill_runtime["enabled"] == true
    assert loaded.skill_runtime["max_selected_skills"] == 3
    assert [%{"repo" => "org/index"} | _] = loaded.skill_runtime["github_indexes"]
  end

  test "openai-codex provider resolves access token from codex auth file" do
    tmp_dir = Path.join(System.tmp_dir!(), "nex-agent-codex-#{System.unique_integer([:positive])}")
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

    config = %Config{Config.default() | provider: "openai-codex"}

    assert is_binary(Config.get_current_api_key(config))
    assert Config.get_current_base_url(config) == Codex.default_base_url()
    assert Config.valid?(config)
  end

  test "openai-codex-custom provider resolves api key and base url from codex files" do
    tmp_dir = Path.join(System.tmp_dir!(), "nex-agent-codex-custom-#{System.unique_integer([:positive])}")
    auth_path = Path.join([tmp_dir, "auth.json"])
    config_toml_path = Path.join([tmp_dir, "config.toml"])
    previous_home = System.get_env("CODEX_HOME")
    previous_key = System.get_env("OPENAI_CODEX_API_KEY")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if previous_home do
        System.put_env("CODEX_HOME", previous_home)
      else
        System.delete_env("CODEX_HOME")
      end

      if previous_key do
        System.put_env("OPENAI_CODEX_API_KEY", previous_key)
      else
        System.delete_env("OPENAI_CODEX_API_KEY")
      end
    end)

    System.put_env("CODEX_HOME", tmp_dir)
    System.delete_env("OPENAI_CODEX_API_KEY")
    File.mkdir_p!(tmp_dir)

    File.write!(
      auth_path,
      Jason.encode!(%{
        "OPENAI_API_KEY" => "sk-custom-test-key",
        "tokens" => %{
          "access_token" => signed_token(System.system_time(:second) + 3600),
          "refresh_token" => "refresh-token"
        }
      })
    )

    File.write!(
      config_toml_path,
      """
      model_provider = "myproxy"

      [model_providers.myproxy]
      name = "myproxy"
      base_url = "https://proxy.example.com/codex"
      """
    )

    config = %Config{Config.default() | provider: "openai-codex-custom"}

    assert Config.get_current_api_key(config) == "sk-custom-test-key"
    assert Config.get_current_base_url(config) == "https://proxy.example.com/codex"
    assert Config.valid?(config)
  end

  test "web_search provider config is normalized through unified accessor" do
    config =
      %Config{
        Config.default()
        | tools: %{
            "web_search" => %{
              "provider" => "codex",
              "providers" => %{
                "codex" => %{
                  "mode" => "cached",
                  "allowed_domains" => [" example.com ", "example.com", ""],
                  "user_location" => %{
                    "country" => "US",
                    "timezone" => "America/Los_Angeles",
                    "ignored" => "value"
                  }
                },
                "duckduckgo" => %{"ignored" => true}
              }
            }
          }
      }

    assert Config.web_search_provider_config(config) == %{
             "provider" => "codex",
             "providers" => %{
               "duckduckgo" => %{},
               "codex" => %{
                 "mode" => "cached",
                 "allowed_domains" => ["example.com"],
                 "user_location" => %{
                   "country" => "US",
                   "timezone" => "America/Los_Angeles"
                 }
               }
             }
           }
  end

  test "image_generation provider config is normalized through unified accessor" do
    config =
      %Config{
        Config.default()
        | tools: %{
            "image_generation" => %{
              "provider" => "codex",
              "providers" => %{
                "codex" => %{"output_format" => "webp"},
                "nanobanana" => %{"model" => "banana-v1"}
              }
            }
          }
      }

    assert Config.image_generation_provider_config(config) == %{
             "provider" => "codex",
             "providers" => %{
               "codex" => %{"output_format" => "webp"},
               "nanobanana" => %{"model" => "banana-v1"}
             }
           }
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
