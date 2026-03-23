defmodule Nex.Automation.Workflow do
  @moduledoc false

  defmodule Tracker do
    @moduledoc false

    defstruct kind: :github,
              owner: nil,
              repo: nil,
              ready_labels: ["nex:ready"],
              running_label: "nex:running",
              review_label: "nex:review",
              failed_label: "nex:failed"
  end

  defmodule Polling do
    @moduledoc false

    defstruct interval_ms: 30_000
  end

  defmodule Workspace do
    @moduledoc false

    defstruct [:root, :agent_root]
  end

  defmodule Agent do
    @moduledoc false

    defstruct max_concurrent_agents: 1,
              max_retry_backoff_ms: 300_000
  end

  defmodule Worker do
    @moduledoc false

    defstruct command: ["mix", "nex.agent"], timeout_ms: 3_600_000
  end

  defstruct [
    :path,
    :repo_root,
    :prompt_template,
    tracker: nil,
    polling: nil,
    workspace: nil,
    agent: nil,
    worker: nil
  ]

  @type t :: %__MODULE__{}

  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, body} <- File.read(expanded),
         {metadata, prompt_template} <- parse_document(body),
         {:ok, workflow} <- build_workflow(expanded, metadata, prompt_template) do
      {:ok, workflow}
    else
      {:error, _} = error -> error
    end
  end

  defp build_workflow(path, metadata, prompt_template) do
    repo_root = Path.dirname(path) |> Path.expand()

    tracker =
      metadata
      |> Map.get("tracker", %{})
      |> build_tracker()

    with :ok <- validate_tracker(tracker) do
      {:ok,
       %__MODULE__{
         path: path,
         repo_root: repo_root,
         prompt_template: String.trim(prompt_template),
         tracker: tracker,
         polling: build_polling(Map.get(metadata, "polling", %{})),
         workspace: build_workspace(Map.get(metadata, "workspace", %{}), repo_root),
         agent: build_agent(Map.get(metadata, "agent", %{})),
         worker: build_worker(Map.get(metadata, "worker", %{}))
       }}
    end
  end

  defp validate_tracker(%Tracker{kind: :github, owner: owner, repo: repo})
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
    :ok
  end

  defp validate_tracker(%Tracker{kind: :github, repo: repo})
       when not is_binary(repo) or repo == "" do
    {:error, "tracker.repo is required for github workflows"}
  end

  defp validate_tracker(%Tracker{kind: :github}) do
    {:error, "tracker.owner is required for github workflows"}
  end

  defp validate_tracker(%Tracker{kind: kind}) do
    {:error, "unsupported tracker.kind: #{inspect(kind)}"}
  end

  defp build_tracker(attrs) when is_map(attrs) do
    %Tracker{
      kind: normalize_tracker_kind(Map.get(attrs, "kind", "github")),
      owner: blank_to_nil(Map.get(attrs, "owner")),
      repo: blank_to_nil(Map.get(attrs, "repo")),
      ready_labels: normalize_labels(Map.get(attrs, "ready_labels"), ["nex:ready"]),
      running_label: normalize_label(Map.get(attrs, "running_label"), "nex:running"),
      review_label: normalize_label(Map.get(attrs, "review_label"), "nex:review"),
      failed_label: normalize_label(Map.get(attrs, "failed_label"), "nex:failed")
    }
  end

  defp build_tracker(_), do: %Tracker{}

  defp build_polling(attrs) when is_map(attrs) do
    %Polling{
      interval_ms: normalize_positive_integer(Map.get(attrs, "interval_ms"), 30_000)
    }
  end

  defp build_polling(_), do: %Polling{}

  defp build_workspace(attrs, repo_root) when is_map(attrs) do
    default_root = Path.join(repo_root, ".nex/orchestrator/worktrees")
    default_agent_root = Path.join(repo_root, ".nex/orchestrator/agents")

    %Workspace{
      root: expand_path(Map.get(attrs, "root"), default_root, repo_root),
      agent_root: expand_path(Map.get(attrs, "agent_root"), default_agent_root, repo_root)
    }
  end

  defp build_workspace(_, repo_root) do
    build_workspace(%{}, repo_root)
  end

  defp build_agent(attrs) when is_map(attrs) do
    %Agent{
      max_concurrent_agents:
        normalize_positive_integer(Map.get(attrs, "max_concurrent_agents"), 1),
      max_retry_backoff_ms:
        normalize_positive_integer(Map.get(attrs, "max_retry_backoff_ms"), 300_000)
    }
  end

  defp build_agent(_), do: %Agent{}

  defp build_worker(attrs) when is_map(attrs) do
    %Worker{
      command: normalize_command(Map.get(attrs, "command"), ["mix", "nex.agent"]),
      timeout_ms: normalize_positive_integer(Map.get(attrs, "timeout_ms"), 3_600_000)
    }
  end

  defp build_worker(_), do: %Worker{}

  defp parse_document(body) do
    case Regex.run(~r/^---\n(.*?)\n---\n?(.*)$/s, body) do
      [_, frontmatter, prompt_template] ->
        {parse_frontmatter(frontmatter), prompt_template}

      nil ->
        {%{}, body}
    end
  end

  defp parse_frontmatter(""), do: %{}

  defp parse_frontmatter(content) do
    parse_yaml_block(String.split(content, "\n"), 0)
  end

  defp parse_yaml_block(lines, indent) do
    {result, _rest} = do_parse_yaml_block(lines, indent, %{})
    result
  end

  defp do_parse_yaml_block([], _indent, acc), do: {acc, []}

  defp do_parse_yaml_block([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        do_parse_yaml_block(rest, indent, acc)

      current_indent < indent ->
        {acc, [line | rest]}

      String.starts_with?(trimmed, "- ") ->
        {acc, [line | rest]}

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [key, ""] ->
            next_line = List.first(rest)

            {value, remaining} =
              cond do
                is_nil(next_line) or indentation(next_line) <= current_indent ->
                  {"", rest}

                String.trim(next_line) in ["|", ">"] ->
                  parse_yaml_multiline(
                    tl(rest),
                    indentation(next_line) + 2,
                    block_scalar_style(String.trim(next_line))
                  )

                String.starts_with?(String.trim(next_line), "- ") ->
                  parse_yaml_list(rest, current_indent + 2)

                true ->
                  do_parse_yaml_block(rest, current_indent + 2, %{})
              end

            do_parse_yaml_block(remaining, indent, Map.put(acc, key, value))

          [key, value] ->
            value = String.trim(value)

            {parsed, remaining} =
              case value do
                "|" ->
                  parse_yaml_multiline(rest, current_indent + 2, :literal)

                ">" ->
                  parse_yaml_multiline(rest, current_indent + 2, :folded)

                _ ->
                  {parse_scalar(value), rest}
              end

            do_parse_yaml_block(remaining, indent, Map.put(acc, key, parsed))
        end
    end
  end

  defp parse_yaml_list(lines, indent), do: do_parse_yaml_list(lines, indent, [])

  defp do_parse_yaml_list([], _indent, acc), do: {Enum.reverse(acc), []}

  defp do_parse_yaml_list([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" ->
        do_parse_yaml_list(rest, indent, acc)

      current_indent < indent or not String.starts_with?(trimmed, "- ") ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        item =
          trimmed
          |> String.replace_prefix("- ", "")
          |> String.trim()
          |> parse_scalar()

        do_parse_yaml_list(rest, indent, [item | acc])
    end
  end

  defp parse_yaml_multiline(lines, indent, style) do
    {block_lines, remaining} = take_yaml_multiline(lines, indent, [])

    value =
      case style do
        :literal -> Enum.join(block_lines, "\n")
        :folded -> fold_yaml_lines(block_lines)
      end

    {String.trim_trailing(value), remaining}
  end

  defp take_yaml_multiline([], _indent, acc), do: {Enum.reverse(acc), []}

  defp take_yaml_multiline([line | rest], indent, acc) do
    trimmed = String.trim(line)
    current_indent = indentation(line)

    cond do
      trimmed == "" ->
        take_yaml_multiline(rest, indent, ["" | acc])

      current_indent < indent ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        content =
          if String.length(line) >= indent do
            String.slice(line, indent..-1//1)
          else
            trimmed
          end

        take_yaml_multiline(rest, indent, [String.trim_trailing(content) | acc])
    end
  end

  defp fold_yaml_lines(lines) do
    Enum.reduce(lines, "", fn
      "", "" ->
        ""

      "", acc ->
        acc <> "\n\n"

      line, "" ->
        line

      line, acc ->
        if String.ends_with?(acc, "\n\n") do
          acc <> line
        else
          acc <> " " <> line
        end
    end)
  end

  defp block_scalar_style("|"), do: :literal
  defp block_scalar_style(">"), do: :folded

  defp indentation(line) do
    String.length(line) - String.length(String.trim_leading(line))
  end

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("null"), do: nil

  defp parse_scalar(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          _ -> value
        end

      true ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value
        end
    end
  end

  defp normalize_tracker_kind("github"), do: :github
  defp normalize_tracker_kind(:github), do: :github
  defp normalize_tracker_kind(other), do: other

  defp normalize_labels(nil, default), do: default
  defp normalize_labels("", default), do: default

  defp normalize_labels(labels, _default) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_labels(labels, default) when is_binary(labels) do
    labels
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      normalized -> normalized
    end
  end

  defp normalize_labels(_, default), do: default

  defp normalize_label(nil, default), do: default
  defp normalize_label("", default), do: default
  defp normalize_label(value, _default), do: to_string(value) |> String.trim()

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_command(nil, default), do: default
  defp normalize_command("", default), do: default

  defp normalize_command(command, _default) when is_list(command) do
    command
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_command(command, default) when is_binary(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [] -> default
      parsed -> parsed
    end
  end

  defp normalize_command(_, default), do: default

  defp expand_path(nil, default, _repo_root), do: Path.expand(default)
  defp expand_path("", default, _repo_root), do: Path.expand(default)

  defp expand_path(path, _default, repo_root) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, repo_root)
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
