defmodule Nex.Agent.Channel.Specs.Feishu do
  @moduledoc false

  @behaviour Nex.Agent.Channel.Spec

  @impl true
  def type, do: "feishu"

  @impl true
  def gateway_module, do: Nex.Agent.Channel.Feishu

  @impl true
  def apply_defaults(instance) when is_map(instance) do
    instance
    |> Map.put("type", type())
    |> Map.put_new("streaming", true)
  end

  @impl true
  def validate_instance(instance, opts) when is_map(instance) do
    instance_id = Keyword.get(opts, :instance_id)

    diagnostics =
      if Map.get(instance, "enabled", false) == true do
        [
          required_diagnostic(instance, "app_id", instance_id),
          required_diagnostic(instance, "app_secret", instance_id)
        ]
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  @impl true
  def runtime(instance) when is_map(instance) do
    %{
      "type" => type(),
      "streaming" => Map.get(instance, "streaming", true) == true
    }
  end

  @impl true
  def format_prompt(runtime, _opts) when is_map(runtime) do
    streaming = if Map.get(runtime, "streaming", true) == true, do: "streaming", else: "single"

    """
    ## Feishu Output Contract

    - Current channel IR: Feishu markdown-like text IR.
    - Delivery mode: #{streaming}.
    - Feishu IR supports headings, lists, quotes, fenced code blocks, tables, and `<newmsg/>`.
    - `<newmsg/>` splits your reply into separate messages wherever it appears.
    - Keep normal replies as plain markdown-like text; do not emit Feishu JSON unless a tool explicitly asks for a native payload.
    """
    |> String.trim()
  end

  @impl true
  def im_profile, do: Nex.Agent.IMIR.Profiles.Feishu.profile()

  @impl true
  def renderer, do: Nex.Agent.IMIR.Renderers.Feishu

  @impl true
  def config_contract do
    %{
      "type" => type(),
      "label" => "Feishu",
      "ui" => %{
        "summary" => "Feishu/Lark bot websocket channel.",
        "requires" => ["app_id", "app_secret or env var", "allow_from for access control"]
      },
      "fields" => [
        "type",
        "enabled",
        "streaming",
        "app_id",
        "app_secret",
        "encrypt_key",
        "verification_token",
        "allow_from"
      ],
      "secret_fields" => ["app_secret", "encrypt_key", "verification_token"],
      "required_when_enabled" => ["app_id", "app_secret"],
      "defaults" => %{"streaming" => true},
      "options" => %{}
    }
  end

  defp required_diagnostic(instance, field, instance_id) do
    if present?(Map.get(instance, field)) do
      nil
    else
      %{
        code: :missing_required_channel_field,
        field: field,
        instance_id: instance_id,
        type: type(),
        message: "enabled feishu channel requires #{field}"
      }
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
