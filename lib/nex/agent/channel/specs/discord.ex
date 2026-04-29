defmodule Nex.Agent.Channel.Specs.Discord do
  @moduledoc false

  @behaviour Nex.Agent.Channel.Spec

  @table_modes ~w(raw ascii embed)

  @impl true
  def type, do: "discord"

  @impl true
  def gateway_module, do: Nex.Agent.Channel.Discord

  @impl true
  def apply_defaults(instance) when is_map(instance) do
    instance
    |> Map.put("type", type())
    |> Map.put_new("streaming", false)
    |> Map.put("show_table_as", normalize_table_mode(Map.get(instance, "show_table_as")))
  end

  @impl true
  def validate_instance(instance, opts) when is_map(instance) do
    instance_id = Keyword.get(opts, :instance_id)

    diagnostics =
      if Map.get(instance, "enabled", false) == true and
           not present?(Map.get(instance, "token")) do
        [
          %{
            code: :missing_required_channel_field,
            field: "token",
            instance_id: instance_id,
            type: type(),
            message: "enabled discord channel requires token"
          }
        ]
      else
        []
      end

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  @impl true
  def runtime(instance) when is_map(instance) do
    %{
      "type" => type(),
      "streaming" => Map.get(instance, "streaming", false) == true,
      "show_table_as" => normalize_table_mode(Map.get(instance, "show_table_as"))
    }
  end

  @impl true
  def format_prompt(runtime, _opts) when is_map(runtime) do
    show_table_as = Map.get(runtime, "show_table_as", "ascii")
    streaming = if Map.get(runtime, "streaming", false) == true, do: "streaming", else: "single"

    """
    ## Discord Output Contract

    - Current channel IR: Discord markdown.
    - Delivery mode: #{streaming}.
    - Discord supports bold, italic, underline (`__text__`), strikethrough, headings `#`/`##`/`###` only, lists, quotes, inline code, fenced code blocks, links, spoiler tags, and `<newmsg/>`.
    - Use paragraphs, bullets, blockquotes, and bold standalone labels for lightweight sections; reserve headings for rare major sections.
    - For compact section labels such as `Good`, `Problems`, `If I changed it`, or `问题`, write a bold line like `**Problems**`, then continue with bullets or paragraphs.
    - Never output any line starting with `####`, `#####`, or `######`, and do not wrap plain emphasis or short concept contrasts in fenced `text` blocks.
    - Discord does not support image embeds (`![]()`), horizontal rules (`---`), or HTML.
    - Markdown tables render as #{show_table_as} (`raw`, `ascii`, or `embed` channel setting).
    - `<newmsg/>` splits your reply into separate messages wherever it appears.
    """
    |> String.trim()
  end

  @impl true
  def im_profile, do: Nex.Agent.IMIR.Profiles.Discord.profile()

  @impl true
  def renderer, do: Nex.Agent.IMIR.Renderers.Discord

  @impl true
  def config_contract do
    %{
      "type" => type(),
      "label" => "Discord",
      "ui" => %{
        "summary" => "Discord Gateway bot channel.",
        "requires" => [
          "bot token or env var",
          "optional guild_id",
          "allow_from for access control"
        ]
      },
      "fields" => [
        "type",
        "enabled",
        "streaming",
        "token",
        "guild_id",
        "allow_from",
        "show_table_as"
      ],
      "secret_fields" => ["token"],
      "required_when_enabled" => ["token"],
      "defaults" => %{"streaming" => false, "show_table_as" => "ascii"},
      "options" => %{"show_table_as" => @table_modes}
    }
  end

  defp normalize_table_mode(mode) when is_binary(mode) do
    mode = mode |> String.trim() |> String.downcase()
    if mode in @table_modes, do: mode, else: "ascii"
  end

  defp normalize_table_mode(_mode), do: "ascii"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
