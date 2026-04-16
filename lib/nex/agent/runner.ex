defmodule Nex.Agent.Runner do
  @moduledoc false

  require Logger

  alias Nex.Agent.{
    Bus,
    ContextBuilder,
    MemoryUpdater,
    RequestTrace,
    Session,
    Stream.Assembler,
    Stream.Result
  }

  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Tool.Registry, as: ToolRegistry
  alias Nex.SkillRuntime

  @default_max_iterations 10
  @max_iterations_hard_limit 50
  @memory_window 50
  @max_tool_result_length 8000
  @skill_complexity_tool_calls 4
  @skill_complexity_tool_rounds 2
  @user_correction_terms [
    "actually",
    "instead",
    "that's wrong",
    "that is wrong",
    "不对",
    "应该",
    "改成",
    "不是这个"
  ]

  @doc """
  Run agent loop with session and prompt.
  """
  def run(session, prompt, opts \\ []) do
    do_run(session, prompt, opts)
  end

  defp do_run(session, prompt, opts) do
    workspace = Keyword.get(opts, :workspace)
    runtime_snapshot = runtime_snapshot_from_opts(opts)
    runtime_config = if runtime_snapshot, do: runtime_snapshot.config

    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    provider =
      Keyword.get(opts, :provider) ||
        if(runtime_config,
          do: Nex.Agent.Config.provider_to_atom(runtime_config.provider),
          else: :anthropic
        )

    model =
      Keyword.get(opts, :model) ||
        if(runtime_config, do: runtime_config.model, else: "claude-sonnet-4-20250514")

    run_id = generate_run_id()
    request_trace_config = RequestTrace.config(opts)

    Logger.info("[Runner] Starting provider=#{provider} model=#{model}")

    Logger.info(
      "[Runner] Run context run_id=#{run_id} workspace=#{workspace || "-"} " <>
        "channel=#{Keyword.get(opts, :channel) || "-"} chat_id=#{Keyword.get(opts, :chat_id) || "-"} " <>
        "base_url=#{Keyword.get(opts, :base_url) || "-"} api_key_present=#{value_present?(Keyword.get(opts, :api_key))} " <>
        "request_trace_enabled=#{request_trace_config["enabled"] == true}"
    )

    opts =
      opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:model, model)
      |> Keyword.put(:run_id, run_id)
      |> maybe_put_opt(:runtime_snapshot, runtime_snapshot)
      |> maybe_put_opt(:runtime_version, runtime_snapshot && runtime_snapshot.version)
      |> Keyword.put(:request_trace, request_trace_config)
      |> Keyword.put(:skill_runtime, SkillRuntime.config(opts))
      |> Keyword.put_new(:_evolution_signals, default_evolution_signals())
      |> init_stream_assembler()

    initial_message_count = length(session.messages)
    {session, runtime_system_messages} = prepare_evolution_turn(session, prompt, opts)

    {session, runtime_system_messages, prepared_run} =
      prepare_skill_runtime_turn(session, prompt, runtime_system_messages, opts)

    history_limit = Keyword.get(opts, :history_limit, @memory_window)
    history = Session.get_history(session, history_limit)

    channel = Keyword.get(opts, :channel, "telegram")
    chat_id = Keyword.get(opts, :chat_id, "default")
    media = Keyword.get(opts, :media)

    trace_request_started(prompt, channel, chat_id, prepared_run, runtime_system_messages, opts)

    messages =
      ContextBuilder.build_messages(history, prompt, channel, chat_id, media,
        system_prompt: runtime_system_prompt(runtime_snapshot),
        skip_skills: Keyword.get(opts, :skip_skills, false),
        workspace: workspace,
        runtime_system_messages: runtime_system_messages,
        cwd: Keyword.get(opts, :cwd)
      )

    session =
      Session.add_message(session, "user", prompt, project: Keyword.get(opts, :project))

    Logger.info(
      "[Runner] LLM request prepared run_id=#{run_id} history=#{length(history)} " <>
        "messages=#{length(messages)} message_stats=#{message_stats_log(messages)} " <>
        "runtime_system_messages=#{length(runtime_system_messages)} " <>
        "selected_skill_packages=#{length(prepared_run.selected_packages)}"
    )

    opts = Keyword.put(opts, :skill_runtime_prepared_run, prepared_run)

    case run_loop(session, messages, 0, max_iterations, opts) do
      {:ok, result, final_session} ->
        final_session =
          finalize_skill_runtime_run(
            final_session,
            initial_message_count,
            prompt,
            result,
            prepared_run,
            opts
          )

        trace_request_completed("completed", result, opts)

        {:ok, result,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace, opts)}

      {:error, reason, final_session} ->
        final_session =
          finalize_skill_runtime_run(
            final_session,
            initial_message_count,
            prompt,
            reason,
            prepared_run,
            opts,
            status: "failed"
          )

        trace_request_completed("failed", reason, opts)

        {:error, reason,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace, opts)}
    end
  end

  defp prepare_evolution_turn(session, prompt, _opts) do
    metadata =
      evolution_metadata(session)
      |> Map.put("last_prompt", prompt)

    runtime_system_messages =
      []
      |> maybe_add_memory_nudge(metadata)
      |> maybe_add_skill_nudge(metadata)

    {put_evolution_metadata(session, metadata), runtime_system_messages}
  end

  defp finalize_evolution_turn(session, initial_message_count, prompt, workspace, opts) do
    signals =
      session.messages
      |> Enum.drop(initial_message_count)
      |> collect_evolution_signals(prompt)

    metadata =
      session
      |> evolution_metadata()
      |> Map.put("turns_since_memory_write", next_memory_turn_count(session, signals))
      |> Map.put("pending_skill_nudge", next_skill_nudge(session, signals))

    session = put_evolution_metadata(session, metadata)
    maybe_enqueue_memory_refresh(session, workspace, opts)
    session
  end

  defp prepare_skill_runtime_turn(session, prompt, runtime_system_messages, opts) do
    if Keyword.get(opts, :skip_skills, false) do
      {session, runtime_system_messages, %Nex.SkillRuntime.PreparedRun{}}
    else
      case SkillRuntime.prepare_run(prompt, opts) do
        {:ok, prepared_run} ->
          metadata =
            Map.put(session.metadata || %{}, "skill_runtime", %{
              "selected_packages" =>
                Enum.map(prepared_run.selected_packages, &package_metadata/1),
              "ephemeral_tools" => Enum.map(prepared_run.ephemeral_tools, &Map.get(&1, "name"))
            })

          skill_guard = selected_skill_guard(prepared_run.selected_packages)

          warnings =
            case prepared_run.availability_warnings do
              [] -> []
              list -> ["[Skill Runtime] Warnings: " <> Enum.join(list, "; ")]
            end

          {%{session | metadata: metadata},
           runtime_system_messages ++ skill_guard ++ prepared_run.prompt_fragments ++ warnings,
           prepared_run}

        {:error, reason} ->
          Logger.warning("[Runner] SkillRuntime prepare_run failed: #{reason}")
          {session, runtime_system_messages, %Nex.SkillRuntime.PreparedRun{}}
      end
    end
  end

  defp package_metadata(package) do
    %{
      "skill_id" => package.skill_id,
      "name" => package.name,
      "execution_mode" => package.execution_mode,
      "tool_name" => package.tool_name
    }
  end

  defp selected_skill_guard([]), do: []

  defp selected_skill_guard(packages) do
    names =
      packages
      |> Enum.map(& &1.name)
      |> Enum.join(", ")

    [
      "[Skill Runtime] Selected skill packages for this turn are authoritative: #{names}. " <>
        "Follow their workflow exactly. Do not replace a concrete skill-specified command, " <>
        "renderer, output path, or delivery step with an ad-hoc bash/python/html workaround. " <>
        "Only use a fallback after you actually attempted the primary path and observed it fail. " <>
        "If a selected skill says to deliver an image/file/artifact, send that artifact instead " <>
        "of a descriptive text summary whenever the primary step succeeded."
    ]
  end

  defp finalize_skill_runtime_run(
         session,
         initial_message_count,
         prompt,
         result,
         prepared_run,
         opts,
         extra \\ []
       ) do
    if Keyword.get(opts, :skill_runtime, %{})["enabled"] == true do
      delta_messages = Enum.drop(session.messages, initial_message_count)
      tool_messages = Enum.filter(delta_messages, &(Map.get(&1, "role") == "tool"))

      trace = %{
        run_id: Keyword.get(opts, :run_id) || generate_run_id(),
        prompt: prompt,
        selected_packages: Enum.map(prepared_run.selected_packages, &package_metadata/1),
        tool_messages: tool_messages,
        result: result,
        status: Keyword.get(extra, :status, "completed"),
        inserted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      _ = SkillRuntime.record_run(trace, opts)

      if Keyword.get(opts, :skill_runtime, %{})["post_run_analysis"] == true do
        _ = SkillRuntime.evolve(trace, opts)
      end
    end

    session
  end

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    iter_start = System.monotonic_time(:millisecond)
    Logger.info("[Runner] === Iteration #{iteration + 1}/#{max_iterations} started ===")

    if iteration >= max_iterations do
      Logger.warning("[Runner] Max iterations reached (#{max_iterations})")
      {:error, :max_iterations_exceeded, session}
    else
      # Time the LLM call
      llm_start = System.monotonic_time(:millisecond)

      llm_result =
        try do
          call_llm_with_retry(
            messages,
            Keyword.put(opts, :trace_iteration, iteration + 1),
            _retries = 1
          )
        rescue
          e ->
            Logger.error("[Runner] LLM call crashed: #{Exception.message(e)}")
            {:error, "LLM call failed: #{Exception.message(e)}"}
        catch
          kind, reason ->
            Logger.error("[Runner] LLM call crashed: #{kind} #{inspect(reason)}")
            {:error, "LLM call failed: #{kind} #{inspect(reason)}"}
        end

      llm_duration = System.monotonic_time(:millisecond) - llm_start
      Logger.info("[Runner] LLM call took #{llm_duration}ms")

      case llm_result do
        {:ok, response} ->
          content = response.content
          finish_reason = Map.get(response, :finish_reason)
          trace_llm_response(iteration + 1, response, llm_duration, opts)

          reasoning_content =
            Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content")

          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

          if finish_reason == "error" do
            # Nanobot parity: keep the user turn, but never persist the assistant error response.
            Logger.error("[Runner] LLM returned error finish_reason")
            iter_total = System.monotonic_time(:millisecond) - iter_start

            Logger.info(
              "[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms (error) ==="
            )

            reason = "LLM returned an error"
            emit_stream_error(opts, reason)
            {:error, stream_result(:error, opts, nil, %{error: reason}), session}
          else
            {response, opts} = take_stream_assembler(response, opts)

            opts =
              if Map.get(response, :streamed_text, false) do
                Keyword.put(opts, :_llm_text_streamed, true)
              else
                opts
              end

            result =
              handle_response(
                session,
                messages,
                content,
                tool_calls,
                reasoning_content,
                iteration,
                max_iterations,
                _on_progress = nil,
                opts
              )

            iter_total = System.monotonic_time(:millisecond) - iter_start
            Logger.info("[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms ===")
            result
          end

        {:error, reason} ->
          Logger.error("[Runner] LLM call failed: #{inspect(reason)}")
          emit_stream_error(opts, reason)
          iter_total = System.monotonic_time(:millisecond) - iter_start

          Logger.info(
            "[Runner] === Iteration #{iteration + 1} finished in #{iter_total}ms (failed) ==="
          )

          {:error, stream_result(:error, opts, nil, %{error: reason}), session}
      end
    end
  end

  @max_loop_repeats 3

  defp handle_response(
         session,
         messages,
         content,
         tool_calls,
         reasoning_content,
         iteration,
         max_iterations,
         _on_progress,
         opts
       )
       when is_list(tool_calls) and tool_calls != [] do
    Logger.info("[Runner] LLM requests #{length(tool_calls)} tool call(s)")

    if Keyword.get(opts, :_suppress_current_reply_stream, false) do
      tool_call_dicts = normalize_tool_calls(tool_calls)

      messages =
        ContextBuilder.add_assistant_message(
          messages,
          content,
          tool_call_dicts,
          reasoning_content
        )

      session =
        Session.add_message(session, "assistant", content,
          tool_calls: tool_call_dicts,
          reasoning_content: reasoning_content
        )

      {new_messages, results, session, opts} =
        execute_tools(session, messages, tool_call_dicts, opts)

      opts = maybe_emit_tool_result_events(opts, results)
      maybe_publish_tool_results(results, opts)

      run_loop(session, new_messages, iteration + 1, max_iterations, opts)
    else
    tool_call_dicts = normalize_tool_calls(tool_calls)

    current_signatures =
      tool_call_dicts
      |> Enum.map(fn tc ->
        name = get_in(tc, ["function", "name"])
        args = get_in(tc, ["function", "arguments"]) || ""
        {name, tool_loop_signature(name, args)}
      end)
      |> Enum.sort()

    tool_history = Keyword.get(opts, :_tool_history, [])
    tool_history = [current_signatures | tool_history] |> Enum.take(@max_loop_repeats)

    # Detect loop: exact same {tool_name, args} pattern repeated N times consecutively
    if length(tool_history) >= @max_loop_repeats and
         tool_history |> Enum.take(@max_loop_repeats) |> Enum.uniq() |> length() == 1 do
      Logger.warning(
        "[Runner] Loop detected: #{inspect(current_signatures)} repeated #{@max_loop_repeats}x, breaking"
      )

      final_content =
        render_text(content) ||
          "I detected a repeated action loop and stopped. Please try a different approach."

      opts =
        opts
        |> maybe_emit_text_delta(final_content)
        |> maybe_emit_message_end(final_content)

      {:ok, stream_result(:ok, opts, final_content), session}
    else
      opts = Keyword.put(opts, :_tool_history, tool_history)

      existing_suppress? = Keyword.get(opts, :_suppress_current_reply_stream, false)

      suppress_current_reply_stream? =
        existing_suppress? or
          Enum.any?(tool_call_dicts, fn tc ->
            get_in(tc, ["function", "name"]) == "message" and
              message_tool_call_targets_current_conversation?(tc, opts)
          end)

      opts =
        if suppress_current_reply_stream? do
          opts
          |> Keyword.put(:_suppress_current_reply_stream, true)
          |> suppress_stream_output(true)
        else
          opts
        end

      opts =
        if suppress_current_reply_stream? do
          opts
        else
          maybe_emit_text_commit(opts, content)
        end

      opts = maybe_emit_tool_call_start_events(opts, tool_call_dicts)

      messages =
        ContextBuilder.add_assistant_message(
          messages,
          content,
          tool_call_dicts,
          reasoning_content
        )

      session =
        Session.add_message(session, "assistant", content,
          tool_calls: tool_call_dicts,
          reasoning_content: reasoning_content
        )

      {new_messages, results, session, opts} =
        execute_tools(session, messages, tool_call_dicts, opts)

      opts = maybe_emit_tool_result_events(opts, results)
      maybe_publish_tool_results(results, opts)

      message_sent_to_current_channel =
        Enum.any?(results, fn {_id, name, _r, args} ->
          name == "message" and message_targets_current_conversation?(args, opts)
        end)

      effective_max =
        if iteration + 1 >= max_iterations and iteration + 1 < @max_iterations_hard_limit and
             not Keyword.has_key?(opts, :tools_filter) and
             not Keyword.get(opts, :_expanded, false) do
          new_max = min(max_iterations * 2, @max_iterations_hard_limit)
          Logger.info("[Runner] Auto-expanding max_iterations #{max_iterations} -> #{new_max}")
          new_max
        else
          max_iterations
        end

      opts =
        if effective_max > max_iterations,
          do: Keyword.put(opts, :_expanded, true),
          else: opts

      case run_loop(session, new_messages, iteration + 1, effective_max, opts) do
        {:ok, _final_content, final_session} when message_sent_to_current_channel ->
          {:ok, stream_result(:ok, opts, nil, %{message_sent: true}), final_session}

        other ->
          other
      end
    end
  end
  end

  defp handle_response(
         session,
         _messages,
         content,
         _tool_calls,
         reasoning_content,
         _iteration,
         _max_iterations,
         _on_progress,
         opts
       ) do
    content_text = render_text(content)

    Logger.info("[Runner] LLM finished: #{String.slice(content_text, 0, 100)}")

    opts =
      unless Keyword.get(opts, :_llm_text_streamed, false) or
               Keyword.get(opts, :_suppress_current_reply_stream, false) do
        opts
        |> maybe_emit_text_delta(content_text)
        |> maybe_emit_message_end(content_text)
      else
        opts
      end

    session =
      Session.add_message(session, "assistant", content_text,
        reasoning_content: reasoning_content
      )

    final_content =
      if Keyword.get(opts, :_suppress_current_reply_stream, false), do: nil, else: content_text

    metadata =
      if Keyword.get(opts, :_suppress_current_reply_stream, false), do: %{message_sent: true}, else: %{}

    {:ok, stream_result(:ok, opts, final_content, metadata), session}
  end

  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

      name =
        Map.get(tc, :name) || Map.get(tc, "name") || Map.get(func, "name") ||
          Map.get(func, :name)

      arguments =
        Map.get(tc, :arguments) || Map.get(tc, "arguments") ||
          Map.get(func, "arguments") || Map.get(func, :arguments) || %{}

      %{
        "id" => Map.get(tc, :id) || Map.get(tc, "id") || generate_tool_call_id(),
        "type" => "function",
        "function" => %{
          "name" => name,
          "arguments" => if(is_binary(arguments), do: arguments, else: Jason.encode!(arguments))
        }
      }
    end)
  end

  defp maybe_emit_text_delta(opts, text),
    do: update_stream_assembler(opts, &Assembler.emit_text_delta(&1, text))

  defp maybe_emit_text_commit(opts, content),
    do: update_stream_assembler(opts, &Assembler.emit_text_commit(&1, content))

  defp maybe_emit_tool_call_start_events(opts, tool_call_dicts),
    do: update_stream_assembler(opts, &Assembler.emit_tool_call_start_events(&1, tool_call_dicts))

  defp maybe_emit_tool_result_events(opts, results),
    do: update_stream_assembler(opts, &Assembler.emit_tool_result_events(&1, results))

  defp maybe_emit_message_end(opts, _content_text),
    do: update_stream_assembler(opts, &Assembler.emit_message_end/1)

  defp emit_stream_error(opts, reason),
    do: update_stream_assembler(opts, &Assembler.emit_error(&1, reason))

  defp stream_result(status, opts, final_content, metadata \\ %{})

  defp stream_result(:ok, opts, final_content, metadata) do
    if streaming_result?(opts) do
      Result.ok(Keyword.get(opts, :run_id) || "run_unknown", final_content, metadata)
    else
      if Map.get(metadata, :message_sent) == true or Map.get(metadata, "message_sent") == true do
        :message_sent
      else
        final_content
      end
    end
  end

  defp stream_result(:error, opts, final_content, metadata) do
    reason = Map.get(metadata, :error) || Map.get(metadata, "error")

    if streaming_result?(opts) do
      Result.error(Keyword.get(opts, :run_id) || "run_unknown", reason, final_content, metadata)
    else
      reason
    end
  end

  defp streaming_result?(opts), do: is_function(Keyword.get(opts, :stream_sink), 1)

  defp maybe_publish_tool_results(results, opts) do
    if Process.whereis(Nex.Agent.Bus) do
      Enum.each(results, fn {_id, tool_name, result, args} ->
        success = not String.starts_with?(render_text(result), "Error")

        Bus.publish(:tool_result, %{
          tool: tool_name,
          success: success,
          result: truncate_result(result),
          args: summarize_args(tool_name, args),
          channel: Keyword.get(opts, :channel),
          chat_id: Keyword.get(opts, :chat_id)
        })
      end)
    end
  end

  defp truncate_result(result)
       when is_binary(result) and byte_size(result) > @max_tool_result_length do
    String.slice(result, 0, @max_tool_result_length) <> "\n... (truncated)"
  end

  defp truncate_result(result) when is_binary(result), do: result
  defp truncate_result(result), do: inspect(result)

  defp summarize_args("bash", %{"command" => cmd}) when is_binary(cmd), do: %{"command" => cmd}
  defp summarize_args("bash", %{command: cmd}) when is_binary(cmd), do: %{"command" => cmd}

  defp summarize_args(_tool_name, args) when is_map(args) do
    args
    |> Enum.take(3)
    |> Map.new(fn {k, v} ->
      v_str = if is_binary(v), do: String.slice(v, 0, 100), else: inspect(v, limit: 3)
      {to_string(k), v_str}
    end)
  end

  defp summarize_args(_tool_name, _args), do: %{}

  defp message_targets_current_conversation?(args, opts) do
    current_channel = Keyword.get(opts, :channel)

    if is_binary(current_channel) do
      message_targets_current_conversation_with_channel?(args, opts, current_channel)
    else
      false
    end
  end

  defp message_targets_current_conversation_with_channel?(args, opts, current_channel)
       when is_map(args) do
    current_chat_id = normalize_chat_id(Keyword.get(opts, :chat_id))

    target_channel =
      Map.get(args, "channel") || Map.get(args, :channel) || current_channel

    target_chat_id =
      Map.get(args, "chat_id") || Map.get(args, :chat_id) || current_chat_id

    target_channel == current_channel and normalize_chat_id(target_chat_id) == current_chat_id
  end

  defp message_targets_current_conversation_with_channel?(_args, _opts, _current_channel),
    do: false

  defp message_tool_call_targets_current_conversation?(tool_call, opts) when is_map(tool_call) do
    args = get_in(tool_call, ["function", "arguments"]) || %{}
    message_targets_current_conversation?(parse_tool_arguments(args), opts)
  end

  defp message_tool_call_targets_current_conversation?(_tool_call, _opts), do: false

  defp normalize_chat_id(nil), do: ""
  defp normalize_chat_id(chat_id), do: to_string(chat_id)

  defp call_llm_with_retry(messages, opts, retries_left) do
    case call_llm(messages, opts) do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        cond do
          retries_left > 0 and transient_error?(reason) ->
            Logger.warning("[Runner] LLM transient error, retrying in 2s: #{inspect(reason)}")
            Process.sleep(2_000)
            call_llm_with_retry(messages, opts, retries_left - 1)

          not Keyword.get(opts, :__recovered, false) ->
            case attempt_recovery(reason, messages, opts) do
              {:retry, new_messages, new_opts} ->
                new_opts = Keyword.put(new_opts, :__recovered, true)
                call_llm_with_retry(new_messages, new_opts, 0)

              :give_up ->
                error
            end

          true ->
            error
        end
    end
  end

  # Analyze LLM error and attempt automatic recovery.
  defp attempt_recovery(reason, messages, opts) do
    error_msg = extract_error_message(reason)
    status = extract_error_status(reason)

    Logger.warning(
      "[Runner] Recovery analysis run_id=#{Keyword.get(opts, :run_id)} status=#{inspect(status)} " <>
        "message_count=#{length(messages)} error=#{inspect(String.slice(to_string(error_msg), 0, 300))}"
    )

    cond do
      # 400: context too long → trim older messages
      status == 400 and context_length_error?(error_msg) ->
        trimmed = trim_messages(messages)

        if length(trimmed) < length(messages) do
          Logger.warning(
            "[Runner] Context too long (#{length(messages)} msgs), trimmed to #{length(trimmed)}"
          )

          {:retry, trimmed, opts}
        else
          :give_up
        end

      # 400: other known patterns can be added here
      true ->
        :give_up
    end
  end

  defp extract_error_message(%{error: %{"error" => %{"message" => msg}}}), do: msg
  defp extract_error_message(%{error: %{message: msg}}), do: msg
  defp extract_error_message(msg) when is_binary(msg), do: msg
  defp extract_error_message(other), do: inspect(other)

  defp extract_error_status(%{status: status}), do: status
  defp extract_error_status(_), do: nil

  defp context_length_error?(msg) do
    String.contains?(msg, "context_length") or
      String.contains?(msg, "too long") or
      String.contains?(msg, "maximum context") or
      String.contains?(msg, "token")
  end

  # Trim messages by removing older turns, keeping system + first user + recent messages.
  defp trim_messages(messages) when length(messages) <= 4, do: messages

  defp trim_messages(messages) do
    # Keep first 2 messages (system prompt + first user) and last half
    keep_recent = max(div(length(messages), 2), 4)
    first = Enum.take(messages, 2)
    recent = Enum.take(messages, -keep_recent)
    recent_start = max(length(messages) - length(recent), 0)
    recent = repair_leading_tool_boundary(messages, recent, recent_start)
    Enum.uniq(first ++ recent)
  end

  defp repair_leading_tool_boundary(_messages, [], _start_idx), do: []

  defp repair_leading_tool_boundary(messages, window, start_idx) do
    if tool_message?(hd(window)) do
      tool_ids = leading_tool_call_ids(window)

      case find_matching_assistant_before(messages, start_idx, tool_ids) do
        nil -> Enum.drop_while(window, &tool_message?/1)
        assistant -> [assistant | window]
      end
    else
      window
    end
  end

  defp leading_tool_call_ids(window) do
    window
    |> Enum.take_while(&tool_message?/1)
    |> Enum.map(&Map.get(&1, "tool_call_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp find_matching_assistant_before(_messages, start_idx, _tool_ids) when start_idx <= 0,
    do: nil

  defp find_matching_assistant_before(messages, start_idx, tool_ids) do
    candidate =
      messages
      |> Enum.take(start_idx)
      |> Enum.reverse()
      |> Enum.drop_while(&tool_message?/1)
      |> List.first()

    if assistant_message_with_tool_calls?(candidate, tool_ids), do: candidate, else: nil
  end

  defp assistant_message_with_tool_calls?(%{"role" => "assistant"} = message, tool_ids) do
    message_tool_ids =
      message
      |> Map.get("tool_calls", [])
      |> Enum.map(fn tool_call -> Map.get(tool_call, "id") || Map.get(tool_call, :id) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    tool_ids != [] and Enum.all?(tool_ids, &MapSet.member?(message_tool_ids, &1))
  end

  defp assistant_message_with_tool_calls?(_message, _tool_ids), do: false

  defp tool_message?(%{"role" => "tool"}), do: true
  defp tool_message?(_message), do: false

  defp transient_error?(%{__struct__: struct}) do
    struct_name = to_string(struct)
    String.contains?(struct_name, "TransportError") or String.contains?(struct_name, "Mint")
  end

  defp transient_error?(%{status: status}) when status in [429, 500, 502, 503, 504], do: true
  defp transient_error?(:timeout), do: true
  defp transient_error?(:closed), do: true
  defp transient_error?(reason) when is_binary(reason), do: String.contains?(reason, "timeout")
  defp transient_error?(_), do: false

  defp call_llm(messages, opts) do
    tools =
      case Keyword.get(opts, :tools_filter) do
        :subagent -> registry_definitions(:subagent, opts)
        :cron -> registry_definitions(:cron, opts)
        _ -> registry_definitions(:all, opts)
      end

    opts = Keyword.put(opts, :tools, tools)

    Logger.info(
      "[Runner] Dispatching LLM call run_id=#{Keyword.get(opts, :run_id)} " <>
        "iteration=#{Keyword.get(opts, :trace_iteration)} provider=#{Keyword.get(opts, :provider)} " <>
        "model=#{Keyword.get(opts, :model)} base_url=#{Keyword.get(opts, :base_url) || "-"} " <>
        "tool_count=#{length(tools)} tool_choice=#{inspect(Keyword.get(opts, :tool_choice))} " <>
        "message_stats=#{message_stats_log(messages)}"
    )

    trace_llm_request(Keyword.get(opts, :trace_iteration), messages, tools, opts)

    call_llm_stream(messages, opts)
  end

  # Tool names must start with a letter and contain only letters, numbers, underscores, dashes.
  @valid_tool_name ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/

  defp registry_definitions(filter, opts) do
    runtime_definitions =
      case Keyword.get(opts, :runtime_snapshot) do
        %Snapshot{} = snapshot -> snapshot_tool_definitions(snapshot, filter)
        _ -> nil
      end

    if is_list(runtime_definitions) do
      runtime_definitions
      |> append_ephemeral_tools(opts)
      |> normalize_tool_definitions()
    else
      registry_definitions_from_registry(filter, opts)
    end
  end

  defp registry_definitions_from_registry(filter, opts) do
    if Process.whereis(ToolRegistry) do
      ToolRegistry.definitions(filter)
      |> append_ephemeral_tools(opts)
      |> normalize_tool_definitions()
    else
      []
    end
  end

  defp append_ephemeral_tools(definitions, opts) do
    runtime_tools =
      opts
      |> Keyword.get(:skill_runtime_prepared_run, %Nex.SkillRuntime.PreparedRun{})
      |> Map.get(:ephemeral_tools, [])

    definitions ++ runtime_tools
  end

  defp normalize_tool_definitions(definitions) do
    definitions
    |> Enum.filter(fn tool ->
      name = tool["name"]

      if valid_tool_name?(name) do
        true
      else
        Logger.warning("[Runner] Dropping tool with invalid name: #{inspect(name)}")
        false
      end
    end)
    |> Enum.uniq_by(& &1["name"])
  end

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, :subagent),
    do: snapshot.tools.definitions_subagent

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, :cron),
    do: snapshot.tools.definitions_cron

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, _filter),
    do: snapshot.tools.definitions_all

  defp valid_tool_name?(name) when is_binary(name), do: Regex.match?(@valid_tool_name, name)
  defp valid_tool_name?(_), do: false

  defp runtime_system_prompt(%Snapshot{} = snapshot), do: snapshot.prompt.system_prompt
  defp runtime_system_prompt(_), do: nil

  defp runtime_snapshot_from_opts(opts) do
    case Keyword.get(opts, :runtime_snapshot) do
      %Snapshot{} = snapshot ->
        snapshot

      _ ->
        nil
    end
  end

  defp call_llm_stream(messages, opts) do
    assembler =
      Keyword.get_lazy(opts, :_stream_assembler, fn ->
        Assembler.new(
          mode: :conversation,
          run_id: Keyword.get(opts, :run_id) || "run_unknown",
          sink: Keyword.get(opts, :stream_sink),
          suppress_output?: Keyword.get(opts, :_suppress_current_reply_stream, false)
        )
      end)
      |> Assembler.prepare_next_response()

    stream_fun = fn callback ->
      if opts[:llm_stream_client] do
        opts[:llm_stream_client].(messages, opts, callback)
      else
        call_req_llm_stream(messages, opts, callback)
      end
    end

    case Assembler.drain_stream(stream_fun, assembler, :runner_stream_event) do
      {:ok, assembler} ->
        {assembler, response} = Assembler.finalize(assembler)

        if response.error do
          {:error, response.error}
        else
          {:ok, Map.put(response, :_stream_assembler, assembler)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_req_llm_stream(messages, opts, callback) do
    provider = Keyword.get(opts, :provider, :anthropic)

    stream_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        tools: Keyword.get(opts, :tools, []),
        temperature: Keyword.get(opts, :temperature, 1.0),
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        tool_choice: Keyword.get(opts, :tool_choice)
      ]
      |> maybe_put_opt(:req_llm_stream_text_fun, Keyword.get(opts, :req_llm_stream_text_fun))

    Nex.Agent.LLM.ReqLLM.stream(messages, stream_opts, callback)
  end

  defp execute_tools(session, messages, tool_calls, opts) do
    ctx = build_tool_ctx(opts)

    # Pre-extract tool metadata before async execution so it survives task crashes
    indexed_calls =
      Enum.map(tool_calls, fn tc ->
        func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

        tool_name =
          Map.get(tc, :name) || Map.get(tc, "name") || Map.get(func, "name") ||
            Map.get(func, :name)

        tool_call_id = Map.get(tc, :id) || Map.get(tc, "id") || generate_tool_call_id()

        args =
          Map.get(tc, :arguments) || Map.get(tc, "arguments") || Map.get(func, "arguments") ||
            Map.get(func, :arguments) || %{}

        {tool_call_id, tool_name, args}
      end)

    results =
      indexed_calls
      |> Task.async_stream(
        fn {tool_call_id, tool_name, args} ->
          parsed_args = parse_args(args)
          Logger.info("[Runner] Executing tool: #{tool_name}(#{inspect(parsed_args)})")
          tool_started_at = System.monotonic_time(:millisecond)

          result = execute_tool(tool_name, parsed_args, ctx)
          truncated = truncate_result(result)
          tool_duration_ms = System.monotonic_time(:millisecond) - tool_started_at

          Logger.info(
            "[Runner] Tool completed: #{tool_name} duration_ms=#{tool_duration_ms} " <>
              "result_preview=#{inspect(String.slice(render_text(truncated), 0, 160))}"
          )

          {tool_call_id, tool_name, truncated, parsed_args}
        end,
        ordered: true,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(indexed_calls)
      |> Enum.map(fn
        {{:ok, result}, _meta} ->
          result

        {{:exit, reason}, {tool_call_id, tool_name, args}} ->
          Logger.error("[Runner] Tool task exited: #{tool_name} #{inspect(reason)}")

          {tool_call_id, tool_name, "Error: tool timed out or crashed (#{inspect(reason)})",
           parse_args(args)}
      end)

    {new_messages, session} =
      Enum.reduce(results, {messages, session}, fn {tool_call_id, tool_name, result, _args},
                                                   {msgs, sess} ->
        trace_tool_result(tool_call_id, tool_name, result, opts)
        msgs = ContextBuilder.add_tool_result(msgs, tool_call_id, tool_name, result)

        sess =
          Session.add_message(sess, "tool", result, tool_call_id: tool_call_id, name: tool_name)

        {msgs, sess}
      end)

    {new_messages, results, session, update_evolution_signals(opts, results)}
  end

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} ->
        map

      _ ->
        case Nex.Agent.LLM.JsonRepair.repair_and_decode(args) do
          {:ok, map} -> map
          _ -> %{}
        end
    end
  end

  defp parse_args([head | _rest]) when is_map(head), do: head
  defp parse_args([]), do: %{}
  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}

  defp tool_loop_signature("tool_create", args) do
    parsed = parse_args(args)
    Map.get(parsed, "name") || Map.get(parsed, :name) || args
  end

  defp tool_loop_signature(_name, args), do: args

  @doc false
  def parse_tool_arguments(args), do: parse_args(args)

  defp execute_tool(tool_name, args, ctx) do
    if String.starts_with?(tool_name, "skill_run__") do
      case SkillRuntime.execute_ephemeral_tool(tool_name, args, ctx) do
        {:ok, result} when is_binary(result) -> result
        {:ok, result} when is_map(result) -> Jason.encode!(result, pretty: true)
        {:ok, result} -> render_text(result)
        {:error, reason} -> "Error: #{reason}"
      end
    else
      if Process.whereis(ToolRegistry) do
        case ToolRegistry.execute(tool_name, args, ctx) do
          {:ok, result} when is_binary(result) ->
            result

          {:ok, %{content: content}} when is_binary(content) ->
            content

          {:ok, %{error: error}} ->
            "Error: #{error}"

          {:ok, result} when is_map(result) ->
            Jason.encode!(result, pretty: true)

          {:ok, result} ->
            render_text(result)

          {:error, reason} ->
            "Error: #{reason}"

          %{content: content} when is_binary(content) ->
            Logger.warning(
              "[Runner] Tool #{tool_name} returned non-standard bare map result; coercing to success"
            )

            content

          %{error: error} ->
            Logger.warning(
              "[Runner] Tool #{tool_name} returned non-standard bare error map; coercing to error"
            )

            "Error: #{error}"

          result when is_map(result) ->
            Logger.warning(
              "[Runner] Tool #{tool_name} returned non-standard bare map result; coercing to success"
            )

            Jason.encode!(result, pretty: true)

          result ->
            Logger.warning(
              "[Runner] Tool #{tool_name} returned non-standard result #{inspect(result, limit: 50)}; coercing to text"
            )

            render_text(result)
        end
      else
        "Error: tool registry unavailable"
      end
    end
  end

  defp build_tool_ctx(opts) do
    %{
      channel: Keyword.get(opts, :channel),
      chat_id: Keyword.get(opts, :chat_id),
      session_key: Keyword.get(opts, :session_key),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      tools: Keyword.get(opts, :tools, %{}),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      workspace: Keyword.get(opts, :workspace),
      project: Keyword.get(opts, :project),
      metadata: Keyword.get(opts, :metadata, %{}),
      skill_runtime: Keyword.get(opts, :skill_runtime, %{}),
      skill_runtime_prepared_run: Keyword.get(opts, :skill_runtime_prepared_run)
    }
  end

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  defp generate_run_id do
    "run_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  @doc """
  Call LLM for memory consolidation - exposes for Memory module.
  """
  def call_llm_for_consolidation(messages, opts) do
    provider = Keyword.get(opts, :provider, :anthropic)
    tool_choice = Keyword.get(opts, :tool_choice)

    call_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        tools: Keyword.get(opts, :tools, []),
        tool_choice: tool_choice
      ]
      |> maybe_put_opt(:req_llm_stream_text_fun, Keyword.get(opts, :req_llm_stream_text_fun))

    Logger.info(
      "[Runner] consolidation LLM call: provider=#{provider} model=#{Keyword.get(call_opts, :model)} tool_choice=#{inspect(tool_choice)}"
    )

    case call_llm_stream_for_consolidation(messages, call_opts) do
      {:ok, response} ->
        Logger.info(
          "[Runner] consolidation LLM response: finish_reason=#{inspect(Map.get(response, :finish_reason))} has_tool_calls=#{is_list(Map.get(response, :tool_calls) || Map.get(response, "tool_calls"))} content_preview=#{inspect(String.slice(to_string(Map.get(response, :content, "")), 0, 100))}"
        )

        extract_tool_call(response)

      {:error, err} ->
        Logger.warning("[Runner] consolidation LLM error: #{inspect(err, limit: 300)}")

        case consolidation_tool_choice_retry_reason(provider, tool_choice, err) do
          nil ->
            {:error, err}

          reason ->
            Logger.warning("[Runner] #{consolidation_tool_choice_retry_message(reason)}")
            retry_opts = Keyword.delete(call_opts, :tool_choice)

            case call_llm_stream_for_consolidation(messages, retry_opts) do
              {:ok, response} -> extract_tool_call(response)
              error -> error
            end
        end

      error ->
        Logger.error("[Runner] consolidation unexpected error: #{inspect(error, limit: 300)}")
        error
    end
  end

  defp call_llm_stream_for_consolidation(messages, opts) do
    assembler = Assembler.new(mode: :consolidation)

    stream_fun = fn callback ->
      Nex.Agent.LLM.ReqLLM.stream(messages, opts, callback)
    end

    case Assembler.drain_stream(stream_fun, assembler, :runner_consolidation_stream_event) do
      {:ok, assembler} ->
        {_assembler, response} = Assembler.finalize(assembler)

        if response.error do
          {:error, response.error}
        else
          {:ok, Map.delete(response, :streamed_text)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_tool_call(response) do
    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls")

    if is_list(tool_calls) and tool_calls != [] do
      tc = List.first(tool_calls)
      func = Map.get(tc, :function) || Map.get(tc, "function") || %{}

      args =
        Map.get(tc, :arguments) || Map.get(tc, "arguments") || Map.get(func, "arguments") ||
          Map.get(func, :arguments) || %{}

      args = parse_args(args)

      Logger.info("[Runner] extract_tool_call success: keys=#{inspect(Map.keys(args))}")
      {:ok, args}
    else
      content = Map.get(response, :content, "") |> to_string() |> String.slice(0, 200)

      Logger.warning(
        "[Runner] extract_tool_call: no tool_calls in response, content=#{inspect(content)}"
      )

      {:error, "No tool call in response"}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp consolidation_tool_choice_retry_reason(_provider, nil, _err), do: nil

  defp consolidation_tool_choice_retry_reason(provider, _tool_choice, err) do
    err_msg = err |> inspect() |> String.downcase()

    cond do
      String.contains?(err_msg, "tool_choice") ->
        :tool_choice_incompatible

      provider == :anthropic and
        String.contains?(err_msg, "matcherror") and
          String.contains?(err_msg, "not_implemented") ->
        :anthropic_match_error

      true ->
        nil
    end
  end

  defp consolidation_tool_choice_retry_message(:tool_choice_incompatible) do
    "tool_choice incompatible, retrying without it"
  end

  defp consolidation_tool_choice_retry_message(:anthropic_match_error) do
    "Anthropic tool_choice fallback triggered after MatchError, retrying without it"
  end

  defp default_evolution_signals do
    %{
      tool_call_count: 0,
      tool_rounds: 0,
      tool_errors: 0,
      used_tools: []
    }
  end

  defp update_evolution_signals(opts, results) do
    current = Keyword.get(opts, :_evolution_signals, default_evolution_signals())

    tool_errors =
      Enum.count(results, fn {_id, _name, result, _args} ->
        String.starts_with?(result, "Error:")
      end)

    used_tools = Enum.map(results, fn {_id, name, _result, _args} -> name end)

    Keyword.put(opts, :_evolution_signals, %{
      tool_call_count: current.tool_call_count + length(results),
      tool_rounds: current.tool_rounds + if(results == [], do: 0, else: 1),
      tool_errors: current.tool_errors + tool_errors,
      used_tools: current.used_tools ++ used_tools
    })
  end

  defp evolution_metadata(session) do
    Map.get(session.metadata || %{}, "runtime_evolution", %{})
  end

  defp put_evolution_metadata(session, metadata) do
    %{session | metadata: Map.put(session.metadata || %{}, "runtime_evolution", metadata)}
  end

  defp maybe_add_memory_nudge(messages, metadata) do
    if Map.get(metadata, "turns_since_memory_write", 0) >= 5 do
      messages ++
        [
          "[Runtime Evolution] Several exchanges have passed since durable memory was refreshed. " <>
            "If this turn confirms a lasting fact, use user_update for user-profile facts and use memory_write for durable project or workflow knowledge."
        ]
    else
      messages
    end
  end

  defp maybe_add_skill_nudge(messages, metadata) do
    if Map.get(metadata, "pending_skill_nudge") == true do
      messages ++
        [
          "[Runtime Evolution] The previous task was complex. If you just proved a reusable workflow, capture it with skill_capture before you move on."
        ]
    else
      messages
    end
  end

  defp next_memory_turn_count(_session, %{wrote_memory: true}), do: 0

  defp next_memory_turn_count(session, _signals) do
    session
    |> evolution_metadata()
    |> Map.get("turns_since_memory_write", 0)
    |> Kernel.+(1)
  end

  defp next_skill_nudge(_session, %{created_skill: true}), do: false
  defp next_skill_nudge(_session, %{complex_task: true}), do: true

  defp next_skill_nudge(session, _signals) do
    session
    |> evolution_metadata()
    |> Map.get("pending_skill_nudge", false)
  end

  defp maybe_enqueue_memory_refresh(session, workspace, opts) do
    if Keyword.get(opts, :skip_consolidation, false) do
      :ok
    else
      maybe_enqueue_memory_refresh_now(session, workspace, opts)
    end
  end

  defp maybe_enqueue_memory_refresh_now(session, workspace, opts) do
    if Process.whereis(MemoryUpdater) do
      MemoryUpdater.enqueue(session,
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        workspace: workspace,
        req_llm_stream_text_fun: Keyword.get(opts, :req_llm_stream_text_fun),
        llm_call_fun: Keyword.get(opts, :llm_call_fun)
      )
    end

    :ok
  end

  defp collect_evolution_signals(delta_messages, prompt) do
    tool_messages = Enum.filter(delta_messages, &(Map.get(&1, "role") == "tool"))
    tool_call_count = length(tool_messages)
    used_tools = Enum.map(tool_messages, &Map.get(&1, "name"))

    tool_rounds =
      delta_messages
      |> Enum.filter(&(Map.get(&1, "role") == "assistant" and is_list(Map.get(&1, "tool_calls"))))
      |> length()

    tool_errors =
      tool_messages
      |> Enum.count(fn msg ->
        msg
        |> Map.get("content", "")
        |> render_text()
        |> String.starts_with?("Error:")
      end)

    correction_hint =
      prompt
      |> String.downcase()
      |> then(fn lowered -> Enum.any?(@user_correction_terms, &String.contains?(lowered, &1)) end)

    %{
      wrote_memory: "memory_write" in used_tools,
      created_skill: "skill_capture" in used_tools,
      used_tools: used_tools,
      tool_call_count: tool_call_count,
      tool_rounds: tool_rounds,
      tool_errors: tool_errors,
      correction_hint: correction_hint,
      complex_task:
        tool_call_count >= @skill_complexity_tool_calls or
          tool_rounds >= @skill_complexity_tool_rounds or
          tool_errors > 0 or correction_hint
    }
  end

  defp render_text(nil), do: ""
  defp render_text(text) when is_binary(text), do: text

  defp render_text(text) when is_atom(text) or is_integer(text) or is_float(text),
    do: to_string(text)

  defp render_text(content) when is_list(content) do
    cond do
      List.ascii_printable?(content) ->
        to_string(content)

      Enum.all?(content, &text_content_part?/1) ->
        Enum.map_join(content, "", fn
          %{"type" => "text", "text" => text} -> text
          %{type: "text", text: text} -> text
          text when is_binary(text) -> text
        end)

      true ->
        render_structured(content)
    end
  end

  defp render_text(content) when is_map(content), do: render_structured(content)
  defp render_text(content), do: inspect(content, printable_limit: 500, limit: 50)

  defp text_content_part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp text_content_part?(%{type: "text", text: text}) when is_binary(text), do: true
  defp text_content_part?(text) when is_binary(text), do: true
  defp text_content_part?(_), do: false

  defp render_structured(content) do
    case Jason.encode(content, pretty: true) do
      {:ok, encoded} -> encoded
      _ -> inspect(content, printable_limit: 500, limit: 50)
    end
  end

  defp trace_request_started(
         prompt,
         channel,
         chat_id,
         prepared_run,
         runtime_system_messages,
         opts
       ) do
    request_trace_event(
      "request_started",
      %{
        "prompt" => prompt,
        "channel" => channel,
        "chat_id" => chat_id,
        "selected_packages" => Enum.map(prepared_run.selected_packages, &package_metadata/1),
        "runtime_system_messages" => runtime_system_messages
      },
      opts
    )
  end

  defp trace_request_completed(status, result, opts) do
    request_trace_event(
      "request_completed",
      %{
        "status" => status,
        "result" => render_text(result)
      },
      opts
    )
  end

  defp trace_llm_request(nil, _messages, _tools, _opts), do: :ok

  defp trace_llm_request(iteration, messages, tools, opts) do
    request_trace_event(
      "llm_request",
      %{
        "iteration" => iteration,
        "messages" => messages,
        "tools" => Enum.map(tools, &trace_tool_definition/1),
        "tool_choice" => Keyword.get(opts, :tool_choice)
      },
      opts
    )
  end

  defp trace_llm_response(iteration, response, duration_ms, opts) do
    request_trace_event(
      "llm_response",
      %{
        "iteration" => iteration,
        "content" => Map.get(response, :content) || Map.get(response, "content"),
        "tool_calls" => Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || [],
        "finish_reason" =>
          Map.get(response, :finish_reason) || Map.get(response, "finish_reason"),
        "duration_ms" => duration_ms
      },
      opts
    )
  end

  defp trace_tool_result(tool_call_id, tool_name, result, opts) do
    request_trace_event(
      "tool_result",
      %{
        "tool" => tool_name,
        "tool_call_id" => tool_call_id,
        "content" => result
      },
      opts
    )
  end

  defp request_trace_event(type, payload, opts) do
    _ =
      RequestTrace.append_event(
        Map.merge(payload, %{
          "type" => type,
          "run_id" => Keyword.get(opts, :run_id)
        }),
        opts
      )

    :ok
  end

  defp message_stats_log(messages) when is_list(messages) do
    counts =
      Enum.reduce(messages, %{"system" => 0, "user" => 0, "assistant" => 0, "tool" => 0}, fn msg,
                                                                                             acc ->
        role = Map.get(msg, "role", "unknown")
        Map.update(acc, role, 1, &(&1 + 1))
      end)

    content_chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        acc + (msg |> Map.get("content") |> render_text() |> byte_size())
      end)

    tool_call_messages =
      Enum.count(messages, fn msg ->
        tool_calls = Map.get(msg, "tool_calls")
        is_list(tool_calls) and tool_calls != []
      end)

    inspect(%{
      total: length(messages),
      role_counts: counts,
      content_chars: content_chars,
      tool_call_messages: tool_call_messages
    })
  end

  defp value_present?(value) when value in [nil, "", []], do: false
  defp value_present?(_), do: true

  defp trace_tool_definition(tool) when is_map(tool) do
    function = Map.get(tool, "function") || Map.get(tool, :function) || %{}

    %{
      "name" =>
        Map.get(tool, "name") || Map.get(tool, :name) || Map.get(function, "name") ||
          Map.get(function, :name),
      "description" =>
        Map.get(tool, "description") || Map.get(tool, :description) ||
          Map.get(function, "description") || Map.get(function, :description),
      "parameters" =>
        Map.get(tool, "parameters") || Map.get(tool, :parameters) ||
          Map.get(tool, "input_schema") || Map.get(tool, :input_schema) ||
          Map.get(function, "parameters") || Map.get(function, :parameters) ||
          Map.get(function, "input_schema") || Map.get(function, :input_schema) || %{}
    }
  end

  defp trace_tool_definition(tool), do: %{"definition" => inspect(tool)}

  defp init_stream_assembler(opts) do
    if streaming_result?(opts) do
      assembler =
        Assembler.new(
          mode: :conversation,
          run_id: Keyword.get(opts, :run_id) || "run_unknown",
          sink: Keyword.get(opts, :stream_sink),
          suppress_output?: Keyword.get(opts, :_suppress_current_reply_stream, false)
        )

      Keyword.put(opts, :_stream_assembler, assembler)
    else
      opts
    end
  end

  defp suppress_stream_output(opts, suppress?) do
    update_stream_assembler(opts, &Assembler.suppress_output(&1, suppress?))
  end

  defp update_stream_assembler(opts, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :_stream_assembler) do
      %Assembler{} = assembler ->
        Keyword.put(opts, :_stream_assembler, fun.(assembler))

      _ ->
        opts
    end
  end

  defp take_stream_assembler(%{_stream_assembler: %Assembler{} = assembler} = response, opts) do
    {Map.delete(response, :_stream_assembler), Keyword.put(opts, :_stream_assembler, assembler)}
  end

  defp take_stream_assembler(response, opts), do: {response, opts}
end
