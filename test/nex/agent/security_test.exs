defmodule Nex.Agent.SecurityTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Config
  alias Nex.Agent.Security

  setup do
    previous_allowed_roots = System.get_env("NEX_ALLOWED_ROOTS")
    System.delete_env("NEX_ALLOWED_ROOTS")

    on_exit(fn ->
      restore_env("NEX_ALLOWED_ROOTS", previous_allowed_roots)
    end)

    :ok
  end

  test "config file_access roots extend allowed path validation without prefix bleed" do
    allowed_root = external_root("allowed")
    prefix_sibling = allowed_root <> "-sibling"
    allowed_file = Path.join(allowed_root, "README.md")
    sibling_file = Path.join(prefix_sibling, "README.md")

    File.mkdir_p!(allowed_root)
    File.mkdir_p!(prefix_sibling)
    File.write!(allowed_file, "allowed\n")
    File.write!(sibling_file, "sibling\n")

    on_exit(fn ->
      File.rm_rf!(allowed_root)
      File.rm_rf!(prefix_sibling)
    end)

    config =
      Config.from_map(%{"tools" => %{"file_access" => %{"allowed_roots" => [allowed_root]}}})

    assert {:ok, ^allowed_file} = Security.validate_path(allowed_file, %{config: config})

    assert {:ok, new_file} =
             Security.validate_write_path(Path.join(allowed_root, "new.md"), %{config: config})

    assert new_file == Path.join(allowed_root, "new.md")

    assert {:error, message} = Security.validate_path(sibling_file, %{config: config})
    assert message =~ "Path not within allowed roots"
  end

  test "NEX_ALLOWED_ROOTS remains a process-level override" do
    env_root = external_root("env")
    config_root = external_root("config")
    env_file = Path.join(env_root, "env.txt")
    config_file = Path.join(config_root, "config.txt")

    File.mkdir_p!(env_root)
    File.mkdir_p!(config_root)
    File.write!(env_file, "env\n")
    File.write!(config_file, "config\n")

    on_exit(fn ->
      File.rm_rf!(env_root)
      File.rm_rf!(config_root)
    end)

    System.put_env("NEX_ALLOWED_ROOTS", env_root)

    config =
      Config.from_map(%{"tools" => %{"file_access" => %{"allowed_roots" => [config_root]}}})

    assert {:ok, ^env_file} = Security.validate_path(env_file, %{config: config})
    assert {:error, _message} = Security.validate_path(config_file, %{config: config})
  end

  defp external_root(label) do
    Path.expand(
      "../#{Path.basename(File.cwd!())}-security-#{label}-#{System.unique_integer([:positive])}",
      File.cwd!()
    )
  end

  defp restore_env(_key, nil), do: System.delete_env("NEX_ALLOWED_ROOTS")
  defp restore_env(key, value), do: System.put_env(key, value)
end
