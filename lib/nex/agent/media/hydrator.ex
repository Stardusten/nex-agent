defmodule Nex.Agent.Media.Hydrator do
  @moduledoc """
  Hydrates channel media refs into local attachments.
  """

  require Logger

  alias Nex.Agent.Media.{Ref, Store}

  @spec hydrate_refs([Ref.t()], keyword()) :: {[Nex.Agent.Media.Attachment.t()], [Ref.t()]}
  def hydrate_refs(refs, opts) when is_list(refs) do
    Enum.reduce(refs, {[], []}, fn ref, {attachments, unresolved} ->
      case hydrate_ref(ref, opts) do
        {:ok, attachment} ->
          {[attachment | attachments], unresolved}

        :unhandled ->
          {attachments, [ref | unresolved]}

        {:error, reason} ->
          Logger.warning("[Media.Hydrator] Failed to hydrate #{inspect(ref)}: #{inspect(reason)}")
          {attachments, [ref | unresolved]}
      end
    end)
    |> then(fn {attachments, unresolved} ->
      {Enum.reverse(attachments), Enum.reverse(unresolved)}
    end)
  end

  defp hydrate_ref(%Ref{kind: :image} = ref, opts) do
    fetch_binary_fun = Keyword.fetch!(opts, :fetch_binary_fun)

    with {:ok, body, mime_type} <- fetch_binary_fun.(ref),
         {:ok, attachment} <-
           Store.put_binary(
             body,
             channel: ref.channel,
             kind: ref.kind,
             mime_type: mime_type || ref.mime_type || "image/jpeg",
             filename: ref.filename,
             message_id: ref.message_id,
             platform_ref: ref.platform_ref,
             metadata: ref.metadata,
             workspace: Keyword.get(opts, :workspace)
           ) do
      {:ok, attachment}
    end
  rescue
    error -> {:error, error}
  end

  defp hydrate_ref(%Ref{}, _opts), do: :unhandled
end
