defmodule Nex.Agent.ConfigTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Auth.Codex
  alias Nex.Agent.Config

  test "loads new config shape and resolves model roles" do
    previous = System.get_env("HY3_API_KEY")
    System.put_env("HY3_API_KEY", "sk-hy3-test")

    on_exit(fn ->
      if previous,
        do: System.put_env("HY3_API_KEY", previous),
        else: System.delete_env("HY3_API_KEY")
    end)

    config = Config.from_map(full_config())

    assert Config.valid?(config)
    assert Config.get_max_iterations(config) == 100
    assert Config.configured_workspace(config) == "/tmp/nex-agent-workspace"
    assert Config.gateway_port(config) == 18_790

    assert Config.workbench_runtime(config) == %{
             "enabled" => false,
             "host" => "127.0.0.1",
             "port" => 50_051,
             "apps" => %{}
           }

    assert %{
             model_key: "hy3-preview",
             model_id: "hy3-preview",
             provider_key: "hy3-tencent",
             provider_type: "openai-compatible",
             provider: :openai_compatible,
             api_key: "sk-hy3-test",
             base_url: "https://hy3.example.com/v1"
           } = Config.default_model_runtime(config)

    assert %{model_key: "hy3-preview"} = Config.cheap_model_runtime(config)

    assert %{
             model_key: "gpt-5.4",
             model_id: "gpt-5.4",
             provider_key: "openai-codex",
             provider_type: "openai-codex"
           } = Config.memory_model_runtime(config)

    assert %{
             model_key: "gpt-5.4",
             model_id: "gpt-5.4",
             provider_key: "openai-codex",
             provider_type: "openai-codex"
           } = Config.advisor_model_runtime(config)

    assert Config.default_model_runtime(config).provider_options[:temperature] == 0.2
    assert Config.default_model_runtime(config).provider_options[:reasoning_effort] == "low"

    assert %{
             "code_reviewer" => %{
               "description" => "Review risky code",
               "model_role" => "advisor",
               "tools_filter" => "subagent"
             }
           } = Config.subagent_profile_config(config)
  end

  test "model entries carry provider-specific request options" do
    config =
      Config.from_map(%{
        full_config()
        | "model" => %{
            "default_model" => "gpt-5.5-xhigh-fast",
            "models" => %{
              "gpt-5.5-xhigh-fast" => %{
                "provider" => "openai-codex",
                "id" => "gpt-5.5",
                "context_window" => 272_000,
                "auto_compact_token_limit" => 190_000,
                "context_strategy" => "server_side_then_recent",
                "reasoning_effort" => "xhigh",
                "service_tier" => "fast"
              }
            }
          }
      })

    assert %{
             model_key: "gpt-5.5-xhigh-fast",
             model_id: "gpt-5.5",
             provider_key: "openai-codex",
             provider_type: "openai-codex",
             context_window: 272_000,
             auto_compact_token_limit: 190_000,
             context_strategy: "server_side_then_recent",
             provider_options: provider_options
           } = Config.default_model_runtime(config)

    assert provider_options[:reasoning_effort] == "xhigh"
    assert provider_options[:service_tier] == "fast"
    refute Keyword.has_key?(provider_options, :context_window)
    refute Keyword.has_key?(provider_options, :auto_compact_token_limit)
    refute Keyword.has_key?(provider_options, :context_strategy)
  end

  test "memory model falls back to cheap and then default model role" do
    config =
      Config.from_map(%{
        full_config()
        | "model" => %{
            "cheap_model" => "hy3-preview",
            "default_model" => "gpt-5.4",
            "models" => %{
              "gpt-5.4" => %{"provider" => "openai-codex", "id" => "gpt-5.4"},
              "hy3-preview" => %{"provider" => "hy3-tencent", "id" => "hy3-preview"}
            }
          }
      })

    assert %{model_key: "hy3-preview"} = Config.memory_model_runtime(config)

    config =
      Config.from_map(%{
        full_config()
        | "model" => %{
            "default_model" => "gpt-5.4",
            "models" => %{
              "gpt-5.4" => %{"provider" => "openai-codex", "id" => "gpt-5.4"}
            }
          }
      })

    assert %{model_key: "gpt-5.4"} = Config.memory_model_runtime(config)
  end

  test "channel instances are keyed by instance id" do
    config = Config.from_map(full_config())

    assert %{
             "feishu_kai" => %{"type" => "feishu", "enabled" => true},
             "discord_kai" => %{"type" => "discord", "enabled" => true}
           } = Config.channel_instances(config)

    assert Config.channel_instance(config, "feishu_kai")["app_id"] == "cli_feishu_app"
    assert Config.channel_type(config, "discord_kai") == "discord"
    assert Config.channel_streaming?(config, "feishu_kai")
    refute Config.channel_streaming?(config, "discord_kai")

    assert Config.channels_runtime(config) == %{
             "feishu_kai" => %{"type" => "feishu", "streaming" => true},
             "discord_kai" => %{
               "type" => "discord",
               "streaming" => false,
               "show_table_as" => "ascii"
             }
           }
  end

  test "discord table render mode is normalized" do
    config =
      Config.from_map(%{
        full_config()
        | "channel" => %{
            "discord_kai" => %{
              "type" => "discord",
              "enabled" => true,
              "token" => "discord-token",
              "show_table_as" => "EMBED"
            },
            "discord_bad" => %{
              "type" => "discord",
              "enabled" => true,
              "token" => "discord-token",
              "show_table_as" => "surprise"
            }
          }
      })

    assert Config.channel_instance(config, "discord_kai")["show_table_as"] == "embed"
    assert Config.channel_instance(config, "discord_bad")["show_table_as"] == "ascii"
    assert {:ok, runtime} = Config.channel_runtime(config, "discord_kai")
    assert runtime["show_table_as"] == "embed"
  end

  test "unknown channel types are preserved as invalid config" do
    config =
      Config.from_map(%{
        full_config()
        | "channel" => %{
            "telegram_main" => %{"type" => "telegram", "enabled" => true, "token" => "token"}
          }
      })

    assert Config.channel_instance(config, "telegram_main")["type"] == "telegram"
    refute Config.valid?(config)

    assert {:error, diagnostic} = Config.channel_runtime(config, "telegram_main")
    assert diagnostic.code == :unknown_channel_type
    assert diagnostic.instance_id == "telegram_main"
    assert diagnostic.type == "telegram"
    assert Config.channels_runtime(config) == %{}
    assert [diagnostic] == Config.channel_diagnostics(config)
  end

  test "channel diagnostics report missing enabled requirements" do
    config =
      Config.from_map(%{
        full_config()
        | "channel" => %{
            "discord_bad" => %{"type" => "discord", "enabled" => true},
            "feishu_bad" => %{"type" => "feishu", "enabled" => true, "app_id" => "cli"}
          }
      })

    refute Config.valid?(config)

    diagnostics = Config.channel_diagnostics(config)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.code == :missing_required_channel_field and
               diagnostic.instance_id == "discord_bad" and diagnostic.field == "token"
           end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.code == :missing_required_channel_field and
               diagnostic.instance_id == "feishu_bad" and diagnostic.field == "app_secret"
           end)
  end

  test "old top-level provider and model strings are invalid" do
    config =
      Config.from_map(%{
        "max_iterations" => 100,
        "workspace" => "/tmp/workspace",
        "provider" => "openai",
        "model" => "gpt-4o",
        "channel" => %{},
        "gateway" => %{"port" => 18_790},
        "tools" => %{}
      })

    refute Config.valid?(config)
    assert Config.default_model_runtime(config) == nil
  end

  test "new config shape persists through save and load" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-config-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm_rf!(path) end)

    config = Config.from_map(full_config())

    assert :ok = Config.save(config, config_path: path)
    loaded = Config.load(config_path: path)

    assert loaded.workspace == "/tmp/nex-agent-workspace"
    assert loaded.gateway["port"] == 18_790
    assert get_in(loaded.gateway, ["workbench", "port"]) == 50_051
    assert Map.has_key?(loaded.channel, "feishu_kai")
    assert loaded.model["default_model"] == "hy3-preview"

    assert get_in(loaded.provider, ["providers", "hy3-tencent", "api_key"]) == %{
             "env" => "HY3_API_KEY"
           }
  end

  test "workbench runtime is normalized under gateway config" do
    config =
      Config.from_map(%{
        full_config()
        | "gateway" => %{
            "port" => 18_790,
            "workbench" => %{
              "enabled" => true,
              "host" => "0.0.0.0",
              "port" => "50052",
              "apps" => %{
                "notes" => %{"root" => " ./notes "},
                "Bad.App" => %{"root" => "/tmp/bad"},
                "broken" => "not a map"
              }
            }
          }
      })

    notes_root = Path.expand("./notes")

    assert Config.workbench_runtime(config) == %{
             "enabled" => true,
             "host" => "127.0.0.1",
             "port" => 50_052,
             "apps" => %{"notes" => %{"root" => notes_root}}
           }

    assert Config.workbench_app_config(config, "notes") == %{"root" => notes_root}
    assert Config.workbench_app_config(config, :missing) == %{}

    updated = Config.set(config, :workbench_port, 50_053)

    assert Config.workbench_runtime(updated)["port"] == 50_053
    assert Config.workbench_app_config(updated, "notes") == %{"root" => notes_root}
  end

  test "openai-codex provider resolves access token from codex auth file" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "nex-agent-codex-#{System.unique_integer([:positive])}")

    auth_path = Path.join([tmp_dir, "auth.json"])
    previous_home = System.get_env("CODEX_HOME")
    previous_token = System.get_env("OPENAI_CODEX_ACCESS_TOKEN")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if previous_home,
        do: System.put_env("CODEX_HOME", previous_home),
        else: System.delete_env("CODEX_HOME")

      if previous_token,
        do: System.put_env("OPENAI_CODEX_ACCESS_TOKEN", previous_token),
        else: System.delete_env("OPENAI_CODEX_ACCESS_TOKEN")
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

    config =
      Config.from_map(%{
        full_config()
        | "provider" => %{
            "providers" => %{
              "openai-codex" => %{"type" => "openai-codex"}
            }
          },
          "model" => %{
            "default_model" => "gpt-5.4",
            "cheap_model" => "gpt-5.4",
            "advisor_model" => "gpt-5.4",
            "models" => %{"gpt-5.4" => %{"provider" => "openai-codex"}}
          }
      })

    runtime = Config.default_model_runtime(config)

    assert is_binary(runtime.api_key)
    assert runtime.base_url == Codex.default_base_url()
    assert Config.valid?(config)
  end

  test "openai-codex-custom provider resolves api key and base url from codex files" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "nex-agent-codex-custom-#{System.unique_integer([:positive])}")

    auth_path = Path.join([tmp_dir, "auth.json"])
    config_toml_path = Path.join([tmp_dir, "config.toml"])
    previous_home = System.get_env("CODEX_HOME")
    previous_key = System.get_env("OPENAI_CODEX_API_KEY")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if previous_home,
        do: System.put_env("CODEX_HOME", previous_home),
        else: System.delete_env("CODEX_HOME")

      if previous_key,
        do: System.put_env("OPENAI_CODEX_API_KEY", previous_key),
        else: System.delete_env("OPENAI_CODEX_API_KEY")
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

    config =
      Config.from_map(%{
        full_config()
        | "provider" => %{
            "providers" => %{
              "openai-codex-custom" => %{"type" => "openai-codex-custom"}
            }
          },
          "model" => %{
            "default_model" => "gpt-5.4",
            "cheap_model" => "gpt-5.4",
            "advisor_model" => "gpt-5.4",
            "models" => %{"gpt-5.4" => %{"provider" => "openai-codex-custom"}}
          }
      })

    runtime = Config.default_model_runtime(config)

    assert runtime.api_key == "sk-custom-test-key"
    assert runtime.base_url == "https://proxy.example.com/codex"
    assert Config.valid?(config)
  end

  test "web_search config reads the tools.web_search backend provider contract" do
    config =
      Config.from_map(%{
        full_config()
        | "tools" => %{
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
                }
              }
            }
          }
      })

    assert Config.web_search_provider_config(config) == %{
             "provider" => "codex",
             "mode" => "cached",
             "allowed_domains" => ["example.com"],
             "user_location" => %{
               "country" => "US",
               "timezone" => "America/Los_Angeles"
             }
           }
  end

  test "image_generation config reads the tools.image_generation backend provider contract" do
    config =
      Config.from_map(%{
        full_config()
        | "tools" => %{
            "image_generation" => %{
              "provider" => "codex",
              "providers" => %{
                "codex" => %{"output_format" => "webp"}
              }
            }
          }
      })

    assert Config.image_generation_provider_config(config) == %{
             "provider" => "codex",
             "output_format" => "webp"
           }
  end

  test "file_access config normalizes allowed roots" do
    root = Path.expand("../nex-agent-file-access-root", File.cwd!())

    config =
      Config.from_map(%{
        full_config()
        | "tools" => %{
            "file_access" => %{
              "allowed_roots" => [" #{root} ", "", 42, root]
            }
          }
      })

    assert Config.file_access_allowed_roots(config) == [root]
  end

  defp full_config do
    %{
      "max_iterations" => 100,
      "workspace" => "/tmp/nex-agent-workspace",
      "channel" => %{
        "feishu_kai" => %{
          "type" => "feishu",
          "enabled" => true,
          "streaming" => true,
          "app_id" => "cli_feishu_app",
          "app_secret" => "feishu_secret"
        },
        "discord_kai" => %{
          "type" => "discord",
          "enabled" => true,
          "streaming" => false,
          "token" => "discord-token"
        }
      },
      "gateway" => %{"port" => 18_790},
      "provider" => %{
        "providers" => %{
          "hy3-tencent" => %{
            "type" => "openai-compatible",
            "base_url" => "https://hy3.example.com/v1",
            "api_key" => %{"env" => "HY3_API_KEY"},
            "temperature" => 0.2
          },
          "openai-codex" => %{"type" => "openai-codex"}
        }
      },
      "model" => %{
        "cheap_model" => "hy3-preview",
        "memory_model" => "gpt-5.4",
        "default_model" => "hy3-preview",
        "advisor_model" => "gpt-5.4",
        "models" => %{
          "gpt-5.4" => %{"provider" => "openai-codex", "id" => "gpt-5.4"},
          "hy3-preview" => %{
            "provider" => "hy3-tencent",
            "id" => "hy3-preview",
            "reasoning_effort" => "low"
          }
        }
      },
      "subagents" => %{
        "profiles" => %{
          "code_reviewer" => %{
            "description" => "Review risky code",
            "prompt" => "Find correctness bugs first.",
            "model_role" => "advisor",
            "tools_filter" => "subagent",
            "context_mode" => "parent_recent",
            "return_mode" => "silent",
            "allowed_tools" => ["read", "find"]
          }
        }
      },
      "tools" => %{
        "web_search" => %{
          "provider" => "duckduckgo",
          "providers" => %{
            "duckduckgo" => %{},
            "codex" => %{"mode" => "live"}
          }
        },
        "image_generation" => %{
          "provider" => "codex",
          "providers" => %{"codex" => %{"output_format" => "png"}}
        }
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
