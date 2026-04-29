defmodule Nex.Agent.Runner do
  @moduledoc false

  require Logger

  alias Nex.Agent.{
    Bus,
    Config,
    ContextBuilder,
    ContextWindow,
    Evolution,
    Hooks,
    RunControl,
    MemoryUpdater,
    Session,
    Stream.Result
  }

  alias Nex.Agent.ControlPlane.Log, as: ControlPlaneLog
  alias Nex.Agent.ControlPlane.Redactor
  require ControlPlaneLog
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Tool.Registry, as: ToolRegistry

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
    reset_stream_format_state()

    try do
      do_run(session, prompt, opts)
    after
      reset_stream_format_state()
    end
  end

  defp do_run(session, prompt, opts) do
    workspace = Keyword.get(opts, :workspace)
    runtime_snapshot = runtime_snapshot_from_opts(opts)
    runtime_config = if runtime_snapshot, do: runtime_snapshot.config

    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    default_model_runtime =
      Keyword.get(opts, :model_runtime) ||
        if(runtime_config, do: Nex.Agent.Config.default_model_runtime(runtime_config))

    provider =
      Keyword.get(opts, :provider) ||
        if(default_model_runtime, do: default_model_runtime.provider, else: :anthropic)

    model =
      Keyword.get(opts, :model) ||
        if(default_model_runtime,
          do: default_model_runtime.model_id,
          else: Nex.Agent.LLM.ProviderProfile.default_model(provider)
        )

    provider_options =
      Keyword.get(opts, :provider_options) ||
        if(default_model_runtime, do: default_model_runtime.provider_options, else: [])

    run_id = Keyword.get(opts, :run_id, generate_run_id())
    cancel_ref = Keyword.get(opts, :cancel_ref, make_ref())

    opts =
      opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:model, model)
      |> Keyword.put(:model_runtime, default_model_runtime)
      |> Keyword.put(:provider_options, provider_options)
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:cancel_ref, cancel_ref)
      |> maybe_put_opt(:runtime_snapshot, runtime_snapshot)
      |> maybe_put_opt(:runtime_version, runtime_snapshot && runtime_snapshot.version)
      |> Keyword.put_new(:_evolution_signals, default_evolution_signals())

    initial_message_count = length(session.messages)
    {session, runtime_system_messages} = prepare_evolution_turn(session, prompt, opts)

    channel = Keyword.get(opts, :channel, "feishu")
    chat_id = Keyword.get(opts, :chat_id, "default")
    media = Keyword.get(opts, :media)

    run_started_at = System.monotonic_time(:millisecond)
    emit_runner_lifecycle(:info, "runner.run.started", runner_run_attrs(opts, %{}), opts)

    trace_request_started(prompt, channel, chat_id, runtime_system_messages, opts)

    case build_initial_messages(
           session,
           prompt,
           channel,
           chat_id,
           media,
           runtime_snapshot,
           runtime_system_messages,
           workspace,
           runtime_config,
           opts
         ) do
      {:ok, messages, history_message_count} ->
        provider_options = ContextWindow.prepare_provider_options(opts, session)
        opts = Keyword.put(opts, :provider_options, provider_options)

        do_run_with_messages(
          session,
          messages,
          prompt,
          initial_message_count,
          history_message_count,
          max_iterations,
          runtime_system_messages,
          run_started_at,
          workspace,
          opts
        )

      {:error, reason} ->
        emit_runner_lifecycle(
          :error,
          "runner.run.failed",
          runner_run_attrs(opts, %{
            "duration_ms" => duration_since(run_started_at),
            "result_status" => "error",
            "reason_type" => "context_hook_failed",
            "error_summary" => error_summary(reason)
          }),
          opts
        )

        trace_request_completed("failed", reason, opts)
        {:error, stream_result(:error, opts, nil, %{error: reason}), session}
    end
  end

  defp do_run_with_messages(
         session,
         messages,
         prompt,
         initial_message_count,
         history_message_count,
         max_iterations,
         runtime_system_messages,
         run_started_at,
         workspace,
         opts
       ) do
    session =
      Session.add_message(session, "user", prompt, project: Keyword.get(opts, :project))

    emit_runner_lifecycle(
      :info,
      "runner.llm.request.prepared",
      %{
        "history_message_count" => history_message_count,
        "message_count" => length(messages),
        "message_stats" => message_stats_log(messages),
        "runtime_system_message_count" => length(runtime_system_messages)
      },
      opts
    )

    case run_loop(session, messages, 0, max_iterations, opts) do
      {:ok, result, final_session} ->
        emit_runner_lifecycle(
          :info,
          "runner.run.finished",
          runner_run_attrs(opts, %{
            "duration_ms" => duration_since(run_started_at),
            "result_status" => "ok"
          }),
          opts
        )

        trace_request_completed("completed", result, opts)

        {:ok, result,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace, opts)}

      {:error, reason, final_session} ->
        emit_runner_lifecycle(
          :error,
          "runner.run.failed",
          runner_run_attrs(opts, %{
            "duration_ms" => duration_since(run_started_at),
            "result_status" => result_status_from_reason(reason),
            "reason_type" => reason_type(reason),
            "error_summary" => error_summary(reason)
          }),
          opts
        )

        trace_request_completed("failed", reason, opts)

        {:error, reason,
         finalize_evolution_turn(final_session, initial_message_count, prompt, workspace, opts)}
    end
  end

  defp build_initial_messages(
         session,
         prompt,
         channel,
         chat_id,
         media,
         runtime_snapshot,
         runtime_system_messages,
         workspace,
         runtime_config,
         opts
       ) do
    hook_ctx = %{
      session_key: session.key,
      channel: channel,
      chat_id: chat_id,
      parent_chat_id: hook_parent_chat_id(opts),
      workspace: workspace,
      run_id: Keyword.get(opts, :run_id)
    }

    case Hooks.run(:prompt_build_before, runtime_hooks(runtime_snapshot), hook_ctx) do
      {:ok, context_hook_fragments} ->
        build_opts = [
          system_prompt: runtime_system_prompt(runtime_snapshot),
          skip_skills: Keyword.get(opts, :skip_skills, false),
          workspace: workspace,
          runtime_system_messages: runtime_system_messages,
          context_hook_fragments: context_hook_fragments,
          parent_chat_id: hook_ctx.parent_chat_id,
          cwd: Keyword.get(opts, :cwd),
          config: runtime_config
        ]

        {history, context_window_attrs} =
          ContextWindow.select_history(
            session,
            prompt,
            channel,
            chat_id,
            media,
            build_opts,
            Keyword.put(opts, :default_history_limit, @memory_window)
          )

        emit_runner_lifecycle(
          :info,
          "runner.context_window.projected",
          context_window_attrs,
          opts
        )

        {:ok, ContextBuilder.build_messages(history, prompt, channel, chat_id, media, build_opts),
         length(history)}

      {:error, reason} ->
        {:error, reason}
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
    maybe_record_runtime_evolution_signal(signals, prompt, workspace)
    maybe_enqueue_memory_refresh(session, workspace, opts)
    session
  end

  defp maybe_record_runtime_evolution_signal(
         %{correction_hint: true} = signals,
         prompt,
         workspace
       ) do
    Evolution.record_signal(
      %{
        source: :runner,
        signal: "user correction observed: #{String.slice(prompt, 0, 200)}",
        context: %{
          tool_call_count: signals.tool_call_count,
          tool_errors: signals.tool_errors,
          used_tools: signals.used_tools
        }
      },
      workspace: workspace
    )
  end

  defp maybe_record_runtime_evolution_signal(%{tool_errors: errors} = signals, _prompt, workspace)
       when errors > 0 do
    Evolution.record_signal(
      %{
        source: :runner,
        signal: "tool error observed during run",
        context: %{
          tool_call_count: signals.tool_call_count,
          tool_errors: signals.tool_errors,
          used_tools: signals.used_tools
        }
      },
      workspace: workspace
    )
  end

  defp maybe_record_runtime_evolution_signal(_signals, _prompt, _workspace), do: :ok

  defp run_loop(session, messages, iteration, max_iterations, opts) do
    iter_start = System.monotonic_time(:millisecond)

    emit_runner_lifecycle(
      :info,
      "runner.iteration.started",
      %{"iteration" => iteration + 1, "max_iterations" => max_iterations},
      opts
    )

    if cancelled?(opts) do
      {:error, stream_result(:error, opts, nil, %{error: :cancelled}), session}
    else
      if iteration >= max_iterations do
        emit_runner_lifecycle(
          :warning,
          "runner.iteration.max_reached",
          %{
            "iteration" => iteration + 1,
            "max_iterations" => max_iterations,
            "result_status" => "error",
            "reason_type" => "max_iterations_exceeded"
          },
          opts
        )

        {:error, :max_iterations_exceeded, session}
      else
        llm_start = System.monotonic_time(:millisecond)
        llm_attrs = llm_call_attrs(opts, iteration, max_iterations)
        emit_runner_lifecycle(:info, "runner.llm.call.started", llm_attrs, opts)

        llm_result =
          try do
            call_llm_with_retry(
              messages,
              Keyword.put(opts, :trace_iteration, iteration + 1),
              _retries = 1
            )
          rescue
            e ->
              {:error, "LLM call failed: #{Exception.message(e)}"}
          catch
            kind, reason ->
              {:error, "LLM call failed: #{kind} #{inspect(reason)}"}
          end

        llm_duration = System.monotonic_time(:millisecond) - llm_start

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
              iter_total = System.monotonic_time(:millisecond) - iter_start

              reason = "LLM returned an error"

              emit_control_plane_failure("runner.llm.call.failed", opts, %{
                "provider" => Keyword.get(opts, :provider) |> to_string(),
                "model" => Keyword.get(opts, :model) |> to_string(),
                "iteration" => iteration + 1,
                "max_iterations" => max_iterations,
                "duration_ms" => llm_duration,
                "tool_call_count" => tool_call_count(tool_calls),
                "finish_reason" => "error",
                "result_status" => "error",
                "reason_type" => "finish_reason_error",
                "error_summary" => reason,
                "actor" => llm_actor(opts),
                "classifier" => %{"family" => "llm", "retryable" => false},
                "evidence" => %{"error_text" => reason}
              })

              emit_iteration_finished(:error, iteration, max_iterations, iter_total, opts)
              emit_stream_error(opts, reason)
              {:error, stream_result(:error, opts, nil, %{error: reason}), session}
            else
              emit_runner_lifecycle(
                :info,
                "runner.llm.call.finished",
                llm_attrs
                |> Map.put("duration_ms", llm_duration)
                |> Map.put("finish_reason", to_string(finish_reason || "stop"))
                |> Map.put("tool_call_count", tool_call_count(tool_calls))
                |> Map.put("result_status", "ok"),
                opts
              )

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
                  response,
                  iteration,
                  max_iterations,
                  _on_progress = nil,
                  opts
                )

              iter_total = System.monotonic_time(:millisecond) - iter_start
              emit_iteration_finished(:ok, iteration, max_iterations, iter_total, opts)

              result
            end

          {:error, reason} ->
            emit_control_plane_failure("runner.llm.call.failed", opts, %{
              "provider" => Keyword.get(opts, :provider) |> to_string(),
              "model" => Keyword.get(opts, :model) |> to_string(),
              "iteration" => iteration + 1,
              "max_iterations" => max_iterations,
              "duration_ms" => llm_duration,
              "tool_call_count" => 0,
              "result_status" => result_status_from_reason(reason),
              "reason_type" => reason_type(reason),
              "error_summary" => error_summary(stream_error_reason(reason)),
              "actor" => llm_actor(opts),
              "classifier" => %{
                "family" => "llm",
                "retryable" => transient_error?(reason)
              },
              "evidence" => %{"error_text" => stream_error_reason(reason) |> inspect(limit: 20)}
            })

            emit_stream_error(opts, stream_error_reason(reason))
            iter_total = System.monotonic_time(:millisecond) - iter_start
            emit_iteration_finished(:error, iteration, max_iterations, iter_total, opts)

            {:error,
             stream_result(:error, opts, stream_error_partial_content(reason), %{
               error: stream_error_reason(reason),
               partial_content: stream_error_partial_content(reason)
             }), session}
        end
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
         response,
         iteration,
         max_iterations,
         _on_progress,
         opts
       )
       when is_list(tool_calls) and tool_calls != [] do
    if Keyword.get(opts, :_suppress_current_reply_stream, false) do
      tool_call_dicts = normalize_tool_calls(tool_calls)
      emit_stream_tool_call_notice(opts, tool_call_dicts)

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
        |> ContextWindow.store_response_compaction(response, opts)

      {new_messages, results, session, opts} =
        execute_tools(session, messages, tool_call_dicts, opts)

      maybe_publish_tool_results(results, opts)

      {new_messages, opts} = ContextWindow.compact_loop_messages(new_messages, response, opts)

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
        emit_runner_lifecycle(
          :warning,
          "runner.tool.loop_detected",
          %{
            "tool_call_count" => length(tool_call_dicts),
            "repeat_count" => @max_loop_repeats,
            "signatures_summary" => inspect(current_signatures, limit: 20)
          },
          opts
        )

        final_content =
          render_text(content) ||
            "I detected a repeated action loop and stopped. Please try a different approach."

        opts =
          opts
          |> maybe_stream_text(final_content)
          |> maybe_finish_stream()

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
            Keyword.put(opts, :_suppress_current_reply_stream, true)
          else
            opts
          end

        emit_stream_tool_call_notice(opts, tool_call_dicts)

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
          |> ContextWindow.store_response_compaction(response, opts)

        {new_messages, results, session, opts} =
          execute_tools(session, messages, tool_call_dicts, opts)

        maybe_publish_tool_results(results, opts)

        {new_messages, opts} = ContextWindow.compact_loop_messages(new_messages, response, opts)

        message_sent_to_current_channel =
          Enum.any?(results, fn {_id, name, _r, args} ->
            name == "message" and message_targets_current_conversation?(args, opts)
          end)

        effective_max =
          if iteration + 1 >= max_iterations and iteration + 1 < @max_iterations_hard_limit and
               not Keyword.has_key?(opts, :tools_filter) and
               not Keyword.get(opts, :_expanded, false) do
            new_max = min(max_iterations * 2, @max_iterations_hard_limit)

            emit_runner_lifecycle(
              :info,
              "runner.iteration.max_expanded",
              %{
                "iteration" => iteration + 1,
                "previous_max_iterations" => max_iterations,
                "max_iterations" => new_max
              },
              opts
            )

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
         response,
         _iteration,
         _max_iterations,
         _on_progress,
         opts
       ) do
    content_text = render_text(content)
    generated_images = persist_generated_images(response, opts)

    artifact_notice =
      case generated_images do
        [] -> nil
        images -> render_generated_image_notice(images)
      end

    effective_text =
      cond do
        is_binary(content_text) and String.trim(content_text) != "" and is_binary(artifact_notice) ->
          content_text <> "\n\n" <> artifact_notice

        is_binary(content_text) and String.trim(content_text) != "" ->
          content_text

        is_binary(artifact_notice) ->
          artifact_notice

        true ->
          content_text
      end

    opts =
      cond do
        Keyword.get(opts, :_suppress_current_reply_stream, false) ->
          opts

        Keyword.get(opts, :_llm_text_streamed, false) ->
          maybe_finish_stream(opts)

        true ->
          opts
          |> maybe_stream_text(effective_text)
          |> maybe_finish_stream()
      end

    session =
      Session.add_message(session, "assistant", effective_text,
        reasoning_content: reasoning_content
      )
      |> ContextWindow.store_response_compaction(response, opts)

    final_content =
      if Keyword.get(opts, :_suppress_current_reply_stream, false), do: nil, else: effective_text

    metadata =
      if Keyword.get(opts, :_suppress_current_reply_stream, false) do
        maybe_put_generated_images(%{message_sent: true}, generated_images)
      else
        maybe_put_generated_images(%{}, generated_images)
      end

    {:ok, stream_result(:ok, opts, final_content, metadata), session}
  end

  defp persist_generated_images(response, opts) when is_map(response) do
    response_metadata =
      Map.get(response, :response_metadata) || Map.get(response, "response_metadata") || %{}

    images =
      Map.get(response_metadata, :generated_images) ||
        Map.get(response_metadata, "generated_images") || []

    do_persist_generated_images(images, opts)
  end

  defp persist_generated_images(_response, _opts), do: []

  defp do_persist_generated_images(images, opts) when is_list(images) do
    run_id = Keyword.get(opts, :run_id, "run_unknown")
    out_dir = Path.join([System.tmp_dir!(), "nex-agent-generated-images", run_id])
    File.mkdir_p!(out_dir)

    images
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {image, idx} ->
      case persist_generated_image(image, out_dir, idx) do
        {:ok, persisted} -> [persisted]
        _ -> []
      end
    end)
  end

  defp do_persist_generated_images(_images, _opts), do: []

  defp persist_generated_image(%{"result" => result} = image, out_dir, idx)
       when is_binary(result) do
    mime_type = Map.get(image, "mime_type", "image/png")
    ext = image_extension(mime_type)
    path = Path.join(out_dir, "image_#{idx}.#{ext}")

    with {:ok, bytes} <- Base.decode64(result),
         :ok <- File.write(path, bytes) do
      {:ok,
       %{
         "path" => path,
         "mime_type" => mime_type,
         "revised_prompt" => Map.get(image, "revised_prompt")
       }}
    else
      _ -> {:error, :persist_failed}
    end
  end

  defp persist_generated_image(_image, _out_dir, _idx), do: {:error, :invalid_image}

  defp image_extension("image/jpeg"), do: "jpg"
  defp image_extension("image/webp"), do: "webp"
  defp image_extension(_mime_type), do: "png"

  defp render_generated_image_notice(images) when is_list(images) do
    paths =
      images
      |> Enum.map(fn image -> "- " <> Map.get(image, "path", "-") end)
      |> Enum.join("\n")

    "Generated images:\n" <> paths
  end

  defp maybe_put_generated_images(metadata, []), do: metadata

  defp maybe_put_generated_images(metadata, images),
    do: Map.put(metadata, :generated_images, images)

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

  defp emit_stream_tool_call_notice(opts, tool_calls)
       when is_list(tool_calls) and tool_calls != [] do
    case Keyword.get(opts, :stream_sink) do
      sink when is_function(sink, 1) ->
        notice = render_tool_call_notice(tool_calls)

        if notice != "" do
          maybe_flush_text_before_tool_notice(opts)
          _ = sink.({:text, notice})
          remember_stream_text_suffix({:text, notice})
          Process.put(:_last_stream_was_tool_notice, true)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp emit_stream_tool_call_notice(_opts, _tool_calls), do: :ok

  defp render_tool_call_notice(tool_calls) do
    tool_calls
    |> Enum.map(&render_tool_call_notice_line/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      lines -> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp render_tool_call_notice_line(tool_call) when is_map(tool_call) do
    tool_name = get_in(tool_call, ["function", "name"]) || "unknown_tool"

    args =
      tool_call
      |> get_in(["function", "arguments"])
      |> parse_args()
      |> then(&summarize_args(tool_name, &1))

    case render_tool_call_notice_args(tool_name, args) do
      "" ->
        "#{tool_notice_emoji(tool_name)} #{tool_notice_label(tool_name)}"

      rendered_args ->
        "#{tool_notice_emoji(tool_name)} #{tool_notice_label(tool_name)} - #{rendered_args}"
    end
  end

  defp render_tool_call_notice_line(_tool_call), do: ""

  defp render_tool_call_notice_args("bash", %{"command" => cmd}) when is_binary(cmd) do
    command =
      cmd
      |> String.replace("\n", " ")
      |> String.trim()
      |> String.slice(0, 120)

    command
  end

  defp render_tool_call_notice_args("get_memory", %{"query" => query}) when is_binary(query) do
    query
    |> String.replace("\n", " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp render_tool_call_notice_args("skill_get", %{"id" => id}) when is_binary(id) do
    id
    |> String.replace("\n", " ")
    |> String.trim()
    |> String.slice(0, 120)
    |> escape_markdown_notice_value()
  end

  defp render_tool_call_notice_args(_tool_name, args) when is_map(args) do
    args
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> "#{k}=#{render_tool_call_notice_value(v)}" end)
    |> Enum.join(", ")
    |> String.slice(0, 120)
  end

  defp render_tool_call_notice_args(_tool_name, _args), do: ""

  defp render_tool_call_notice_value(value) when is_binary(value) do
    value =
      value
      |> String.replace("\n", " ")
      |> String.trim()
      |> String.slice(0, 80)

    escape_markdown_notice_value(value)
  end

  defp render_tool_call_notice_value(value), do: inspect(value, printable_limit: 80, limit: 5)

  defp escape_markdown_notice_value(value) do
    Regex.replace(~r/[`*_\[\]()<>#|]/, value, fn marker -> "\\" <> marker end)
  end

  defp tool_notice_label("skill_get"), do: "Skill"

  defp tool_notice_label(tool_name) do
    tool_name
    |> to_string()
    |> String.split("_")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("", &String.capitalize/1)
  end

  defp tool_notice_emoji("bash"), do: "⚙️"
  defp tool_notice_emoji("get_memory"), do: "🧠"
  defp tool_notice_emoji("memory_status"), do: "🧠"
  defp tool_notice_emoji("memory_write"), do: "🧠"
  defp tool_notice_emoji("memory_rebuild"), do: "🧠"
  defp tool_notice_emoji("memory_consolidate"), do: "🧠"
  defp tool_notice_emoji("skill_get"), do: "📚"
  defp tool_notice_emoji("read"), do: "📖"
  defp tool_notice_emoji("find"), do: "🔍"
  defp tool_notice_emoji("write"), do: "✍️"
  defp tool_notice_emoji("edit"), do: "✍️"
  defp tool_notice_emoji("list_dir"), do: "📂"
  defp tool_notice_emoji("web_search"), do: "🔎"
  defp tool_notice_emoji("web_fetch"), do: "🌐"
  defp tool_notice_emoji("message"), do: "💬"
  defp tool_notice_emoji(_tool_name), do: "🛠️"

  defp maybe_stream_text(opts, text) when is_binary(text) and text != "" do
    case Keyword.get(opts, :stream_sink) do
      sink when is_function(sink, 1) ->
        maybe_flush_tool_notice_separator(opts)
        _ = sink.({:text, text})
        remember_stream_text_suffix({:text, text})
        Keyword.put(opts, :_llm_text_streamed, true)

      _ ->
        opts
    end
  end

  defp maybe_stream_text(opts, _text), do: opts

  defp maybe_finish_stream(opts) do
    case Keyword.get(opts, :stream_sink) do
      sink when is_function(sink, 1) ->
        _ = sink.(:finish)
        opts

      _ ->
        opts
    end
  end

  defp emit_stream_error(opts, reason) do
    case Keyword.get(opts, :stream_sink) do
      sink when is_function(sink, 1) ->
        _ = sink.({:error, format_stream_error(reason)})
        opts

      _ ->
        opts
    end
  end

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
    if cancelled?(opts) do
      {:error, :cancelled}
    else
      case call_llm(messages, opts) do
        {:ok, _} = success ->
          success

        {:error, reason} = error ->
          cond do
            retries_left > 0 and resumable_stream_error?(reason) ->
              partial_content = stream_error_partial_content(reason)

              emit_runner_lifecycle(
                :warning,
                "runner.llm.stream_interrupted",
                %{
                  "partial_content_bytes" => byte_size(partial_content),
                  "retry_delay_ms" => llm_retry_delay_ms(opts),
                  "reason_type" => reason_type(stream_error_reason(reason)),
                  "error_summary" => error_summary(stream_error_reason(reason))
                },
                opts
              )

              sleep_with_cancel(llm_retry_delay_ms(opts), opts)

              messages
              |> stream_continue_messages(partial_content)
              |> call_llm_with_retry(
                opts
                |> Keyword.put(:__stream_continue, true)
                |> Keyword.put(:_llm_text_streamed, true),
                retries_left - 1
              )
              |> merge_stream_continue_result(partial_content)

            retries_left > 0 and transient_error?(reason) ->
              emit_runner_lifecycle(
                :warning,
                "runner.llm.transient_retry",
                %{
                  "retry_delay_ms" => llm_retry_delay_ms(opts),
                  "reason_type" => reason_type(reason),
                  "error_summary" => error_summary(reason)
                },
                opts
              )

              sleep_with_cancel(llm_retry_delay_ms(opts), opts)
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
  end

  # Analyze LLM error and attempt automatic recovery.
  defp attempt_recovery(reason, messages, opts) do
    error_msg = extract_error_message(reason)
    status = extract_error_status(reason)

    emit_runner_lifecycle(
      :warning,
      "runner.llm.recovery.analyzed",
      %{
        "status" => status,
        "message_count" => length(messages),
        "error_summary" => String.slice(to_string(error_msg), 0, 300)
      },
      opts
    )

    cond do
      # 400: context too long → trim older messages
      status == 400 and context_length_error?(error_msg) ->
        trimmed = trim_messages(messages)

        if length(trimmed) < length(messages) do
          emit_runner_lifecycle(
            :warning,
            "runner.llm.context_trimmed",
            %{
              "message_count" => length(messages),
              "trimmed_message_count" => length(trimmed)
            },
            opts
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

  defp transient_error?(%{type: :stream_interrupted, reason: reason}),
    do: transient_error?(reason)

  defp transient_error?(%{status: status}) when status in [429, 500, 502, 503, 504], do: true
  defp transient_error?(:timeout), do: true
  defp transient_error?(:closed), do: true

  defp transient_error?(reason) when is_binary(reason) do
    reason = String.downcase(reason)

    String.contains?(reason, "timeout") or
      String.contains?(reason, "transporterror") or
      String.contains?(reason, "transport error") or
      String.contains?(reason, "mint") or
      String.contains?(reason, "connection closed") or
      String.contains?(reason, "reason: :closed") or
      String.contains?(reason, "econnreset")
  end

  defp transient_error?(_), do: false

  defp resumable_stream_error?(reason) do
    transient_error?(reason) and byte_size(stream_error_partial_content(reason)) > 0
  end

  defp llm_retry_delay_ms(opts), do: Keyword.get(opts, :llm_retry_delay_ms, 2_000)

  defp stream_continue_messages(messages, partial_content) do
    messages
    |> ContextBuilder.add_assistant_message(partial_content)
    |> Kernel.++([
      %{
        "role" => "user",
        "content" =>
          "The previous assistant response was interrupted. Continue from the exact breakpoint " <>
            "after the immediately preceding assistant message. Do not repeat any text already " <>
            "present there. Do not summarize or restart; output only the remaining continuation."
      }
    ])
  end

  defp merge_stream_continue_result({:ok, response}, partial_content) when is_map(response) do
    {:ok,
     response
     |> Map.update(:content, partial_content, &(partial_content <> render_text(&1)))
     |> Map.update(:reasoning_content, nil, &merge_optional_text(nil, &1))
     |> Map.put(:streamed_text, true)}
  end

  defp merge_stream_continue_result({:error, reason}, partial_content) do
    retry_partial = stream_error_partial_content(reason)

    {:error,
     %{
       type: :stream_interrupted,
       reason: stream_error_reason(reason),
       partial_content: partial_content <> retry_partial,
       retry_error: reason
     }}
  end

  defp merge_stream_continue_result(other, _partial_content), do: other

  defp merge_optional_text(nil, value), do: value
  defp merge_optional_text(prefix, value), do: render_text(prefix) <> render_text(value)

  defp stream_error_reason(%{type: :stream_interrupted, reason: reason}), do: reason
  defp stream_error_reason(reason), do: reason

  defp stream_error_partial_content(%{type: :stream_interrupted, partial_content: content})
       when is_binary(content),
       do: content

  defp stream_error_partial_content(_reason), do: ""

  defp call_llm(messages, opts) do
    tools =
      case Keyword.get(opts, :tools_filter) do
        :follow_up -> registry_definitions(:follow_up, opts)
        :subagent -> registry_definitions(:subagent, opts)
        :cron -> registry_definitions(:cron, opts)
        :base -> registry_definitions(:base, opts)
        _ -> registry_definitions(:all, opts)
      end
      |> filter_tool_allowlist(Keyword.get(opts, :tool_allowlist))

    opts = Keyword.put(opts, :tools, tools)

    emit_runner_lifecycle(
      :info,
      "runner.llm.call.dispatched",
      %{
        "iteration" => Keyword.get(opts, :trace_iteration),
        "provider" => Keyword.get(opts, :provider) |> to_string(),
        "model" => Keyword.get(opts, :model) |> to_string(),
        "base_url_present" => Keyword.get(opts, :base_url) not in [nil, ""],
        "tool_count" => length(tools),
        "tool_choice_summary" => inspect(Keyword.get(opts, :tool_choice), limit: 20),
        "message_stats" => message_stats_log(messages)
      },
      opts
    )

    trace_llm_request(Keyword.get(opts, :trace_iteration), messages, tools, opts)

    call_llm_stream(messages, opts)
  end

  # Tool names must start with a letter and contain only letters, numbers, underscores, dashes.
  @valid_tool_name ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/

  defp registry_definitions(filter, opts) do
    if Process.whereis(ToolRegistry) do
      registry_definitions_from_registry(filter, opts)
    else
      snapshot_tool_definitions_for_fallback(filter, opts)
    end
  end

  defp registry_definitions_from_registry(filter, opts) do
    ToolRegistry.definitions(filter, tool_registry_resolution_opts(opts, filter))
    |> normalize_tool_definitions()
  end

  defp snapshot_tool_definitions_for_fallback(filter, opts) do
    runtime_definitions =
      case Keyword.get(opts, :runtime_snapshot) do
        %Snapshot{} = snapshot -> snapshot_tool_definitions(snapshot, filter)
        _ -> nil
      end

    if is_list(runtime_definitions) do
      runtime_definitions
      |> normalize_tool_definitions()
    else
      []
    end
  end

  defp normalize_tool_definitions(definitions) do
    definitions
    |> Enum.filter(fn tool ->
      tool_definition_name(tool) |> valid_tool_name?()
    end)
    |> Enum.uniq_by(&tool_definition_name/1)
  end

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, :subagent),
    do: snapshot.tools.definitions_subagent

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, :follow_up),
    do: snapshot.tools.definitions_follow_up

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, :cron),
    do: snapshot.tools.definitions_cron

  defp snapshot_tool_definitions(%Snapshot{}, :base),
    do: []

  defp snapshot_tool_definitions(%Snapshot{} = snapshot, _filter),
    do: snapshot.tools.definitions_all

  defp filter_tool_allowlist(definitions, nil), do: definitions

  defp filter_tool_allowlist(definitions, allowlist) when is_list(allowlist) do
    allowed = allowlist |> Enum.map(&to_string/1) |> MapSet.new()

    Enum.filter(definitions, fn definition ->
      MapSet.member?(allowed, tool_definition_name(definition))
    end)
  end

  defp filter_tool_allowlist(definitions, _allowlist), do: definitions

  defp valid_tool_name?(name) when is_binary(name), do: Regex.match?(@valid_tool_name, name)
  defp valid_tool_name?(_), do: false

  defp tool_definition_name(tool) when is_map(tool) do
    Map.get(tool, "name") ||
      Map.get(tool, :name)
  end

  defp tool_definition_name(_tool), do: nil

  defp runtime_system_prompt(%Snapshot{} = snapshot), do: snapshot.prompt.system_prompt
  defp runtime_system_prompt(_), do: nil

  defp runtime_hooks(%Snapshot{} = snapshot), do: snapshot.hooks
  defp runtime_hooks(_), do: nil

  defp hook_parent_chat_id(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    Keyword.get(opts, :parent_chat_id) ||
      metadata_value(metadata, "parent_chat_id") ||
      metadata_value(metadata, :parent_chat_id)
  end

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(_metadata, _key), do: nil

  defp default_model_runtime(%Snapshot{config: %Nex.Agent.Config{} = config}) do
    Nex.Agent.Config.default_model_runtime(config)
  end

  defp default_model_runtime(_snapshot), do: nil

  defp runtime_snapshot_from_opts(opts) do
    case Keyword.get(opts, :runtime_snapshot) do
      %Snapshot{} = snapshot ->
        snapshot

      _ ->
        nil
    end
  end

  defp call_llm_stream(messages, opts) do
    stream_fun = fn callback ->
      if opts[:llm_stream_client] do
        opts[:llm_stream_client].(messages, opts, callback)
      else
        call_req_llm_stream(messages, opts, callback)
      end
    end

    drain_llm_stream(stream_fun, opts, stream_output?: true)
  end

  defp call_req_llm_stream(messages, opts, callback) do
    provider = Keyword.get(opts, :provider, :anthropic)

    stream_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        provider_options: Keyword.get(opts, :provider_options, []),
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

    batch_started_at = System.monotonic_time(:millisecond)

    emit_runner_lifecycle(
      :info,
      "runner.tool.batch.started",
      %{"tool_call_count" => length(indexed_calls)},
      opts
    )

    results =
      indexed_calls
      |> Task.async_stream(
        fn {tool_call_id, tool_name, args} ->
          tool_opts = Keyword.put(opts, :tool_call_id, tool_call_id)
          call_attrs = tool_call_attrs(tool_name, tool_call_id, args)
          call_started_at = System.monotonic_time(:millisecond)
          emit_runner_lifecycle(:info, "runner.tool.call.started", call_attrs, tool_opts)

          if cancelled?(opts) do
            emit_runner_lifecycle(
              :warning,
              "runner.tool.task.cancelled",
              call_attrs
              |> Map.put("duration_ms", duration_since(call_started_at))
              |> Map.put("result_status", "cancelled")
              |> Map.put("reason_type", "cancelled"),
              tool_opts
            )

            {tool_call_id, tool_name, "Error: cancelled", parse_args(args)}
          else
            parsed_args = parse_args(args)

            tool_started_at = System.monotonic_time(:millisecond)

            result =
              execute_tool(tool_name, parsed_args, Map.put(ctx, :tool_call_id, tool_call_id))

            truncated = truncate_result(result)
            tool_duration_ms = System.monotonic_time(:millisecond) - tool_started_at

            result_attrs =
              call_attrs
              |> Map.put("duration_ms", tool_duration_ms)

            if String.starts_with?(render_text(truncated), "Error:") do
              emit_runner_lifecycle(
                :error,
                "runner.tool.call.failed",
                result_attrs
                |> Map.put("result_status", "error")
                |> Map.put("reason_type", reason_type(truncated))
                |> Map.put("error_summary", error_summary(truncated))
                |> Map.merge(tool_failure_compat_attrs(tool_name, truncated, parsed_args)),
                tool_opts
              )
            else
              emit_runner_lifecycle(
                :info,
                "runner.tool.call.finished",
                Map.put(result_attrs, "result_status", "ok"),
                tool_opts
              )
            end

            {tool_call_id, tool_name, truncated, parsed_args}
          end
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
          tool_opts = Keyword.put(opts, :tool_call_id, tool_call_id)

          attrs =
            tool_call_attrs(tool_name, tool_call_id, args)
            |> Map.put("result_status", result_status_from_reason(reason))
            |> Map.put("reason_type", reason_type(reason))
            |> Map.put("error_summary", error_summary(reason))

          emit_runner_lifecycle(:error, "runner.tool.task.exited", attrs, tool_opts)

          failure_tag =
            case reason do
              :timeout -> "runner.tool.task.timeout"
              _ -> "runner.tool.call.failed"
            end

          emit_runner_lifecycle(:error, failure_tag, attrs, tool_opts)

          {tool_call_id, tool_name, "Error: tool timed out or crashed (#{inspect(reason)})",
           parse_args(args)}
      end)

    emit_runner_lifecycle(
      :info,
      "runner.tool.batch.finished",
      %{
        "tool_call_count" => length(results),
        "duration_ms" => duration_since(batch_started_at),
        "result_status" => if(Enum.any?(results, &tool_result_error?/1), do: "error", else: "ok")
      },
      opts
    )

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
    cond do
      cancelled_ctx?(ctx) ->
        "Error: cancelled"

      not tool_allowed?(tool_name, ctx) ->
        "Error: tool #{tool_name} is not available for this run"

      true ->
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
              emit_tool_coercion(tool_name, ctx, "bare_content_map")

              content

            %{error: error} ->
              emit_tool_coercion(tool_name, ctx, "bare_error_map")

              "Error: #{error}"

            result when is_map(result) ->
              emit_tool_coercion(tool_name, ctx, "bare_map")

              Jason.encode!(result, pretty: true)

            result ->
              emit_tool_coercion(tool_name, ctx, "non_standard_result")

              render_text(result)
          end
        else
          "Error: tool registry unavailable"
        end
    end
  end

  defp tool_allowed?(_tool_name, %{tool_allowlist: nil}), do: true
  defp tool_allowed?(_tool_name, %{"tool_allowlist" => nil}), do: true
  defp tool_allowed?(_tool_name, ctx) when not is_map_key(ctx, :tool_allowlist), do: true

  defp tool_allowed?(tool_name, %{tool_allowlist: allowlist}) when is_list(allowlist) do
    tool_name in Enum.map(allowlist, &to_string/1)
  end

  defp tool_allowed?(_tool_name, _ctx), do: true

  defp build_tool_ctx(opts) do
    runtime_snapshot = Keyword.get(opts, :runtime_snapshot)

    %{
      channel: Keyword.get(opts, :channel),
      chat_id: Keyword.get(opts, :chat_id),
      parent_chat_id: hook_parent_chat_id(opts),
      session_key: Keyword.get(opts, :session_key),
      run_id: Keyword.get(opts, :run_id),
      cancel_ref: Keyword.get(opts, :cancel_ref),
      tools_filter: Keyword.get(opts, :tools_filter),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      api_key: Keyword.get(opts, :api_key),
      base_url: Keyword.get(opts, :base_url),
      provider_options: Keyword.get(opts, :provider_options, []),
      tool_allowlist: Keyword.get(opts, :tool_allowlist),
      tools: Keyword.get(opts, :tools, %{}),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      workspace: Keyword.get(opts, :workspace),
      config: runtime_snapshot && runtime_snapshot.config,
      runtime_snapshot: runtime_snapshot,
      project: Keyword.get(opts, :project),
      metadata: Keyword.get(opts, :metadata, %{}),
      llm_stream_client: Keyword.get(opts, :llm_stream_client),
      req_llm_stream_text_fun: Keyword.get(opts, :req_llm_stream_text_fun),
      llm_call_fun: Keyword.get(opts, :llm_call_fun)
    }
  end

  defp tool_registry_resolution_opts(opts, filter) do
    runtime_snapshot = Keyword.get(opts, :runtime_snapshot)

    []
    |> maybe_put_opt(:provider, Keyword.get(opts, :provider))
    |> maybe_put_opt(:base_url, Keyword.get(opts, :base_url))
    |> maybe_put_opt(:provider_options, Keyword.get(opts, :provider_options))
    |> maybe_put_opt(:config, runtime_snapshot && runtime_snapshot.config)
    |> maybe_put_opt(:model_runtime, default_model_runtime(runtime_snapshot))
    |> maybe_put_opt(:surface, filter)
  end

  defp emit_control_plane_failure(tag, opts, attrs) do
    attrs =
      attrs
      |> Map.put("phase", "runner")
      |> Map.put("outcome", nil)

    log_opts =
      []
      |> put_log_opt(:workspace, Keyword.get(opts, :workspace))
      |> put_log_opt(:run_id, Keyword.get(opts, :run_id))
      |> put_log_opt(:session_key, Keyword.get(opts, :session_key))

    case ControlPlaneLog.error(tag, attrs, log_opts) do
      {:ok, _observation} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Runner] control-plane log #{tag} failed: #{inspect(reason)}")

      other ->
        Logger.warning("[Runner] control-plane log #{tag} returned: #{inspect(other)}")
    end
  rescue
    e ->
      Logger.warning("[Runner] control-plane log #{tag} crashed: #{Exception.message(e)}")
      :ok
  end

  defp emit_tool_coercion(tool_name, ctx, reason_type) do
    opts =
      []
      |> put_log_opt(:workspace, Map.get(ctx, :workspace))
      |> put_log_opt(:run_id, Map.get(ctx, :run_id))
      |> put_log_opt(:session_key, Map.get(ctx, :session_key))
      |> put_log_opt(:channel, Map.get(ctx, :channel))
      |> put_log_opt(:chat_id, Map.get(ctx, :chat_id))
      |> put_log_opt(:tool_call_id, Map.get(ctx, :tool_call_id))

    case ControlPlaneLog.warning(
           "runner.tool.result.coerced",
           %{"tool_name" => tool_name, "reason_type" => reason_type},
           opts
         ) do
      {:ok, _observation} -> :ok
      :ok -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp put_log_opt(opts, _key, nil), do: opts
  defp put_log_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp llm_actor(opts) do
    %{
      "component" => "runner",
      "provider" => Keyword.get(opts, :provider) |> to_string(),
      "model" => Keyword.get(opts, :model) |> to_string()
    }
  end

  defp tool_error_retryable?(result) do
    result
    |> render_text()
    |> transient_error?()
  end

  defp emit_runner_lifecycle(level, tag, attrs, opts) do
    case level do
      :info -> ControlPlaneLog.info(tag, attrs, control_plane_opts(opts))
      :warning -> ControlPlaneLog.warning(tag, attrs, control_plane_opts(opts))
      :error -> ControlPlaneLog.error(tag, attrs, control_plane_opts(opts))
    end

    :ok
  rescue
    e ->
      Logger.warning("[Runner] control-plane log #{tag} crashed: #{Exception.message(e)}")
      :ok
  end

  defp emit_iteration_finished(status, iteration, max_iterations, duration_ms, opts) do
    level = if status == :ok, do: :info, else: :error

    emit_runner_lifecycle(
      level,
      "runner.iteration.finished",
      %{
        "iteration" => iteration + 1,
        "max_iterations" => max_iterations,
        "duration_ms" => duration_ms,
        "result_status" => to_string(status)
      },
      opts
    )
  end

  defp control_plane_opts(opts) do
    []
    |> put_log_opt(:workspace, Keyword.get(opts, :workspace))
    |> put_log_opt(:run_id, Keyword.get(opts, :run_id))
    |> put_log_opt(:session_key, Keyword.get(opts, :session_key))
    |> put_log_opt(:channel, Keyword.get(opts, :channel))
    |> put_log_opt(:chat_id, Keyword.get(opts, :chat_id))
    |> put_log_opt(:tool_call_id, Keyword.get(opts, :tool_call_id))
  end

  defp runner_run_attrs(opts, extra) do
    %{
      "provider" => Keyword.get(opts, :provider) |> to_string(),
      "model" => Keyword.get(opts, :model) |> to_string(),
      "max_iterations" => Keyword.get(opts, :max_iterations, @default_max_iterations)
    }
    |> Map.merge(extra)
    |> compact_attrs()
  end

  defp llm_call_attrs(opts, iteration, max_iterations) do
    %{
      "provider" => Keyword.get(opts, :provider) |> to_string(),
      "model" => Keyword.get(opts, :model) |> to_string(),
      "iteration" => iteration + 1,
      "max_iterations" => max_iterations
    }
  end

  defp tool_call_attrs(tool_name, tool_call_id, args) do
    %{
      "tool_name" => to_string(tool_name),
      "tool_call_id" => tool_call_id,
      "args_summary" => args_summary(args)
    }
  end

  defp tool_failure_compat_attrs(tool_name, result, args) do
    args_summary = args_summary(args)

    %{
      "actor" => %{
        "component" => "tool",
        "tool" => tool_name
      },
      "classifier" => %{
        "family" => "tool",
        "retryable" => tool_error_retryable?(result)
      },
      "evidence" => %{
        "error_text" => render_text(result),
        "args_summary" => args_summary
      }
    }
  end

  defp tool_result_error?({_tool_call_id, _tool_name, result, _args}) do
    String.starts_with?(render_text(result), "Error:")
  end

  defp tool_call_count(tool_calls) when is_list(tool_calls), do: length(tool_calls)
  defp tool_call_count(_tool_calls), do: 0

  defp result_status_from_reason(:cancelled), do: "cancelled"
  defp result_status_from_reason(:timeout), do: "timeout"

  defp result_status_from_reason(reason) when is_binary(reason) do
    cond do
      String.contains?(String.downcase(reason), "cancel") -> "cancelled"
      String.contains?(String.downcase(reason), "timeout") -> "timeout"
      true -> "error"
    end
  end

  defp result_status_from_reason(_reason), do: "error"

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp reason_type(%{__struct__: struct}), do: inspect(struct)
  defp reason_type({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(_reason), do: "error"

  defp error_summary(reason), do: reason |> render_text() |> String.slice(0, 1000)

  defp args_summary(args) do
    args
    |> parse_args()
    |> Redactor.redact()
    |> inspect(limit: 20, printable_limit: 1000)
    |> String.slice(0, 1000)
  end

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp duration_since(started_at), do: System.monotonic_time(:millisecond) - started_at

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
        provider_options: Keyword.get(opts, :provider_options, []),
        tools: Keyword.get(opts, :tools, []),
        tool_choice: tool_choice
      ]
      |> maybe_put_opt(:req_llm_stream_text_fun, Keyword.get(opts, :req_llm_stream_text_fun))

    emit_runner_lifecycle(
      :info,
      "runner.consolidation.llm.call.started",
      %{
        "provider" => to_string(provider),
        "model" => to_string(Keyword.get(call_opts, :model)),
        "tool_choice_summary" => inspect(tool_choice, limit: 20)
      },
      opts
    )

    case call_llm_stream_for_consolidation(messages, call_opts) do
      {:ok, response} ->
        emit_runner_lifecycle(
          :info,
          "runner.consolidation.llm.call.finished",
          %{
            "finish_reason" => to_string(Map.get(response, :finish_reason) || "stop"),
            "has_tool_calls" =>
              is_list(Map.get(response, :tool_calls) || Map.get(response, "tool_calls")),
            "content_summary" => String.slice(to_string(Map.get(response, :content, "")), 0, 100)
          },
          opts
        )

        extract_tool_call(response)

      {:error, err} ->
        emit_runner_lifecycle(
          :warning,
          "runner.consolidation.llm.call.failed",
          %{
            "reason_type" => reason_type(err),
            "error_summary" => error_summary(err)
          },
          opts
        )

        case consolidation_tool_choice_retry_reason(provider, tool_choice, err) do
          nil ->
            {:error, stream_error_reason(err)}

          reason ->
            emit_runner_lifecycle(
              :warning,
              "runner.consolidation.llm.retry_without_tool_choice",
              %{
                "reason_type" => to_string(reason),
                "error_summary" => consolidation_tool_choice_retry_message(reason)
              },
              opts
            )

            retry_opts = Keyword.delete(call_opts, :tool_choice)

            case call_llm_stream_for_consolidation(messages, retry_opts) do
              {:ok, response} -> extract_tool_call(response)
              error -> error
            end
        end

      error ->
        emit_runner_lifecycle(
          :error,
          "runner.consolidation.llm.unexpected",
          %{
            "reason_type" => reason_type(error),
            "error_summary" => error_summary(error)
          },
          opts
        )

        error
    end
  end

  defp call_llm_stream_for_consolidation(messages, opts) do
    stream_fun = fn callback ->
      Nex.Agent.LLM.ReqLLM.stream(messages, opts, callback)
    end

    case drain_llm_stream(stream_fun, opts, stream_output?: false) do
      {:ok, response} -> {:ok, Map.delete(response, :streamed_text)}
      error -> error
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

      {:ok, args}
    else
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

      provider in [:openai, :openai_compatible] and
          String.contains?(err_msg, "model engine error") ->
        :openai_model_engine_error

      provider in [:openai, :openai_compatible] and String.contains?(err_msg, "20057") ->
        :openai_model_engine_error

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

  defp consolidation_tool_choice_retry_message(:openai_model_engine_error) do
    "OpenAI-compatible model engine error with forced tool_choice, retrying without it"
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
    if Keyword.get(opts, :skip_consolidation, false) or
         Keyword.get(opts, :schedule_memory_refresh, true) == false do
      :ok
    else
      maybe_enqueue_memory_refresh_now(session, workspace, opts)
    end
  end

  defp maybe_enqueue_memory_refresh_now(session, workspace, opts) do
    if Process.whereis(MemoryUpdater) do
      runtime = memory_refresh_runtime(opts)

      MemoryUpdater.enqueue(session,
        provider: runtime.provider,
        model: runtime.model,
        api_key: runtime.api_key,
        base_url: runtime.base_url,
        provider_options: runtime.provider_options,
        workspace: workspace,
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id),
        model_role: runtime.model_role,
        notify_memory_updates: false,
        source: "runner_finalize",
        req_llm_stream_text_fun: Keyword.get(opts, :req_llm_stream_text_fun),
        llm_call_fun: Keyword.get(opts, :llm_call_fun)
      )
    end

    :ok
  end

  defp memory_refresh_runtime(opts) do
    runtime_snapshot = Keyword.get(opts, :runtime_snapshot)
    config = runtime_snapshot && runtime_snapshot.config

    case config && Config.memory_model_runtime(config) do
      %{provider: provider, model_id: model} = runtime ->
        %{
          provider: provider,
          model: model,
          api_key: runtime.api_key,
          base_url: runtime.base_url,
          provider_options: runtime.provider_options,
          model_role: "memory"
        }

      _ ->
        %{
          provider: Keyword.get(opts, :provider),
          model: Keyword.get(opts, :model),
          api_key: Keyword.get(opts, :api_key),
          base_url: Keyword.get(opts, :base_url),
          provider_options: Keyword.get(opts, :provider_options, []),
          model_role: "runtime"
        }
    end
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
         runtime_system_messages,
         opts
       ) do
    request_trace_event(
      "request_started",
      %{
        "prompt" => prompt,
        "channel" => channel,
        "chat_id" => chat_id,
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
    attrs =
      Map.merge(request_trace_attrs(type, payload), %{
        "type" => type,
        "run_id" => Keyword.get(opts, :run_id),
        "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    _ = ControlPlaneLog.info("request_trace.event.recorded", attrs, opts)
    :ok
  end

  defp request_trace_attrs("request_started", payload) do
    %{
      "prompt_summary" => payload |> Map.get("prompt") |> text_summary(),
      "channel" => Map.get(payload, "channel"),
      "chat_id" => Map.get(payload, "chat_id"),
      "runtime_system_message_count" =>
        length(Map.get(payload, "runtime_system_messages", []) || [])
    }
  end

  defp request_trace_attrs("llm_request", payload) do
    tools = Map.get(payload, "tools", []) || []

    %{
      "iteration" => Map.get(payload, "iteration"),
      "message_count" => length(Map.get(payload, "messages", []) || []),
      "tool_count" => length(tools),
      "available_tool_names" =>
        tools
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> Enum.reject(&is_nil/1),
      "tool_choice_summary" => payload |> Map.get("tool_choice") |> inspect_summary()
    }
  end

  defp request_trace_attrs("llm_response", payload) do
    tool_calls = Map.get(payload, "tool_calls", []) || []

    %{
      "iteration" => Map.get(payload, "iteration"),
      "content_summary" => payload |> Map.get("content") |> text_summary(),
      "tool_call_count" => length(tool_calls),
      "tool_call_names" =>
        Enum.map(tool_calls, &trace_tool_call_name/1) |> Enum.reject(&is_nil/1),
      "finish_reason" => Map.get(payload, "finish_reason"),
      "duration_ms" => Map.get(payload, "duration_ms")
    }
  end

  defp request_trace_attrs("tool_result", payload) do
    %{
      "tool" => Map.get(payload, "tool"),
      "tool_call_id" => Map.get(payload, "tool_call_id"),
      "content_summary" => payload |> Map.get("content") |> text_summary()
    }
  end

  defp request_trace_attrs("request_completed", payload) do
    %{
      "status" => Map.get(payload, "status"),
      "result_summary" => payload |> Map.get("result") |> text_summary()
    }
  end

  defp request_trace_attrs(_type, payload) do
    payload
    |> Map.take(["iteration", "status", "duration_ms", "finish_reason", "tool", "tool_call_id"])
    |> Map.put("payload_summary", inspect_summary(payload))
  end

  defp trace_tool_call_name(tool_call) when is_map(tool_call) do
    function = Map.get(tool_call, "function") || Map.get(tool_call, :function) || %{}

    Map.get(tool_call, "name") || Map.get(tool_call, :name) || Map.get(function, "name") ||
      Map.get(function, :name)
  end

  defp trace_tool_call_name(_tool_call), do: nil

  defp text_summary(nil), do: nil

  defp text_summary(value) do
    value
    |> render_text()
    |> String.slice(0, 1000)
  end

  defp inspect_summary(nil), do: nil

  defp inspect_summary(value) do
    value
    |> inspect(pretty: false, limit: 20, printable_limit: 1000)
    |> String.slice(0, 1000)
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

  defp drain_llm_stream(stream_fun, opts, drain_opts) do
    key = {:runner_stream_state, make_ref()}

    Process.put(key, %{
      content_parts: [],
      reasoning_parts: [],
      tool_calls: [],
      finish_reason: nil,
      usage: nil,
      model: nil,
      response_metadata: %{},
      error: nil,
      streamed_text: false
    })

    callback = fn event ->
      state = Process.get(key)
      Process.put(key, handle_stream_event(state, event, opts, drain_opts))
    end

    result = stream_fun.(callback)
    state = Process.get(key)
    Process.delete(key)

    cond do
      match?({:error, reason} when not is_nil(reason), result) ->
        {:error, wrap_stream_error(elem(result, 1), state)}

      state.error ->
        {:error, wrap_stream_error(state.error, state)}

      true ->
        {:ok,
         %{
           content: Enum.reverse(state.content_parts) |> IO.iodata_to_binary(),
           reasoning_content: Enum.reverse(state.reasoning_parts) |> IO.iodata_to_binary(),
           tool_calls: Enum.reverse(state.tool_calls),
           finish_reason: state.finish_reason,
           usage: state.usage,
           model: state.model,
           response_metadata: state.response_metadata,
           streamed_text: state.streamed_text
         }}
    end
  end

  defp wrap_stream_error(reason, state) do
    partial_content = Enum.reverse(state.content_parts) |> IO.iodata_to_binary()

    %{
      type: :stream_interrupted,
      reason: reason,
      partial_content: partial_content,
      finish_reason: state.finish_reason,
      usage: state.usage,
      model: state.model
    }
  end

  defp handle_stream_event(state, {:delta, text}, opts, drain_opts) when is_binary(text) do
    state =
      %{
        state
        | content_parts: [text | state.content_parts],
          streamed_text: state.streamed_text or text != ""
      }

    if Keyword.get(drain_opts, :stream_output?, false) and
         not Keyword.get(opts, :_suppress_current_reply_stream, false) and
         text != "" do
      maybe_flush_tool_notice_separator(opts)
      maybe_call_stream_sink(opts, {:text, text})
    end

    state
  end

  defp handle_stream_event(state, {:thinking, text}, _opts, _drain_opts) when is_binary(text) do
    %{state | reasoning_parts: [text | state.reasoning_parts]}
  end

  defp handle_stream_event(state, {:tool_calls, tool_calls}, _opts, _drain_opts)
       when is_list(tool_calls) do
    %{state | tool_calls: Enum.reverse(tool_calls) ++ state.tool_calls}
  end

  defp handle_stream_event(state, {:done, metadata}, _opts, _drain_opts) when is_map(metadata) do
    response_metadata =
      metadata
      |> Map.drop([:finish_reason, :usage, :model, "finish_reason", "usage", "model"])
      |> Enum.into(%{})

    %{
      state
      | finish_reason: Map.get(metadata, :finish_reason) || Map.get(metadata, "finish_reason"),
        usage: Map.get(metadata, :usage) || Map.get(metadata, "usage"),
        model: Map.get(metadata, :model) || Map.get(metadata, "model"),
        response_metadata: Map.merge(state.response_metadata || %{}, response_metadata)
    }
  end

  defp handle_stream_event(state, {:error, reason}, _opts, _drain_opts) do
    %{state | error: reason}
  end

  defp handle_stream_event(state, _event, _opts, _drain_opts), do: state

  defp maybe_call_stream_sink(opts, event) do
    case Keyword.get(opts, :stream_sink) do
      sink when is_function(sink, 1) ->
        _ = sink.(event)
        remember_stream_text_suffix(event)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_flush_text_before_tool_notice(opts) do
    cond do
      Process.get(:_last_stream_was_tool_notice) ->
        :ok

      is_nil(Process.get(:_stream_text_suffix)) ->
        :ok

      String.ends_with?(Process.get(:_stream_text_suffix), "\n\n") ->
        :ok

      String.ends_with?(Process.get(:_stream_text_suffix), "\n") ->
        maybe_call_stream_sink(opts, {:text, "\n"})

      true ->
        maybe_call_stream_sink(opts, {:text, "\n\n"})
    end
  end

  # Flush a blank-line separator between tool-call notices and the next text output.
  # The notice itself ends with "\n"; when real text follows we need one more "\n" to
  # produce the visual blank line.  When consecutive notices follow each other the flag
  # is simply overwritten so no extra blank line appears between them.
  defp maybe_flush_tool_notice_separator(opts) do
    if Process.get(:_last_stream_was_tool_notice) do
      Process.delete(:_last_stream_was_tool_notice)
      maybe_call_stream_sink(opts, {:text, "\n"})
    end

    :ok
  end

  defp remember_stream_text_suffix({:text, text}) when is_binary(text) and text != "" do
    previous = Process.get(:_stream_text_suffix, "")
    suffix = previous <> text

    Process.put(:_stream_text_suffix, String.slice(suffix, -2, 2))
  end

  defp remember_stream_text_suffix(_event), do: :ok

  defp reset_stream_format_state do
    Process.delete(:_last_stream_was_tool_notice)
    Process.delete(:_stream_text_suffix)
  end

  defp cancelled?(opts) do
    case Keyword.get(opts, :cancel_ref) do
      ref when is_reference(ref) -> RunControl.cancelled?(ref)
      _ -> false
    end
  end

  defp cancelled_ctx?(ctx) do
    case Map.get(ctx, :cancel_ref) do
      ref when is_reference(ref) -> RunControl.cancelled?(ref)
      _ -> false
    end
  end

  defp sleep_with_cancel(timeout_ms, opts) do
    started_at = System.monotonic_time(:millisecond)
    do_sleep_with_cancel(timeout_ms, started_at, opts)
  end

  defp do_sleep_with_cancel(timeout_ms, started_at, opts) do
    cond do
      cancelled?(opts) ->
        :ok

      System.monotonic_time(:millisecond) - started_at >= timeout_ms ->
        :ok

      true ->
        Process.sleep(50)
        do_sleep_with_cancel(timeout_ms, started_at, opts)
    end
  end

  defp format_stream_error(:cancelled), do: "cancelled"
  defp format_stream_error(reason) when is_binary(reason), do: reason
  defp format_stream_error(reason), do: inspect(reason)
end
