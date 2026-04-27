defmodule Nex.Agent.Media.Projector do
  @moduledoc """
  Projects hydrated attachments into provider-facing multimodal content items.
  """

  alias Nex.Agent.Media.{Attachment, Ref}

  @max_text_file_bytes 256 * 1024

  @spec project_for_model([Attachment.t()] | nil, keyword()) :: [map()]
  def project_for_model(nil, _opts), do: []
  def project_for_model([], _opts), do: []

  def project_for_model(attachments, _opts) do
    Enum.flat_map(attachments, fn
      %Attachment{kind: :image, local_path: path, mime_type: mime_type} ->
        [
          %{
            "type" => "image",
            "source" => %{
              "type" => "file",
              "path" => path,
              "media_type" => mime_type
            }
          }
        ]

      %Attachment{kind: :file, local_path: path, mime_type: mime_type, filename: filename} =
          attachment ->
        if text_file?(attachment) do
          [
            %{
              "type" => "text",
              "text" => text_file_projection(path, filename, mime_type)
            }
          ]
        else
          [fallback_text(attachment)]
        end

      %Attachment{kind: kind, filename: filename} ->
        [
          fallback_text(kind, filename)
        ]
    end)
  end

  @spec unresolved_refs_text([Ref.t()] | nil) :: String.t() | nil
  def unresolved_refs_text(nil), do: nil
  def unresolved_refs_text([]), do: nil

  def unresolved_refs_text(refs) when is_list(refs) do
    refs
    |> Enum.map(&unresolved_ref_line/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp text_file?(%Attachment{mime_type: mime_type, filename: filename}) do
    textual_mime?(mime_type) or textual_extension?(filename)
  end

  defp textual_mime?(mime_type) when is_binary(mime_type) do
    String.starts_with?(mime_type, "text/") or
      mime_type in [
        "application/json",
        "application/x-ndjson",
        "application/xml",
        "application/yaml",
        "application/toml",
        "application/javascript",
        "application/typescript",
        "application/x-sh",
        "application/x-shellscript"
      ]
  end

  defp textual_mime?(_), do: false

  defp textual_extension?(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in([
      ".txt",
      ".md",
      ".markdown",
      ".json",
      ".jsonl",
      ".csv",
      ".tsv",
      ".xml",
      ".yaml",
      ".yml",
      ".toml",
      ".ex",
      ".exs",
      ".js",
      ".ts",
      ".py",
      ".rb",
      ".go",
      ".rs",
      ".java",
      ".c",
      ".h",
      ".cpp",
      ".hpp",
      ".sh",
      ".log"
    ])
  end

  defp textual_extension?(_), do: false

  defp text_file_projection(path, filename, mime_type) do
    content =
      case File.stat(path) do
        {:ok, %{size: size}} when size > @max_text_file_bytes ->
          read_file_preview(path)

        {:ok, _stat} ->
          {:full, File.read!(path)}

        {:error, reason} ->
          {:error, reason}
      end

    case content do
      {:full, body} ->
        "[User sent text file: #{filename || Path.basename(path)}; mime=#{mime_type}]\n\n" <> body

      {:truncated, body} ->
        "[User sent text file: #{filename || Path.basename(path)}; mime=#{mime_type}; truncated to #{@max_text_file_bytes} bytes]\n\n" <>
          body

      {:error, reason} ->
        "[User sent text file: #{filename || Path.basename(path)}, but it could not be read: #{inspect(reason)}]"
    end
  end

  defp read_file_preview(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @max_text_file_bytes) do
            data when is_binary(data) -> {:truncated, data}
            :eof -> {:truncated, ""}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_text(%Attachment{kind: kind, filename: filename}),
    do: fallback_text(kind, filename)

  defp fallback_text(kind, filename) do
    %{
      "type" => "text",
      "text" => "[User sent #{kind}: #{filename || "attachment"}]"
    }
  end

  defp unresolved_ref_line(%Ref{kind: kind, filename: filename, mime_type: mime_type}) do
    details =
      [
        filename || "attachment",
        if(mime_type, do: "mime=#{mime_type}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    "[User sent #{kind}: #{details}, but the attachment could not be downloaded for this turn.]"
  end

  defp unresolved_ref_line(_ref), do: ""
end
