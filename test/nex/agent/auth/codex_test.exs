defmodule Nex.Agent.Auth.CodexTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Auth.Codex

  test "resolve_access_token refreshes expired codex tokens and persists them" do
    tmp_dir = Path.join(System.tmp_dir!(), "nex-agent-codex-auth-#{System.unique_integer([:positive])}")
    auth_path = Path.join(tmp_dir, "auth.json")
    previous_home = System.get_env("CODEX_HOME")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if previous_home do
        System.put_env("CODEX_HOME", previous_home)
      else
        System.delete_env("CODEX_HOME")
      end
    end)

    System.put_env("CODEX_HOME", tmp_dir)
    File.mkdir_p!(tmp_dir)

    File.write!(
      auth_path,
      Jason.encode!(%{
        "tokens" => %{
          "access_token" => signed_token(System.system_time(:second) - 60),
          "refresh_token" => "stale-refresh-token"
        }
      })
    )

    refresh_fun = fn _tokens ->
      {:ok,
       %{
         access_token: signed_token(System.system_time(:second) + 3600),
         refresh_token: "fresh-refresh-token"
       }}
    end

    assert {:ok, refreshed_token} = Codex.resolve_access_token(refresh_fun: refresh_fun)
    assert is_binary(refreshed_token)

    saved =
      auth_path
      |> File.read!()
      |> Jason.decode!()

    assert get_in(saved, ["tokens", "access_token"]) == refreshed_token
    assert get_in(saved, ["tokens", "refresh_token"]) == "fresh-refresh-token"
    assert is_binary(saved["last_refresh"])
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
