defmodule Nex.Agent.ContextDiagnostics do
  @moduledoc """
  Deterministic layer-boundary diagnostics for context files and write validation.
  """

  @type layer :: :agents | :identity | :soul | :user | :tools | :memory | :unknown

  @type category ::
          :persona_style_instruction_in_memory
          | :user_profile_data_in_soul
          | :identity_definition_in_soul
          | :outdated_capability_model_claim_in_agents
          | :identity_persona_instruction_in_user

  @type diagnostic :: %{
          category: category(),
          source_layer: layer(),
          source: String.t(),
          severity: :warning,
          message: String.t()
        }

  @rules [
    %{
      layer: :memory,
      category: :persona_style_instruction_in_memory,
      message:
        "MEMORY.md contains persona/style instructions; persona and style guidance belongs to SOUL.md.",
      pattern:
        ~r/\b(?:you should|you must|always|never|respond|answer|speak|write)\b[^\n]*\b(?:tone|style|persona|personality|voice|concise|formal|casual)\b/i
    },
    %{
      layer: :soul,
      category: :user_profile_data_in_soul,
      message: "SOUL.md contains user profile data; user profile details belong to USER.md.",
      pattern:
        ~r/(?:^-\s+\*\*(?:Name|Timezone|Role|Preferred Language|Language|Communication Style)\*\*:|\b(?:timezone|preferred\s+language|communication\s+style|my\s+name\s+is)\b)/im
    },
    %{
      layer: :soul,
      category: :identity_definition_in_soul,
      message:
        "SOUL.md contains durable identity definitions; core self-definition belongs to IDENTITY.md.",
      pattern:
        ~r/\b(?:i am|i'm|you are|you're|act as|pretend to be|behave as|your identity|agent identity|core identity)\b.{0,80}\b(?:claude|chatgpt|gpt[-\w]*|copilot|gemini|cursor|nanobot|llama|qwen|deepseek|assistant|agent|model|bot|ai|coding assistant|personal agent|runtime)\b/i
    },
    %{
      layer: :agents,
      category: :outdated_capability_model_claim_in_agents,
      message:
        "AGENTS.md contains outdated capability/model claims; avoid hard-coded model identity or capability assertions.",
      pattern:
        ~r/\b(?:gpt-?3\.5|gpt-?4(?:\b|\.|o)|claude[-\s]?(?:1|2|3)|llama\s?2|o1-preview|gemini\s+pro)\b/i
    },
    %{
      layer: :user,
      category: :identity_persona_instruction_in_user,
      message:
        "USER.md contains identity/persona instructions; user profile details must not redefine agent identity or persona.",
      pattern:
        ~r/\b(?:i am|i'm|my name is|you are|you're|act as|pretend to be|behave as|your persona|agent identity|system prompt|core identity)\b.{0,80}\b(?:claude|chatgpt|gpt[-\w]*|copilot|gemini|cursor|nanobot|llama|qwen|deepseek|assistant|agent|model|bot|ai)\b/i
    }
  ]

  @write_blocked_categories MapSet.new([
                              :user_profile_data_in_soul,
                              :identity_definition_in_soul,
                              :identity_persona_instruction_in_user
                            ])

  @spec scan(layer(), String.t(), keyword()) :: [diagnostic()]
  def scan(layer, content, opts \\ [])

  def scan(layer, content, opts) when is_binary(content) do
    source = Keyword.get(opts, :source, layer_to_source(layer))

    @rules
    |> Enum.filter(&(&1.layer == layer and Regex.match?(&1.pattern, content)))
    |> Enum.map(fn rule ->
      %{
        category: rule.category,
        source_layer: layer,
        source: source,
        severity: :warning,
        message: rule.message
      }
    end)
  end

  def scan(_layer, _content, _opts), do: []

  @spec validate_write(layer(), String.t(), keyword()) :: :ok | {:error, [diagnostic()]}
  def validate_write(layer, content, opts \\ [])

  def validate_write(layer, content, opts) when is_binary(content) do
    diagnostics =
      scan(layer, content, opts)
      |> Enum.filter(&MapSet.member?(@write_blocked_categories, &1.category))

    if diagnostics == [] do
      :ok
    else
      {:error, diagnostics}
    end
  end

  def validate_write(_layer, _content, _opts), do: :ok

  @spec write_error_message([diagnostic()]) :: String.t()
  def write_error_message([first | _]) do
    "Invalid content (#{first.category}): #{first.message}"
  end

  def write_error_message([]), do: "Invalid content for layer write."

  defp layer_to_source(:agents), do: "AGENTS.md"
  defp layer_to_source(:identity), do: "IDENTITY.md"
  defp layer_to_source(:soul), do: "SOUL.md"
  defp layer_to_source(:user), do: "USER.md"
  defp layer_to_source(:tools), do: "TOOLS.md"
  defp layer_to_source(:memory), do: "memory/MEMORY.md"
  defp layer_to_source(_), do: "unknown"
end
